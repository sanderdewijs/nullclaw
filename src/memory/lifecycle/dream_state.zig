//! Dream state persistence — tracks recall counts, query diversity,
//! consolidation history, and promoted keys across dream cycles.
//!
//! State is stored as JSON at `~/.nullclaw/memory/.dreams/state.json`.
//! Recall events are appended to `recall_log.jsonl` by the recall tracking
//! hook and consumed (truncated) during the Light phase.

const std = @import("std");
const fs_compat = @import("../../fs_compat.zig");
const log = std.log.scoped(.dreaming);

// ── Types ────────────────────────────────────────────────────────

/// Persistent dream state, serialized to JSON between cycles.
pub const DreamState = struct {
    last_run_at: i64 = 0,
    last_phase: []const u8 = "none",
    cycle_count: u64 = 0,
    /// Per-key recall counts (how many times recalled since last deep sleep).
    recall_counts: std.StringHashMapUnmanaged(u64) = .{},
    /// Per-key unique session IDs that triggered recall.
    query_diversity: std.StringHashMapUnmanaged(SessionSet) = .{},
    /// Per-key count of dream cycles the entry has survived promotion.
    consolidation_counts: std.StringHashMapUnmanaged(u64) = .{},
    /// Keys that have been promoted to MEMORY.md / .core category.
    promoted_keys: std.StringHashMapUnmanaged(void) = .{},
    /// Arena that owns all heap-allocated strings in the maps above.
    _arena: ?std.heap.ArenaAllocator = null,

    pub const SessionSet = std.StringHashMapUnmanaged(void);

    pub fn deinit(self: *DreamState) void {
        if (self._arena) |*arena| {
            arena.deinit();
        }
        self.* = .{};
    }
};

/// A single recall event logged by the tracking hook.
pub const RecallEvent = struct {
    key: []const u8,
    session_id: []const u8,
    timestamp: i64,
};

// ── Paths ────────────────────────────────────────────────────────

pub fn dreamsDir(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ workspace_dir, "memory", ".dreams" });
}

pub fn statePath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ workspace_dir, "memory", ".dreams", "state.json" });
}

pub fn recallLogPath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ workspace_dir, "memory", ".dreams", "recall_log.jsonl" });
}

// ── Load ─────────────────────────────────────────────────────────

/// Load dream state from disk. Returns default state if file doesn't exist.
pub fn load(allocator: std.mem.Allocator, workspace_dir: []const u8) !DreamState {
    const dir_path = try dreamsDir(allocator, workspace_dir);
    defer allocator.free(dir_path);

    const dir = std.fs.openDirAbsolute(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return DreamState{},
        else => {
            log.warn("failed to open dreams dir: {}", .{err});
            return DreamState{};
        },
    };

    const contents = fs_compat.readFileAlloc(dir, allocator, "state.json", 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return DreamState{},
        else => {
            log.warn("failed to read dream state: {}", .{err});
            return DreamState{};
        },
    };
    defer allocator.free(contents);

    return parseState(allocator, contents) catch |err| {
        log.warn("failed to parse dream state: {}", .{err});
        return DreamState{};
    };
}

fn parseState(parent_allocator: std.mem.Allocator, json_bytes: []const u8) !DreamState {
    var state = DreamState{};
    state._arena = std.heap.ArenaAllocator.init(parent_allocator);
    const allocator = state._arena.?.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, parent_allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return state;
    const obj = root.object;

    if (obj.get("last_run_at")) |v| {
        if (v == .integer) state.last_run_at = v.integer;
    }
    if (obj.get("cycle_count")) |v| {
        if (v == .integer) state.cycle_count = @intCast(@max(0, v.integer));
    }
    if (obj.get("last_phase")) |v| {
        if (v == .string) state.last_phase = try allocator.dupe(u8, v.string);
    }

    // Parse recall_counts: { "key": count }
    if (obj.get("recall_counts")) |v| {
        if (v == .object) {
            for (v.object.keys(), v.object.values()) |k, val| {
                if (val == .integer) {
                    const key = try allocator.dupe(u8, k);
                    try state.recall_counts.put(allocator, key, @intCast(@max(0, val.integer)));
                }
            }
        }
    }

    // Parse query_diversity: { "key": ["sess1", "sess2"] }
    if (obj.get("query_diversity")) |v| {
        if (v == .object) {
            for (v.object.keys(), v.object.values()) |k, val| {
                if (val == .array) {
                    const key = try allocator.dupe(u8, k);
                    var set = DreamState.SessionSet{};
                    for (val.array.items) |item| {
                        if (item == .string) {
                            const sid = try allocator.dupe(u8, item.string);
                            try set.put(allocator, sid, {});
                        }
                    }
                    try state.query_diversity.put(allocator, key, set);
                }
            }
        }
    }

    // Parse consolidation_counts: { "key": count }
    if (obj.get("consolidation_counts")) |v| {
        if (v == .object) {
            for (v.object.keys(), v.object.values()) |k, val| {
                if (val == .integer) {
                    const key = try allocator.dupe(u8, k);
                    try state.consolidation_counts.put(allocator, key, @intCast(@max(0, val.integer)));
                }
            }
        }
    }

    // Parse promoted_keys: ["key1", "key2"]
    if (obj.get("promoted_keys")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item == .string) {
                    const key = try allocator.dupe(u8, item.string);
                    try state.promoted_keys.put(allocator, key, {});
                }
            }
        }
    }

    return state;
}

// ── Save ─────────────────────────────────────────────────────────

/// Persist dream state to disk. Creates the .dreams directory if needed.
pub fn save(allocator: std.mem.Allocator, workspace_dir: []const u8, state: *const DreamState) !void {
    const dir_path = try dreamsDir(allocator, workspace_dir);
    defer allocator.free(dir_path);

    // Ensure directory exists
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try creating parent first
            const parent = try std.fs.path.join(allocator, &.{ workspace_dir, "memory" });
            defer allocator.free(parent);
            std.fs.makeDirAbsolute(parent) catch {};
            std.fs.makeDirAbsolute(dir_path) catch return err;
        },
    };

    const path = try statePath(allocator, workspace_dir);
    defer allocator.free(path);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\n");
    try std.fmt.format(writer, "  \"last_run_at\": {d},\n", .{state.last_run_at});
    try std.fmt.format(writer, "  \"last_phase\": \"{s}\",\n", .{state.last_phase});
    try std.fmt.format(writer, "  \"cycle_count\": {d},\n", .{state.cycle_count});

    // recall_counts
    try writer.writeAll("  \"recall_counts\": {");
    {
        var first = true;
        var it = state.recall_counts.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            try std.fmt.format(writer, "\n    \"{s}\": {d}", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
    }
    if (state.recall_counts.count() > 0) try writer.writeAll("\n  ");
    try writer.writeAll("},\n");

    // query_diversity
    try writer.writeAll("  \"query_diversity\": {");
    {
        var first = true;
        var it = state.query_diversity.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            try std.fmt.format(writer, "\n    \"{s}\": [", .{entry.key_ptr.*});
            var first_sess = true;
            var sit = entry.value_ptr.iterator();
            while (sit.next()) |sess| {
                if (!first_sess) try writer.writeAll(", ");
                try std.fmt.format(writer, "\"{s}\"", .{sess.key_ptr.*});
                first_sess = false;
            }
            try writer.writeAll("]");
            first = false;
        }
    }
    if (state.query_diversity.count() > 0) try writer.writeAll("\n  ");
    try writer.writeAll("},\n");

    // consolidation_counts
    try writer.writeAll("  \"consolidation_counts\": {");
    {
        var first = true;
        var it = state.consolidation_counts.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            try std.fmt.format(writer, "\n    \"{s}\": {d}", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
    }
    if (state.consolidation_counts.count() > 0) try writer.writeAll("\n  ");
    try writer.writeAll("},\n");

    // promoted_keys
    try writer.writeAll("  \"promoted_keys\": [");
    {
        var first = true;
        var it = state.promoted_keys.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(", ");
            try std.fmt.format(writer, "\"{s}\"", .{entry.key_ptr.*});
            first = false;
        }
    }
    try writer.writeAll("]\n}\n");

    // Atomic write: write to tmp, then rename
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer file.close();
    try file.writeAll(buf.items);

    std.fs.renameAbsolute(tmp_path, path) catch |err| {
        log.warn("atomic rename failed, writing directly: {}", .{err});
        const direct = try std.fs.createFileAbsolute(path, .{});
        defer direct.close();
        try direct.writeAll(buf.items);
    };
}

// ── Recall Log ───────────────────────────────────────────────────

/// Append a recall event to the JSONL log. Best-effort, never fails fatally.
pub fn appendRecallEvent(allocator: std.mem.Allocator, workspace_dir: []const u8, event: RecallEvent) void {
    const path = recallLogPath(allocator, workspace_dir) catch return;
    defer allocator.free(path);

    // Ensure directory exists
    const dir = dreamsDir(allocator, workspace_dir) catch return;
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    const line = std.fmt.allocPrint(allocator, "{{\"key\":\"{s}\",\"session_id\":\"{s}\",\"ts\":{d}}}\n", .{
        event.key,
        event.session_id,
        event.timestamp,
    }) catch return;
    defer allocator.free(line);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => {
            const new_file = std.fs.createFileAbsolute(path, .{}) catch return;
            new_file.writeAll(line) catch {};
            new_file.close();
            return;
        },
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch {};
}

/// Read and consume all recall events from the log. Truncates the file after reading.
pub fn consumeRecallLog(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]RecallEvent {
    const path = try recallLogPath(allocator, workspace_dir);
    defer allocator.free(path);

    const dir_path = try dreamsDir(allocator, workspace_dir);
    defer allocator.free(dir_path);

    const dir = std.fs.openDirAbsolute(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(RecallEvent, 0),
        else => return err,
    };

    const contents = fs_compat.readFileAlloc(dir, allocator, "recall_log.jsonl", 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(RecallEvent, 0),
        else => return err,
    };
    defer allocator.free(contents);

    // Parse JSONL
    var events = std.ArrayListUnmanaged(RecallEvent){};
    errdefer {
        for (events.items) |e| {
            allocator.free(e.key);
            allocator.free(e.session_id);
        }
        events.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        const key_val = obj.get("key") orelse continue;
        const sid_val = obj.get("session_id") orelse continue;
        const ts_val = obj.get("ts") orelse continue;

        if (key_val != .string or sid_val != .string or ts_val != .integer) continue;

        try events.append(allocator, .{
            .key = try allocator.dupe(u8, key_val.string),
            .session_id = try allocator.dupe(u8, sid_val.string),
            .timestamp = ts_val.integer,
        });
    }

    // Truncate the log file
    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| {
        log.warn("failed to truncate recall log: {}", .{err});
        return events.toOwnedSlice(allocator);
    };
    defer file.close();
    file.setEndPos(0) catch {};

    return events.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────

test "DreamState save and load roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create memory/.dreams/ directory
    try tmp.dir.makePath("memory/.dreams");

    var state = DreamState{};
    defer state.deinit();
    state._arena = std.heap.ArenaAllocator.init(allocator);
    const arena = state._arena.?.allocator();

    state.last_run_at = 1712534400;
    state.last_phase = try arena.dupe(u8, "deep");
    state.cycle_count = 5;

    const key1 = try arena.dupe(u8, "test_key");
    try state.recall_counts.put(arena, key1, 3);
    try state.consolidation_counts.put(arena, key1, 2);

    var sessions = DreamState.SessionSet{};
    const sid1 = try arena.dupe(u8, "sess_a");
    const sid2 = try arena.dupe(u8, "sess_b");
    try sessions.put(arena, sid1, {});
    try sessions.put(arena, sid2, {});
    const key2 = try arena.dupe(u8, "test_key");
    try state.query_diversity.put(arena, key2, sessions);

    const pkey = try arena.dupe(u8, "promoted_1");
    try state.promoted_keys.put(arena, pkey, {});

    try save(allocator, tmp_path, &state);

    var loaded = try load(allocator, tmp_path);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(i64, 1712534400), loaded.last_run_at);
    try std.testing.expectEqual(@as(u64, 5), loaded.cycle_count);
    try std.testing.expectEqualStrings("deep", loaded.last_phase);
    try std.testing.expectEqual(@as(u64, 3), loaded.recall_counts.get("test_key").?);
    try std.testing.expectEqual(@as(u64, 2), loaded.consolidation_counts.get("test_key").?);
    try std.testing.expect(loaded.promoted_keys.contains("promoted_1"));

    const diversity = loaded.query_diversity.get("test_key").?;
    try std.testing.expectEqual(@as(u32, 2), diversity.count());
}

test "consumeRecallLog parses and truncates" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.makePath("memory/.dreams");

    // Write test recall events
    appendRecallEvent(allocator, tmp_path, .{
        .key = "fact_1",
        .session_id = "sess_a",
        .timestamp = 1712534400,
    });
    appendRecallEvent(allocator, tmp_path, .{
        .key = "fact_2",
        .session_id = "sess_b",
        .timestamp = 1712534401,
    });

    const events = try consumeRecallLog(allocator, tmp_path);
    defer {
        for (events) |e| {
            allocator.free(e.key);
            allocator.free(e.session_id);
        }
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("fact_1", events[0].key);
    try std.testing.expectEqualStrings("sess_b", events[1].session_id);

    // Second consume should return empty (file was truncated)
    const events2 = try consumeRecallLog(allocator, tmp_path);
    defer allocator.free(events2);
    try std.testing.expectEqual(@as(usize, 0), events2.len);
}
