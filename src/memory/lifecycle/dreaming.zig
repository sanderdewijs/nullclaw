//! Dreaming — 3-phase background memory consolidation.
//!
//! Inspired by OpenClaw's dreaming concept, adapted for nullclaw's
//! vtable-driven memory architecture.
//!
//! **Light Sleep**: Consumes recall log, updates tracking state (recall counts,
//!   query diversity). Pure bookkeeping, no LLM, no data modification.
//!
//! **Deep Sleep**: Scores every memory entry using weighted signals (relevance,
//!   frequency, query diversity, recency, consolidation, richness). Entries
//!   passing all thresholds are promoted to `.core` category.
//!
//! **REM**: Builds a summarization prompt from promoted entries for pattern
//!   extraction. The prompt is returned (not executed) — the caller schedules
//!   it as an agent cron job.
//!
//! Scheduling is driven by the cron system: `runIfDue()` checks cadence
//! via persistent state, same pattern as `hygiene.runIfDue()`.

const std = @import("std");
const root = @import("../root.zig");
const Memory = root.Memory;
const MemoryEntry = root.MemoryEntry;
const MemoryCategory = root.MemoryCategory;
const dream_state = @import("dream_state.zig");
const DreamState = dream_state.DreamState;
const temporal_decay = @import("../retrieval/temporal_decay.zig");
const cron = @import("../../cron.zig");
const log = std.log.scoped(.dreaming);

// ── Configuration ────────────────────────────────────────────────

pub const DreamingConfig = struct {
    enabled: bool = false,
    /// Cron expression for scheduling (default: 3 AM daily).
    frequency: []const u8 = "0 3 * * *",
    /// IANA timezone for the schedule.
    timezone: []const u8 = "",
    /// Workspace directory (injected at runtime).
    workspace_dir: []const u8 = "",
};

// ── Scoring weights ──────────────────────────────────────────────

const WEIGHT_RELEVANCE: f64 = 0.30;
const WEIGHT_FREQUENCY: f64 = 0.24;
const WEIGHT_QUERY_DIVERSITY: f64 = 0.15;
const WEIGHT_RECENCY: f64 = 0.15;
const WEIGHT_CONSOLIDATION: f64 = 0.10;
const WEIGHT_RICHNESS: f64 = 0.06;

// ── Promotion thresholds ─────────────────────────────────────────

const MIN_SCORE: f64 = 0.8;
const MIN_RECALL_COUNT: u64 = 3;
const MIN_UNIQUE_QUERIES: u32 = 3;

// ── Cadence ──────────────────────────────────────────────────────

/// Fallback cadence (24h) if the configured cron expression cannot be parsed.
/// The cron path is the primary mechanism; this only kicks in when
/// `config.frequency` is malformed so we still make forward progress.
const DREAM_FALLBACK_INTERVAL_SECS: i64 = 24 * 60 * 60;

/// Return true when the configured cron schedule says another dream cycle is
/// due. Uses the same 5-field expression parser as the main cron scheduler, so
/// semantics match (UTC-interpreted; the `timezone` config field is accepted
/// but not yet honored — same limitation as scheduled cron jobs).
fn cronCycleDue(expression: []const u8, last_run_at: i64, now: i64) bool {
    if (last_run_at <= 0) return true; // never run before
    const next = cron.nextRunForCronExpression(expression, last_run_at) catch {
        // Malformed expression: fall back to a fixed 24h interval so we keep
        // running (and the user still gets dream cycles) instead of stalling.
        return (now -% last_run_at) >= DREAM_FALLBACK_INTERVAL_SECS;
    };
    return now >= next;
}

// ── Report ───────────────────────────────────────────────────────

pub const DreamReport = struct {
    light_recall_events_processed: u64 = 0,
    deep_entries_scored: u64 = 0,
    deep_entries_promoted: u64 = 0,
    rem_prompt: ?[]const u8 = null,
    skipped: bool = false,
    skip_reason: ?[]const u8 = null,

    pub fn deinit(self: *DreamReport, allocator: std.mem.Allocator) void {
        if (self.rem_prompt) |p| allocator.free(p);
    }
};

// ── Entry point ──────────────────────────────────────────────────

/// Run all dreaming phases if the cadence window has elapsed.
/// Returns a report with counts and an optional REM prompt.
pub fn runIfDue(allocator: std.mem.Allocator, config: DreamingConfig, mem: ?Memory) DreamReport {
    if (!config.enabled) return .{ .skipped = true, .skip_reason = "disabled" };

    const m = mem orelse return .{ .skipped = true, .skip_reason = "no memory backend" };

    if (config.workspace_dir.len == 0)
        return .{ .skipped = true, .skip_reason = "no workspace_dir" };

    // Load persistent state
    var state = dream_state.load(allocator, config.workspace_dir) catch |err| {
        log.warn("failed to load dream state: {}", .{err});
        return .{ .skipped = true, .skip_reason = "state load failed" };
    };
    defer state.deinit();

    // Check cadence against the configured cron expression.
    const now = std.time.timestamp();
    if (!cronCycleDue(config.frequency, state.last_run_at, now)) {
        return .{ .skipped = true, .skip_reason = "too soon" };
    }

    var report = DreamReport{};

    // Phase 1: Light Sleep
    report.light_recall_events_processed = runLightPhase(allocator, config.workspace_dir, &state);

    // Phase 2: Deep Sleep
    const deep = runDeepPhase(allocator, m, &state, now);
    report.deep_entries_scored = deep.scored;
    report.deep_entries_promoted = deep.promoted;

    // Phase 3: REM
    report.rem_prompt = buildRemPrompt(allocator, m, &state) catch null;

    // Update state
    state.last_run_at = now;
    state.last_phase = "rem";
    state.cycle_count += 1;

    // Persist
    dream_state.save(allocator, config.workspace_dir, &state) catch |err| {
        log.warn("failed to save dream state: {}", .{err});
    };

    log.info("dream cycle {d}: light={d} events, deep={d}/{d} promoted, rem={s}", .{
        state.cycle_count,
        report.light_recall_events_processed,
        report.deep_entries_promoted,
        report.deep_entries_scored,
        if (report.rem_prompt != null) "yes" else "no",
    });

    return report;
}

// ── Phase 1: Light Sleep ─────────────────────────────────────────

/// Process recall log events into tracking state. Pure bookkeeping.
fn runLightPhase(allocator: std.mem.Allocator, workspace_dir: []const u8, state: *DreamState) u64 {
    const events = dream_state.consumeRecallLog(allocator, workspace_dir) catch |err| {
        log.warn("light phase: failed to consume recall log: {}", .{err});
        return 0;
    };
    defer {
        for (events) |e| {
            allocator.free(e.key);
            allocator.free(e.session_id);
        }
        allocator.free(events);
    }

    if (events.len == 0) return 0;

    // We need the arena to own any new strings we put into the maps
    if (state._arena == null) state._arena = std.heap.ArenaAllocator.init(allocator);
    const arena = state._arena.?.allocator();

    for (events) |event| {
        // Update recall count
        if (state.recall_counts.getPtr(event.key)) |count| {
            count.* += 1;
        } else {
            const key = arena.dupe(u8, event.key) catch continue;
            state.recall_counts.put(arena, key, 1) catch continue;
        }

        // Update query diversity (unique sessions)
        if (state.query_diversity.getPtr(event.key)) |set| {
            if (!set.contains(event.session_id)) {
                const sid = arena.dupe(u8, event.session_id) catch continue;
                set.put(arena, sid, {}) catch continue;
            }
        } else {
            var set = DreamState.SessionSet{};
            const sid = arena.dupe(u8, event.session_id) catch continue;
            set.put(arena, sid, {}) catch continue;
            const key = arena.dupe(u8, event.key) catch continue;
            state.query_diversity.put(arena, key, set) catch continue;
        }
    }

    return events.len;
}

// ── Phase 2: Deep Sleep ──────────────────────────────────────────

const DeepResult = struct {
    scored: u64,
    promoted: u64,
};

/// Score all memory entries and promote qualifying ones to .core.
fn runDeepPhase(allocator: std.mem.Allocator, mem: Memory, state: *DreamState, now: i64) DeepResult {
    var result = DeepResult{ .scored = 0, .promoted = 0 };

    // List all non-core entries (core entries don't need promotion)
    const entries = mem.list(allocator, null, null) catch |err| {
        log.warn("deep phase: failed to list entries: {}", .{err});
        return result;
    };
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    if (state._arena == null) state._arena = std.heap.ArenaAllocator.init(allocator);
    const arena = state._arena.?.allocator();

    for (entries) |entry| {
        // Skip entries that are already core or already promoted
        if (entry.category == .core) continue;
        if (state.promoted_keys.contains(entry.key)) continue;
        // Skip internal keys
        if (isInternalKey(entry.key)) continue;

        result.scored += 1;

        const score = computeScore(entry, state, now);
        const recall_count = state.recall_counts.get(entry.key) orelse 0;
        const unique_queries = if (state.query_diversity.get(entry.key)) |set|
            set.count()
        else
            0;

        if (score >= MIN_SCORE and recall_count >= MIN_RECALL_COUNT and unique_queries >= MIN_UNIQUE_QUERIES) {
            // Promote: store as core
            mem.store(entry.key, entry.content, .core, null) catch |err| {
                log.warn("deep phase: failed to promote '{s}': {}", .{ entry.key, err });
                continue;
            };

            // Track promotion
            const pkey = arena.dupe(u8, entry.key) catch continue;
            state.promoted_keys.put(arena, pkey, {}) catch continue;

            // Increment consolidation count
            if (state.consolidation_counts.getPtr(entry.key)) |count| {
                count.* += 1;
            } else {
                const ckey = arena.dupe(u8, entry.key) catch continue;
                state.consolidation_counts.put(arena, ckey, 1) catch continue;
            }

            result.promoted += 1;
            log.info("promoted '{s}' (score={d:.2}, recalls={d}, diversity={d})", .{
                entry.key, score, recall_count, unique_queries,
            });
        }
    }

    return result;
}

/// Compute weighted dream score for a single entry.
fn computeScore(entry: MemoryEntry, state: *const DreamState, now: i64) f64 {
    // Relevance: use existing score from retrieval engine, normalized to [0,1]
    const relevance = if (entry.score) |s| @min(1.0, @max(0.0, s)) else 0.5;

    // Frequency: recall count, saturating at 10
    const recall_count = state.recall_counts.get(entry.key) orelse 0;
    const frequency = @min(1.0, @as(f64, @floatFromInt(recall_count)) / 10.0);

    // Query diversity: unique session count, saturating at 5
    const unique_sessions: u32 = if (state.query_diversity.get(entry.key)) |set|
        set.count()
    else
        0;
    const diversity = @min(1.0, @as(f64, @floatFromInt(unique_sessions)) / 5.0);

    // Recency: temporal decay with 14-day half-life
    const ts = parseTimestamp(entry.timestamp);
    const age_secs_raw = now -% ts;
    const age_days: f64 = if (age_secs_raw < 0) 0.0 else @as(f64, @floatFromInt(age_secs_raw)) / 86400.0;
    const recency = temporal_decay.decayMultiplier(age_days, 14);

    // Consolidation: number of dream cycles survived, saturating at 10
    const consol_count = state.consolidation_counts.get(entry.key) orelse 0;
    const consolidation = @min(1.0, @as(f64, @floatFromInt(consol_count)) / 10.0);

    // Richness: content length with diminishing returns, cap at 500 chars
    const content_len: f64 = @floatFromInt(@min(entry.content.len, 500));
    const richness = content_len / 500.0;

    return (WEIGHT_RELEVANCE * relevance) +
        (WEIGHT_FREQUENCY * frequency) +
        (WEIGHT_QUERY_DIVERSITY * diversity) +
        (WEIGHT_RECENCY * recency) +
        (WEIGHT_CONSOLIDATION * consolidation) +
        (WEIGHT_RICHNESS * richness);
}

// ── Phase 3: REM ─────────────────────────────────────────────────

/// Build a summarization prompt from recently promoted entries.
/// Returns the prompt text; caller schedules it as an agent job.
fn buildRemPrompt(allocator: std.mem.Allocator, mem: Memory, state: *const DreamState) !?[]const u8 {
    if (state.promoted_keys.count() == 0) return null;

    // Collect promoted entry contents
    var contents = std.ArrayListUnmanaged(u8){};
    defer contents.deinit(allocator);
    const writer = contents.writer(allocator);

    var count: u32 = 0;
    var it = state.promoted_keys.iterator();
    while (it.next()) |kv| {
        const entry = mem.get(allocator, kv.key_ptr.*) catch continue orelse continue;
        defer entry.deinit(allocator);

        try std.fmt.format(writer, "- [{s}] {s}\n", .{ entry.key, entry.content });
        count += 1;
        if (count >= 20) break; // Cap prompt size
    }

    if (count == 0) return null;

    const prompt = try std.fmt.allocPrint(allocator,
        \\You are reviewing your long-term memory after a dream cycle.
        \\Below are {d} memory entries that were recently promoted to core memory
        \\because they were frequently recalled across multiple sessions.
        \\
        \\ENTRIES:
        \\{s}
        \\
        \\TASK:
        \\1. Identify 2-3 recurring themes or patterns across these entries.
        \\2. Note any contradictions or outdated information.
        \\3. Write a brief reflection (3-5 sentences) about what these patterns
        \\   reveal about your conversations and how you might improve.
        \\
        \\Write your reflection in the first person. Be concise and insightful.
        \\Save the reflection to DREAMS.md using file_edit (append, don't overwrite).
    , .{ count, contents.items });
    return prompt;
}

// ── Helpers ──────────────────────────────────────────────────────

fn isInternalKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "last_hygiene_at") or
        std.mem.startsWith(u8, key, "bootstrap:") or
        std.mem.startsWith(u8, key, "archive:") or
        std.mem.startsWith(u8, key, "recall_track:") or
        std.mem.startsWith(u8, key, "_");
}

fn parseTimestamp(ts: []const u8) i64 {
    return std.fmt.parseInt(i64, ts, 10) catch 0;
}

// ── Tests ────────────────────────────────────────────────────────

test "computeScore returns weighted score" {
    var state = DreamState{};
    defer state.deinit();
    state._arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const arena = state._arena.?.allocator();

    const key = try arena.dupe(u8, "test_key");
    try state.recall_counts.put(arena, key, 5);

    var sessions = DreamState.SessionSet{};
    const s1 = try arena.dupe(u8, "a");
    const s2 = try arena.dupe(u8, "b");
    const s3 = try arena.dupe(u8, "c");
    try sessions.put(arena, s1, {});
    try sessions.put(arena, s2, {});
    try sessions.put(arena, s3, {});
    const qkey = try arena.dupe(u8, "test_key");
    try state.query_diversity.put(arena, qkey, sessions);

    const ckey = try arena.dupe(u8, "test_key");
    try state.consolidation_counts.put(arena, ckey, 2);

    const now = std.time.timestamp();
    var ts_buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now}) catch unreachable;

    const entry = MemoryEntry{
        .id = "1",
        .key = "test_key",
        .content = "This is a test memory entry with enough content to score well on richness",
        .category = .daily,
        .timestamp = ts_str,
        .score = 0.9,
    };

    const score = computeScore(entry, &state, now);

    // Score should be reasonably high given good signals
    try std.testing.expect(score > 0.5);
    try std.testing.expect(score <= 1.0);
}

test "cronCycleDue fires exactly once per daily window" {
    // "0 23 * * *" = every day at 23:00 UTC. Pick a last_run anchored at that
    // minute so we can step forward in predictable increments.
    const one_hour: i64 = 3600;
    const one_day: i64 = 24 * one_hour;

    // Anchor: 2026-01-01T23:00:00Z — verified below with the parser itself.
    const anchor: i64 = cron.nextRunForCronExpression("0 23 * * *", 1_767_306_000) catch unreachable;

    // 1 hour after: not yet due (next fire is +24h).
    try std.testing.expect(!cronCycleDue("0 23 * * *", anchor, anchor + one_hour));
    // Exactly +24h after last run: due.
    try std.testing.expect(cronCycleDue("0 23 * * *", anchor, anchor + one_day));
    // Never-run state should always fire.
    try std.testing.expect(cronCycleDue("0 23 * * *", 0, anchor));
}

test "cronCycleDue falls back gracefully on malformed expression" {
    const one_hour: i64 = 3600;
    const one_day: i64 = 24 * one_hour;
    // 1 hour after last_run: not yet due under the 24h fallback.
    try std.testing.expect(!cronCycleDue("nonsense", 1_000_000, 1_000_000 + one_hour));
    // A full day later: due.
    try std.testing.expect(cronCycleDue("nonsense", 1_000_000, 1_000_000 + one_day));
}

test "isInternalKey filters bootstrap and internal keys" {
    try std.testing.expect(isInternalKey("last_hygiene_at"));
    try std.testing.expect(isInternalKey("bootstrap:soul"));
    try std.testing.expect(isInternalKey("archive:2026-01-01:chunk:0"));
    try std.testing.expect(isInternalKey("_internal"));
    try std.testing.expect(!isInternalKey("user_preference"));
    try std.testing.expect(!isInternalKey("meeting_notes"));
}

test "runLightPhase processes recall events into state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.makePath("memory/.dreams");

    // Seed recall events
    dream_state.appendRecallEvent(allocator, tmp_path, .{
        .key = "fact_a",
        .session_id = "sess_1",
        .timestamp = 1000,
    });
    dream_state.appendRecallEvent(allocator, tmp_path, .{
        .key = "fact_a",
        .session_id = "sess_2",
        .timestamp = 1001,
    });
    dream_state.appendRecallEvent(allocator, tmp_path, .{
        .key = "fact_b",
        .session_id = "sess_1",
        .timestamp = 1002,
    });

    var state = DreamState{};
    defer state.deinit();

    const processed = runLightPhase(allocator, tmp_path, &state);
    try std.testing.expectEqual(@as(u64, 3), processed);
    try std.testing.expectEqual(@as(u64, 2), state.recall_counts.get("fact_a").?);
    try std.testing.expectEqual(@as(u64, 1), state.recall_counts.get("fact_b").?);

    const diversity = state.query_diversity.get("fact_a").?;
    try std.testing.expectEqual(@as(u32, 2), diversity.count());
}
