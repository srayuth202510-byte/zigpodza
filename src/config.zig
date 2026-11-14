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

pub const TomlConfig = struct {
    default_socket: ?[]u8 = null,
    log_dir: ?[]u8 = null,
    verbose: ?bool = null,

    pub fn deinit(self: TomlConfig, allocator: std.mem.Allocator) void {
        if (self.default_socket) |s| allocator.free(s);
        if (self.log_dir) |d| allocator.free(d);
    }
};

fn unquoteTomlString(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return null;
}

/// Minimal pure-Zig parser for `zigpod.toml` (`[socket]` and `[logging]` sections).
pub fn parseToml(allocator: std.mem.Allocator, content: []const u8) !TomlConfig {
    var out = TomlConfig{};
    errdefer out.deinit(allocator);

    var section: enum { root, socket, logging, other } = .root;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |hash| raw_line[0..hash] else raw_line;
        const line = std.mem.trim(u8, no_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            const sec = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            section = if (std.mem.eql(u8, sec, "socket"))
                .socket
            else if (std.mem.eql(u8, sec, "logging"))
                .logging
            else
                .other;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (section == .socket and std.mem.eql(u8, key, "default_path")) {
            if (unquoteTomlString(val)) |s| {
                if (out.default_socket) |old| allocator.free(old);
                out.default_socket = try allocator.dupe(u8, s);
            }
        } else if (section == .logging and std.mem.eql(u8, key, "log_dir")) {
            if (unquoteTomlString(val)) |s| {
                if (out.log_dir) |old| allocator.free(old);
                out.log_dir = try allocator.dupe(u8, s);
            }
        } else if (section == .logging and std.mem.eql(u8, key, "verbose")) {
            if (std.mem.eql(u8, val, "true")) {
                out.verbose = true;
            } else if (std.mem.eql(u8, val, "false")) {
                out.verbose = false;
            }
        }
    }
    return out;
}

fn loadTomlFile(allocator: std.mem.Allocator, path: []const u8) !?TomlConfig {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);
    return try parseToml(allocator, content);
}

pub const Config = struct {
    socket_path: []const u8,
    log_dir: []const u8,

    /// Loads configuration into freshly allocated strings owned by `allocator`.
    /// Call `deinit(allocator)` when no longer needed.
    pub fn load(allocator: std.mem.Allocator, socket_override: ?[]const u8) !Config {
        const toml_opt = loadTomlFile(allocator, "zigpod.toml") catch null;
        defer if (toml_opt) |t| t.deinit(allocator);

        const socket_path = try resolveSocket(allocator, socket_override, toml_opt);
        errdefer allocator.free(socket_path);
        const log_dir = try resolveLogDir(allocator, toml_opt);
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

fn resolveSocket(allocator: std.mem.Allocator, socket_override: ?[]const u8, toml_opt: ?TomlConfig) ![]const u8 {
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

    if (toml_opt) |t| {
        if (t.default_socket) |s| {
            if (s.len > 0) return allocator.dupe(u8, stripUnixScheme(s));
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

fn resolveLogDir(allocator: std.mem.Allocator, toml_opt: ?TomlConfig) ![]const u8 {
    if (try getEnv(allocator, "ZIGPOD_LOG_DIR")) |d| return d;
    if (toml_opt) |t| {
        if (t.log_dir) |d| {
            if (d.len > 0) return allocator.dupe(u8, d);
        }
    }
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

test "parseToml parses socket and logging sections without leaks" {
    const sample =
        \\# ZigPod config
        \\[socket]
        \\default_path = "unix:///tmp/custom-toml.sock" # inline comment
        \\
        \\[logging]
        \\log_dir = "/var/log/zigpod"
        \\verbose = true
    ;
    const parsed = try parseToml(std.testing.allocator, sample);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("unix:///tmp/custom-toml.sock", parsed.default_socket.?);
    try std.testing.expectEqualStrings("/var/log/zigpod", parsed.log_dir.?);
    try std.testing.expectEqual(true, parsed.verbose.?);
}
