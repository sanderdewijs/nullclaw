const std = @import("std");
const builtin = @import("builtin");
const Sandbox = @import("sandbox.zig").Sandbox;

/// Bubblewrap (bwrap) sandbox backend.
/// Wraps commands with `bwrap` for user-namespace isolation.
pub const BubblewrapSandbox = struct {
    workspace_dir: []const u8,
    /// Extra paths to bind read-only into the sandbox (from autonomy.allowed_paths).
    allowed_paths: []const []const u8 = &.{},
    /// Extra paths to bind read-write into the sandbox (from autonomy.writable_paths).
    /// Applied after allowed_paths and workspace_dir so rw-binds win over any parent ro-bind.
    writable_paths: []const []const u8 = &.{},

    pub const sandbox_vtable = Sandbox.VTable{
        .wrapCommand = wrapCommand,
        .isAvailable = isAvailable,
        .name = getName,
        .description = getDescription,
    };

    pub fn sandbox(self: *BubblewrapSandbox) Sandbox {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &sandbox_vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *BubblewrapSandbox {
        return @ptrCast(@alignCast(ptr));
    }

    fn wrapCommand(ptr: *anyopaque, argv: []const []const u8, buf: [][]const u8) anyerror![]const []const u8 {
        const self = resolve(ptr);
        // Mount ordering matters: later binds override earlier ones at the same
        // path. So we bind system read-only paths first, then allowed_paths
        // (read-only), THEN workspace_dir (read-write) and writable_paths —
        // this guarantees a rw-bind on a child path wins over a ro-bind on its
        // parent (e.g. ro /home/nullclaw + rw ~/.nullclaw/workspace).
        const base_prefix = [_][]const u8{
            "bwrap",
            "--ro-bind",
            "/usr",
            "/usr",
            "--ro-bind-try",
            "/bin",
            "/bin",
            "--ro-bind-try",
            "/lib",
            "/lib",
            "--ro-bind-try",
            "/lib64",
            "/lib64",
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            "--bind",
            "/tmp",
            "/tmp",
            "--ro-bind-try",
            "/etc/resolv.conf",
            "/etc/resolv.conf",
            "--ro-bind-try",
            "/etc/nsswitch.conf",
            "/etc/nsswitch.conf",
            "--ro-bind-try",
            "/etc/ssl",
            "/etc/ssl",
            "--ro-bind-try",
            "/etc/hosts",
            "/etc/hosts",
        };
        const base_suffix = [_][]const u8{
            "--unshare-pid",
            "--unshare-ipc",
            "--die-with-parent",
        };

        const allowed_binds = self.allowed_paths.len * 3;
        const workspace_bind_count: usize = 3;
        const writable_binds = self.writable_paths.len * 3;
        const total = base_prefix.len + allowed_binds + workspace_bind_count + writable_binds + base_suffix.len + argv.len;
        if (buf.len < total) return error.BufferTooSmall;

        var i: usize = 0;
        for (base_prefix) |p| {
            buf[i] = p;
            i += 1;
        }
        // allowed_paths BEFORE workspace so that rw-bind on workspace
        // (typically a child of an allowed_path like /home/<user>) is applied
        // on top and wins at that mount point.
        for (self.allowed_paths) |path| {
            buf[i] = "--ro-bind-try";
            buf[i + 1] = path;
            buf[i + 2] = path;
            i += 3;
        }
        buf[i] = "--bind";
        buf[i + 1] = self.workspace_dir;
        buf[i + 2] = self.workspace_dir;
        i += 3;
        for (self.writable_paths) |path| {
            buf[i] = "--bind-try";
            buf[i + 1] = path;
            buf[i + 2] = path;
            i += 3;
        }
        for (base_suffix) |p| {
            buf[i] = p;
            i += 1;
        }
        for (argv) |arg| {
            buf[i] = arg;
            i += 1;
        }
        return buf[0..i];
    }

    fn isAvailable(_: *anyopaque) bool {
        if (comptime builtin.os.tag != .linux) return false;

        var child = std.process.Child.init(&.{ "bwrap", "--version" }, std.heap.page_allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stdin_behavior = .Ignore;
        child.spawn() catch return false;
        const term = child.wait() catch return false;
        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "bubblewrap";
    }

    fn getDescription(_: *anyopaque) []const u8 {
        return "User namespace sandbox (requires bwrap)";
    }
};

pub fn createBubblewrapSandbox(
    workspace_dir: []const u8,
    allowed_paths: []const []const u8,
    writable_paths: []const []const u8,
) BubblewrapSandbox {
    return .{
        .workspace_dir = workspace_dir,
        .allowed_paths = allowed_paths,
        .writable_paths = writable_paths,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "bubblewrap sandbox name" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();
    try std.testing.expectEqualStrings("bubblewrap", sb.name());
}

test "bubblewrap sandbox description mentions bwrap" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();
    const desc = sb.description();
    try std.testing.expect(std.mem.indexOf(u8, desc, "bwrap") != null);
}

test "bubblewrap sandbox wrap command prepends bwrap args" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();

    const argv = [_][]const u8{ "echo", "test" };
    var buf: [48][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    try std.testing.expectEqualStrings("bwrap", result[0]);
    try std.testing.expectEqualStrings("--ro-bind", result[1]);
    try std.testing.expectEqualStrings("/usr", result[2]);
    try std.testing.expectEqualStrings("/usr", result[3]);
    try std.testing.expectEqualStrings("--ro-bind-try", result[4]);
    try std.testing.expectEqualStrings("/bin", result[5]);
    try std.testing.expectEqualStrings("/bin", result[6]);
    // Original command is at the end
    try std.testing.expectEqualStrings("echo", result[result.len - 2]);
    try std.testing.expectEqualStrings("test", result[result.len - 1]);
}

test "bubblewrap sandbox wrap includes unshare and die-with-parent" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();

    const argv = [_][]const u8{"ls"};
    var buf: [48][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    var has_unshare_pid = false;
    var has_unshare_ipc = false;
    var has_die = false;
    for (result) |arg| {
        if (std.mem.eql(u8, arg, "--unshare-pid")) has_unshare_pid = true;
        if (std.mem.eql(u8, arg, "--unshare-ipc")) has_unshare_ipc = true;
        if (std.mem.eql(u8, arg, "--die-with-parent")) has_die = true;
    }
    try std.testing.expect(has_unshare_pid);
    try std.testing.expect(has_unshare_ipc);
    try std.testing.expect(has_die);
}

test "bubblewrap sandbox wrap empty argv" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();

    const argv = [_][]const u8{};
    var buf: [48][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    // Just the prefix args, no original command
    try std.testing.expectEqualStrings("bwrap", result[0]);
    try std.testing.expect(result.len == 38);
}

test "bubblewrap buffer too small returns error" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();

    const argv = [_][]const u8{ "echo", "test" };
    var buf: [3][]const u8 = undefined;
    const result = sb.wrapCommand(&argv, &buf);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "bubblewrap sandbox preserves workspace path for process cwd" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();

    const argv = [_][]const u8{ "/bin/sh", "-c", "printf test" };
    var buf: [48][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    // Regression: ShellTool sets cwd before spawning bwrap, so the workspace
    // must remain mounted at its original absolute path inside the sandbox.
    // Find the workspace bind in the result (position may shift with prefix changes)
    var ws_found = false;
    for (result, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--bind") and i + 2 < result.len and
            std.mem.eql(u8, result[i + 1], "/tmp/workspace"))
        {
            try std.testing.expectEqualStrings("/tmp/workspace", result[i + 2]);
            ws_found = true;
            break;
        }
    }
    try std.testing.expect(ws_found);
    try std.testing.expectEqualStrings("/bin/sh", result[result.len - 3]);
}

test "bubblewrap sandbox allowed_paths ro-bind precedes workspace rw-bind" {
    // Regression: with /home/user in allowed_paths and workspace inside /home/user,
    // the rw-bind of workspace must come AFTER the ro-bind of the parent so that
    // the child mount wins. Otherwise the workspace (and its .git) becomes read-only.
    const allowed = [_][]const u8{"/home/user"};
    var bw = createBubblewrapSandbox("/home/user/.nullclaw/workspace", &allowed, &.{});
    const sb = bw.sandbox();

    const argv = [_][]const u8{"true"};
    var buf: [64][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    var ro_home_idx: ?usize = null;
    var rw_ws_idx: ?usize = null;
    for (result, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--ro-bind-try") and idx + 2 < result.len and
            std.mem.eql(u8, result[idx + 1], "/home/user"))
        {
            ro_home_idx = idx;
        }
        if (std.mem.eql(u8, arg, "--bind") and idx + 2 < result.len and
            std.mem.eql(u8, result[idx + 1], "/home/user/.nullclaw/workspace"))
        {
            rw_ws_idx = idx;
        }
    }
    try std.testing.expect(ro_home_idx != null);
    try std.testing.expect(rw_ws_idx != null);
    try std.testing.expect(ro_home_idx.? < rw_ws_idx.?);
}

test "bubblewrap sandbox writable_paths bind-try after workspace" {
    const writable = [_][]const u8{"/mnt/nas/donna"};
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &writable);
    const sb = bw.sandbox();

    const argv = [_][]const u8{"true"};
    var buf: [64][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    var ws_idx: ?usize = null;
    var writable_idx: ?usize = null;
    for (result, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--bind") and idx + 2 < result.len and
            std.mem.eql(u8, result[idx + 1], "/tmp/workspace"))
        {
            ws_idx = idx;
        }
        if (std.mem.eql(u8, arg, "--bind-try") and idx + 2 < result.len and
            std.mem.eql(u8, result[idx + 1], "/mnt/nas/donna"))
        {
            writable_idx = idx;
        }
    }
    try std.testing.expect(ws_idx != null);
    try std.testing.expect(writable_idx != null);
    try std.testing.expect(ws_idx.? < writable_idx.?);
}

test "bubblewrap sandbox availability requires executable in PATH" {
    var bw = createBubblewrapSandbox("/tmp/workspace", &.{}, &.{});
    const sb = bw.sandbox();
    if (comptime builtin.os.tag != .linux) {
        try std.testing.expect(!sb.isAvailable());
        return;
    }

    const platform = @import("../platform.zig");
    const c = @cImport({
        @cInclude("stdlib.h");
    });

    const key_z = try std.testing.allocator.dupeZ(u8, "PATH");
    defer std.testing.allocator.free(key_z);

    const old_path = platform.getEnvOrNull(std.testing.allocator, "PATH");
    defer if (old_path) |path| std.testing.allocator.free(path);

    const old_path_z = if (old_path) |path| try std.testing.allocator.dupeZ(u8, path) else null;
    defer if (old_path_z) |path| std.testing.allocator.free(path);

    defer {
        if (old_path_z) |path| {
            _ = c.setenv(key_z.ptr, path.ptr, 1);
        } else {
            _ = c.unsetenv(key_z.ptr);
        }
    }

    const empty_z = try std.testing.allocator.dupeZ(u8, "");
    defer std.testing.allocator.free(empty_z);
    try std.testing.expectEqual(@as(c_int, 0), c.setenv(key_z.ptr, empty_z.ptr, 1));
    try std.testing.expect(!sb.isAvailable());
}
