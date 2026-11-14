//! Runtime configuration, resolved from flags and environment variables.
//!
//! Socket path, first match wins:
//!   1. --socket PATH
//!   2. $ZIGPOD_SOCKET
//!   3. $CONTAINER_HOST or $DOCKER_HOST, if it is a unix:// URL
//!   4. $XDG_RUNTIME_DIR/podman/podman.sock (rootless Podman), if it exists
//!   5. /run/podman/podman.sock (rootful Podman)
//!
//! Log directory, first match wins:
//!   1. $ZIGPOD_LOG_DIR
//!   2. ./ (current directory)
const std = @import("std");

pub const Config = struct {
    socket_path: []const u8,
    log_dir: []const u8,

    /// Loads configuration into freshly allocated strings owned by `allocator`.
    /// Call `deinit(allocator)` when no longer needed.
    pub fn load(allocator: std.mem.Allocator, socket_override: ?[]const u8) !Config {
        const socket_path = try resolveSocket(allocator, socket_override);
        errdefer allocator.free(socket_path);
        const log_dir = try resolveLogDir(allocator);
        return .{
            .socket_path = socket_path,
            .log_dir = log_dir,
        };
    }

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.socket_path);
        allocator.free(self.log_dir);
    }
};

fn getEnv(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => e,
    };
}

fn resolveSocket(allocator: std.mem.Allocator, socket_override: ?[]const u8) ![]const u8 {
    if (socket_override) |s| return allocator.dupe(u8, stripUnixScheme(s));
    if (try getEnv(allocator, "ZIGPOD_SOCKET")) |s| {
        defer allocator.free(s);
        return allocator.dupe(u8, stripUnixScheme(s));
    }

    inline for (.{ "CONTAINER_HOST", "DOCKER_HOST" }) |name| {
        if (try getEnv(allocator, name)) |s| {
            defer allocator.free(s);
            if (std.mem.startsWith(u8, s, "unix://")) {
                return allocator.dupe(u8, stripUnixScheme(s));
            }
            // Do not silently ignore a user-configured remote/other-scheme
            // host; say so before falling back to auto-detection.
            std.debug.print(
                "zigpod: warning: {s}='{s}' is not a unix:// socket; using auto-detected socket instead\n",
                .{ name, s },
            );
        }
    }

    if (try getEnv(allocator, "XDG_RUNTIME_DIR")) |dir| {
        defer allocator.free(dir);
        const rootless = try std.fs.path.join(allocator, &.{ dir, "podman", "podman.sock" });
        if (std.fs.accessAbsolute(rootless, .{})) |_| {
            return rootless;
        } else |_| {
            allocator.free(rootless);
        }
    }
    return allocator.dupe(u8, "/run/podman/podman.sock");
}

fn resolveLogDir(allocator: std.mem.Allocator) ![]const u8 {
    if (try getEnv(allocator, "ZIGPOD_LOG_DIR")) |d| return d;
    return allocator.dupe(u8, ".");
}

/// "unix:///run/podman/podman.sock" -> "/run/podman/podman.sock"
pub fn stripUnixScheme(s: []const u8) []const u8 {
    const prefix = "unix://";
    return if (std.mem.startsWith(u8, s, prefix)) s[prefix.len..] else s;
}

test "stripUnixScheme handles unix prefix, empty string, and plain paths" {
    try std.testing.expectEqualStrings("/run/podman/podman.sock", stripUnixScheme("unix:///run/podman/podman.sock"));
    try std.testing.expectEqualStrings("/", stripUnixScheme("unix:///"));
    try std.testing.expectEqualStrings("", stripUnixScheme("unix://"));
    try std.testing.expectEqualStrings("", stripUnixScheme(""));
    try std.testing.expectEqualStrings("/tmp/x.sock", stripUnixScheme("/tmp/x.sock"));
    try std.testing.expectEqualStrings("tcp://127.0.0.1:8080", stripUnixScheme("tcp://127.0.0.1:8080"));
}

test "socket override wins without leaking memory" {
    const cfg = try Config.load(std.testing.allocator, "unix:///tmp/custom.sock");
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/custom.sock", cfg.socket_path);
}

test "load without override frees intermediate env lookups" {
    const cfg = try Config.load(std.testing.allocator, null);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.socket_path.len > 0);
}

test "log_dir defaults to current directory" {
    const env_log = try getEnv(std.testing.allocator, "ZIGPOD_LOG_DIR");
    defer if (env_log) |d| std.testing.allocator.free(d);
    if (env_log == null) {
        const cfg = try Config.load(std.testing.allocator, null);
        defer cfg.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(".", cfg.log_dir);
    }
}
