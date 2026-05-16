//! xAI OAuth 2.0 device authorization for SuperGrok subscriptions.
//!
//! Authenticates via OAuth device code flow (RFC 8628) against auth.x.ai,
//! allowing users with a SuperGrok subscription to use NullClaw without a
//! separate XAI_API_KEY.
//!
//! Usage:
//!   nullclaw auth login xai   — sign in via device code flow
//!   nullclaw auth status xai  — check authentication status
//!   nullclaw auth logout xai  — remove stored credentials

const std = @import("std");
const auth = @import("../auth.zig");
const platform = @import("../platform.zig");

// ── OAuth constants ───────────────────────────────────────────────────────

pub const OAUTH_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828";
pub const OAUTH_DEVICE_URL = "https://auth.x.ai/oauth/device-authorization";
pub const OAUTH_TOKEN_URL = "https://auth.x.ai/oauth/token";
pub const OAUTH_SCOPE = "openid profile email offline_access grok-cli:access api:access";
pub const CREDENTIAL_KEY = "xai";

// ── Token resolution ──────────────────────────────────────────────────────

/// Resolve the current xAI OAuth access token, refreshing if expired.
/// Returns an owned slice (caller must call allocator.free()).
/// Returns null when not authenticated or when all refresh attempts fail.
pub fn resolveToken(allocator: std.mem.Allocator) !?[]u8 {
    // Fast path: non-expired credential already in store.
    if (auth.loadCredential(allocator, CREDENTIAL_KEY) catch null) |token| {
        defer token.deinit(allocator);
        return try allocator.dupe(u8, token.access_token);
    }
    // Credential missing or within 300 s of expiry — try refresh.
    return tryRefreshToken(allocator);
}

/// Exchange a stored refresh_token for a new access_token.
/// Saves the refreshed token back to auth.json on success.
fn tryRefreshToken(allocator: std.mem.Allocator) !?[]u8 {
    const home = platform.getHomeDir(allocator) catch return null;
    defer allocator.free(home);

    const file_path = try std.fs.path.join(allocator, &.{ home, ".nullclaw", "auth.json" });
    defer allocator.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const prov_val = root_obj.get(CREDENTIAL_KEY) orelse return null;
    const prov_obj = switch (prov_val) {
        .object => |o| o,
        else => return null,
    };

    const rt_str: ?[]const u8 = if (prov_obj.get("refresh_token")) |v| switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    } else null;
    if (rt_str == null) return null;

    const new_token = auth.refreshAccessToken(
        allocator,
        OAUTH_TOKEN_URL,
        OAUTH_CLIENT_ID,
        rt_str.?,
    ) catch return null;
    defer new_token.deinit(allocator);

    auth.saveCredential(allocator, CREDENTIAL_KEY, new_token) catch {};
    return try allocator.dupe(u8, new_token.access_token);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "OAuth constants are well-formed" {
    try std.testing.expect(OAUTH_CLIENT_ID.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, OAUTH_DEVICE_URL, "https://"));
    try std.testing.expect(std.mem.startsWith(u8, OAUTH_TOKEN_URL, "https://"));
    try std.testing.expect(OAUTH_SCOPE.len > 0);
    try std.testing.expectEqualStrings("xai", CREDENTIAL_KEY);
}

test "device URL points to auth.x.ai" {
    try std.testing.expect(std.mem.indexOf(u8, OAUTH_DEVICE_URL, "auth.x.ai") != null);
    try std.testing.expect(std.mem.indexOf(u8, OAUTH_TOKEN_URL, "auth.x.ai") != null);
}

test "scope includes offline_access for refresh token support" {
    try std.testing.expect(std.mem.indexOf(u8, OAUTH_SCOPE, "offline_access") != null);
}

test "resolveToken returns null in clean test environment" {
    // No xai credentials stored in test environment; should not crash.
    const result = try resolveToken(std.testing.allocator);
    if (result) |token| std.testing.allocator.free(token);
}
