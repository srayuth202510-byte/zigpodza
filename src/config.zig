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

pub const ConfigError = error{
    InsecureConfigFile,
    InvalidConfigValue,
};

fn validateConfigPathValue(val: []const u8, require_absolute: bool) ConfigError!void {
    if (val.len == 0 or val.len > 4096) return ConfigError.InvalidConfigValue;
    if (require_absolute and val[0] != '/') return ConfigError.InvalidConfigValue;
    for (val) |c| {
        if (c < 0x20 or c == 0x7f) return ConfigError.InvalidConfigValue;
    }
}

fn validateTomlConfig(cfg: TomlConfig) ConfigError!void {
    if (cfg.default_socket) |s| {
        try validateConfigPathValue(stripUnixScheme(s), true);
    }
    if (cfg.log_dir) |d| {
        try validateConfigPathValue(d, false);
    }
}

fn loadTomlFromDir(allocator: std.mem.Allocator, dir: std.fs.Dir, sub_path: []const u8) !?TomlConfig {
    // Reject symlinks, wrong owner, and group/world-writable config files (BUG-033).
    const fd = std.posix.openat(dir.fd, sub_path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.SymLinkLoop, error.IsDir, error.NotDir, error.AccessDenied => return ConfigError.InsecureConfigFile,
        else => return e,
    };
    const file = std.fs.File{ .handle = fd };
    defer file.close();

    const st = std.posix.fstat(fd) catch return ConfigError.InsecureConfigFile;
    if (!std.posix.S.ISREG(st.mode)) return ConfigError.InsecureConfigFile;
    if (st.uid != std.os.linux.getuid()) return ConfigError.InsecureConfigFile;
    if ((st.mode & 0o022) != 0) return ConfigError.InsecureConfigFile;

    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);
    const parsed = try parseToml(allocator, content);
    errdefer parsed.deinit(allocator);
    try validateTomlConfig(parsed);
    return parsed;
}

fn loadTomlFile(allocator: std.mem.Allocator, path: []const u8) !?TomlConfig {
    return loadTomlFromDir(allocator, std.fs.cwd(), path);
}

pub const Config = struct {
    socket_path: []const u8,
    log_dir: []const u8,
    verbose: bool = false,

    /// Loads configuration from CWD (`zigpod.toml` if present and trusted) +
    /// environment variables + CLI override. Call `deinit(allocator)` when done.
    pub fn load(allocator: std.mem.Allocator, socket_override: ?[]const u8) !Config {
        return loadFromDir(allocator, std.fs.cwd(), socket_override);
    }

    /// Loads configuration using `config_dir` as the base directory for `zigpod.toml`.
    pub fn loadFromDir(allocator: std.mem.Allocator, config_dir: std.fs.Dir, socket_override: ?[]const u8) !Config {
        const toml_opt = try loadTomlFromDir(allocator, config_dir, "zigpod.toml");
        defer if (toml_opt) |t| t.deinit(allocator);

        const socket_path = try resolveSocket(allocator, socket_override, toml_opt);
        errdefer allocator.free(socket_path);
        const log_dir = try resolveLogDir(allocator, toml_opt);
        const verbose = if (toml_opt) |t| (t.verbose orelse false) else false;
        return .{
            .socket_path = socket_path,
            .log_dir = log_dir,
            .verbose = verbose,
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
            const stripped = stripUnixScheme(s);
            if (stripped.len > 0 and !std.mem.eql(u8, stripped, "/run/podman/podman.sock")) {
                return allocator.dupe(u8, stripped);
            }
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

    if (toml_opt) |t| {
        if (t.default_socket) |s| {
            const stripped = stripUnixScheme(s);
            if (stripped.len > 0) return allocator.dupe(u8, stripped);
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

test "BUG-033: world-writable, group-writable, symlinked, or invalid zigpod.toml is rejected" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const evil_data =
        \\[socket]
        \\default_path = "unix:///tmp/attacker-sock.sock"
        \\
    ;
    const toml_file = try tmp.dir.createFile("zigpod.toml", .{});
    try toml_file.writeAll(evil_data);
    try toml_file.chmod(0o666);
    toml_file.close();

    // 1) World-writable (0666) must fail closed both directly and via Config.loadFromDir.
    const ww_path = try std.fs.path.join(alloc, &.{ dir_path, "zigpod.toml" });
    defer alloc.free(ww_path);
    try std.testing.expectError(ConfigError.InsecureConfigFile, loadTomlFile(alloc, ww_path));
    try std.testing.expectError(ConfigError.InsecureConfigFile, Config.loadFromDir(alloc, tmp.dir, null));

    // 2) Group-writable (0660) must also be rejected.
    const rw_f = try tmp.dir.openFile("zigpod.toml", .{});
    try rw_f.chmod(0o660);
    rw_f.close();
    try std.testing.expectError(ConfigError.InsecureConfigFile, Config.loadFromDir(alloc, tmp.dir, null));

    // 3) Symlinked zigpod.toml pointing to a 0600 target must be rejected.
    const real_file = try tmp.dir.createFile("real.toml", .{});
    try real_file.writeAll(evil_data);
    try real_file.chmod(0o600);
    real_file.close();
    try tmp.dir.symLink("real.toml", "sym.toml", .{});

    const sym_path = try std.fs.path.join(alloc, &.{ dir_path, "sym.toml" });
    defer alloc.free(sym_path);
    try std.testing.expectError(ConfigError.InsecureConfigFile, loadTomlFile(alloc, sym_path));

    // 4) Trusted 0600 file with non-absolute default_path must be rejected as InvalidConfigValue.
    const bad_val_file = try tmp.dir.createFile("zigpod.toml", .{});
    try bad_val_file.writeAll("[socket]\ndefault_path = \"relative.sock\"\n");
    try bad_val_file.chmod(0o600);
    bad_val_file.close();
    try std.testing.expectError(ConfigError.InvalidConfigValue, Config.loadFromDir(alloc, tmp.dir, null));

    // 5) Trusted 0600 file with valid absolute socket loads cleanly.
    const ok_file = try tmp.dir.createFile("zigpod.toml", .{});
    try ok_file.writeAll(evil_data);
    try ok_file.chmod(0o600);
    ok_file.close();
    const cfg = try Config.loadFromDir(alloc, tmp.dir, "unix:///tmp/override.sock");
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("/tmp/override.sock", cfg.socket_path);
}
