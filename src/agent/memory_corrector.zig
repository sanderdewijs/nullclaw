//! Memory Self-Correction — detects and removes memories that contradict tool results.
//!
//! After a turn where all tools succeeded, checks recalled memory entries for
//! failure/error language. If found, the entry is auto-forgotten because the tool
//! success proves the memory is outdated.

const std = @import("std");
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const MemoryEntry = memory_mod.MemoryEntry;

pub const log = std.log.scoped(.memory_corrector);

/// Failure indicator patterns (bilingual NL/EN).
const failure_indicators = [_][]const u8{
    "error",
    "failed",
    "failure",
    "DNS",
    "timeout",
    "timed out",
    "network",
    "connection refused",
    "could not connect",
    "unreachable",
    "fout",
    "mislukt",
    "faalt",
    "niet bereikbaar",
    "lukt niet",
    "kan niet",
    "vastgelopen",
    "blocked",
    "geblokke",
};

/// Check recalled memory entries against tool execution results.
/// If all tools succeeded but a recalled entry contains failure language,
/// auto-forget that entry because it's contradicted by reality.
///
/// Returns the number of entries corrected.
pub fn correctContradictions(
    allocator: std.mem.Allocator,
    mem: ?Memory,
    recalled_keys: []const []const u8,
    tools_succeeded: bool,
) u32 {
    const m = mem orelse return 0;
    if (!tools_succeeded) return 0;
    if (recalled_keys.len == 0) return 0;

    var corrected: u32 = 0;

    for (recalled_keys) |key| {
        // Skip internal keys
        if (memory_mod.isInternalMemoryKey(key)) continue;

        // Fetch the full entry to check content
        const entry = m.get(allocator, key) catch continue orelse continue;
        defer entry.deinit(allocator);

        if (containsFailureIndicator(entry.content)) {
            _ = m.forget(key) catch continue;
            log.info("corrected '{s}' — tool succeeded but memory claimed failure", .{key});
            corrected += 1;
        }
    }

    return corrected;
}

/// Case-insensitive check for failure indicators in content.
fn containsFailureIndicator(content: []const u8) bool {
    // Work with lowercase for case-insensitive matching
    for (failure_indicators) |indicator| {
        if (indexOfCaseInsensitive(content, indicator) != null) return true;
    }
    return false;
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (matchCaseInsensitive(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn matchCaseInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "containsFailureIndicator detects English patterns" {
    try std.testing.expect(containsFailureIndicator("IMAP connection failed due to DNS"));
    try std.testing.expect(containsFailureIndicator("Network error when connecting"));
    try std.testing.expect(containsFailureIndicator("Connection timed out after 30s"));
    try std.testing.expect(containsFailureIndicator("Could not connect to server"));
}

test "containsFailureIndicator detects Dutch patterns" {
    try std.testing.expect(containsFailureIndicator("IMAP verbinding mislukt door DNS"));
    try std.testing.expect(containsFailureIndicator("Netwerkfout bij het verbinden"));
    try std.testing.expect(containsFailureIndicator("Het lukt niet om verbinding te maken"));
    try std.testing.expect(containsFailureIndicator("Server niet bereikbaar"));
}

test "containsFailureIndicator is case insensitive" {
    try std.testing.expect(containsFailureIndicator("DNS Error"));
    try std.testing.expect(containsFailureIndicator("FAILED to connect"));
    try std.testing.expect(containsFailureIndicator("Timeout bij verbinding"));
}

test "containsFailureIndicator does not match normal content" {
    try std.testing.expect(!containsFailureIndicator("Workshop AI in de Zorg"));
    try std.testing.expect(!containsFailureIndicator("Sander's favorite language is Zig"));
    try std.testing.expect(!containsFailureIndicator("Calendar updated successfully"));
    try std.testing.expect(!containsFailureIndicator("Email sent to Daisha"));
}

test "correctContradictions with no memory returns 0" {
    try std.testing.expectEqual(@as(u32, 0), correctContradictions(
        std.testing.allocator,
        null,
        &.{},
        true,
    ));
}

test "correctContradictions skips when tools failed" {
    try std.testing.expectEqual(@as(u32, 0), correctContradictions(
        std.testing.allocator,
        null,
        &.{},
        false,
    ));
}
