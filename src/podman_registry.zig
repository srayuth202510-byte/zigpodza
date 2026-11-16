//! Registry authentication (`login` / `logout`).
//!
//! Credentials are verified by the daemon (`POST /auth`) and then stored in the
//! containers auth file that Podman itself reads (`$REGISTRY_AUTH_FILE`, else
//! `$XDG_RUNTIME_DIR/containers/auth.json`), so a local Podman service picks
//! them up for `push` / `pull` without zigpod ever sending a secret again.
//!
//! Secret hygiene (BUG-024): passwords are never accepted on argv, never
//! logged, and every buffer holding them is zeroed before it is freed. The
//! auth file is written atomically with mode 0600 and is refused when it is a
//! symlink, a non-regular file, foreign-owned, or not valid JSON.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const validate = @import("podman_validate.zig");
const th = @import("podman_test_helpers.zig");

const ApiError = types.ApiError;
const api_prefix = validate.api_prefix;
const logApiFailure = validate.logApiFailure;

pub const max_registry_bytes = 255;
pub const max_username_bytes = 256;
pub const max_password_bytes = 4096;
pub const max_auth_file_bytes = 1024 * 1024;

/// Validates a registry as `HOST[:PORT]`: RFC-1123 labels, optional decimal
/// port 1-65535. Schemes, paths, userinfo, and whitespace are rejected so the
/// value can be used verbatim as an auth-file key.
pub fn validateRegistry(reg: []const u8) ApiError!void {
    if (reg.len == 0 or reg.len > max_registry_bytes) return ApiError.InvalidRegistry;
    var host = reg;
    if (std.mem.lastIndexOfScalar(u8, reg, ':')) |c| {
        const port = reg[c + 1 ..];
        if (port.len == 0 or port.len > 5) return ApiError.InvalidRegistry;
        for (port) |ch| {
            if (!std.ascii.isDigit(ch)) return ApiError.InvalidRegistry;
        }
        const n = std.fmt.parseInt(u32, port, 10) catch return ApiError.InvalidRegistry;
        if (n == 0 or n > 65535) return ApiError.InvalidRegistry;
        host = reg[0..c];
    }
    if (host.len == 0) return ApiError.InvalidRegistry;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return ApiError.InvalidRegistry;
        if (label[0] == '-' or label[label.len - 1] == '-') return ApiError.InvalidRegistry;
        for (label) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-') return ApiError.InvalidRegistry;
        }
    }
}

/// Usernames are non-empty, at most 256 bytes, and contain no whitespace,
/// control bytes, or `:` (the basic-auth separator). Passwords are non-empty,
/// at most 4096 bytes, and contain no control bytes.
pub fn validateCredentials(username: []const u8, password: []const u8) ApiError!void {
    if (username.len == 0 or username.len > max_username_bytes) return ApiError.InvalidCredentials;
    for (username) |c| {
        if (c <= 0x20 or c == 0x7f or c == ':') return ApiError.InvalidCredentials;
    }
    if (password.len == 0 or password.len > max_password_bytes) return ApiError.InvalidCredentials;
    for (password) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidCredentials;
    }
}

pub const AuthFileLocation = struct {
    /// Absolute path of the auth file.
    path: []const u8,
    /// True for the default `$XDG_RUNTIME_DIR/containers/auth.json`, whose
    /// `containers` directory may be created (mode 0700) on first login.
    create_parent: bool,
};

fn getEnv(allocator: std.mem.Allocator, environ: std.process.Environ, name: []const u8) !?[]u8 {
    return environ.getAlloc(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return ApiError.InvalidAuthFile,
    };
}

fn validateAuthPath(path: []const u8) ApiError!void {
    if (path.len == 0 or path.len > utils.max_path_bytes) return ApiError.InvalidAuthFile;
    if (!std.fs.path.isAbsolute(path)) return ApiError.InvalidAuthFile;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return ApiError.InvalidAuthFile;
    }
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidAuthFile;
    }
    if (std.mem.endsWith(u8, path, "/")) return ApiError.InvalidAuthFile;
}

/// Resolves the auth file the same way Podman does. Caller owns `path`.
pub fn resolveAuthFile(allocator: std.mem.Allocator, environ: std.process.Environ) !AuthFileLocation {
    if (try getEnv(allocator, environ, "REGISTRY_AUTH_FILE")) |p| {
        if (p.len > 0) {
            errdefer allocator.free(p);
            try validateAuthPath(p);
            return .{ .path = p, .create_parent = false };
        }
        allocator.free(p);
    }
    const runtime = (try getEnv(allocator, environ, "XDG_RUNTIME_DIR")) orelse return ApiError.InvalidAuthFile;
    defer allocator.free(runtime);
    if (runtime.len == 0) return ApiError.InvalidAuthFile;
    const p = try std.fs.path.join(allocator, &.{ runtime, "containers", "auth.json" });
    errdefer allocator.free(p);
    try validateAuthPath(p);
    return .{ .path = p, .create_parent = true };
}

/// Opens the auth file's parent directory, which must be owned by the caller
/// and not group/world-writable (another user could otherwise swap the file).
fn openParentDir(io: std.Io, loc: AuthFileLocation, create: bool) !std.Io.Dir {
    try validateAuthPath(loc.path);
    const parent = std.fs.path.dirname(loc.path) orelse return ApiError.InvalidAuthFile;
    if (create and loc.create_parent) {
        const grand = std.fs.path.dirname(parent) orelse return ApiError.InvalidAuthFile;
        var g = std.Io.Dir.openDirAbsolute(io, grand, .{}) catch return ApiError.InvalidAuthFile;
        defer g.close(io);
        g.createDir(io, std.fs.path.basename(parent), .fromMode(0o700)) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return ApiError.InvalidAuthFile,
        };
    }
    const dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return ApiError.InvalidAuthFile,
    };
    errdefer dir.close(io);
    const st = log.statxFd(dir.handle) orelse return ApiError.InvalidAuthFile;
    if (!std.posix.S.ISDIR(st.mode)) return ApiError.InvalidAuthFile;
    if (st.uid != std.os.linux.getuid() or (st.mode & 0o022) != 0) return ApiError.InvalidAuthFile;
    return dir;
}

fn secureFree(allocator: std.mem.Allocator, buf: []u8) void {
    std.crypto.secureZero(u8, buf);
    allocator.free(buf);
}

/// Reads the existing auth file, or null when it does not exist. Symlinks,
/// FIFOs (opened non-blocking, BUG-048), non-regular and foreign-owned files
/// fail closed.
fn readExisting(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, base: []const u8) !?[]u8 {
    const fd = std.posix.openat(dir.handle, base, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    }, 0) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return ApiError.InvalidAuthFile,
    };
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    const st = log.statxFd(fd) orelse return ApiError.InvalidAuthFile;
    if (!std.posix.S.ISREG(st.mode) or st.uid != std.os.linux.getuid()) return ApiError.InvalidAuthFile;
    return utils.readFileToEndAlloc(io, file, allocator, max_auth_file_bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ApiError.InvalidAuthFile,
    };
}

/// Writes the auth document. Every top-level key other than `auths` and every
/// other registry entry is preserved. `registry == null` removes all entries;
/// `new_auth` (base64 `user:pass`) adds or replaces `registry`'s entry.
/// Returns whether an entry for `registry` (any entry, when null) existed.
fn renderAuthFile(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    registry: ?[]const u8,
    new_auth: ?[]const u8,
    out: *std.Io.Writer,
) !bool {
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |p| p.deinit();
    var root: ?std.json.ObjectMap = null;
    var auths: ?std.json.ObjectMap = null;
    if (existing) |raw| {
        if (std.mem.trim(u8, raw, " \t\r\n").len > 0) {
            parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return ApiError.InvalidAuthFile,
            };
            if (parsed.?.value != .object) return ApiError.InvalidAuthFile;
            root = parsed.?.value.object;
            if (root.?.get("auths")) |a| {
                if (a != .object) return ApiError.InvalidAuthFile;
                auths = a.object;
            }
        }
    }

    var jw: std.json.Stringify = .{ .writer = out, .options = .{ .whitespace = .indent_tab } };
    try jw.beginObject();
    if (root) |r| {
        var it = r.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "auths")) continue;
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.*);
        }
    }
    var found = false;
    try jw.objectField("auths");
    try jw.beginObject();
    if (auths) |a| {
        var it = a.iterator();
        while (it.next()) |e| {
            const drop = if (registry) |reg| std.mem.eql(u8, e.key_ptr.*, reg) else true;
            if (drop) {
                found = true;
                continue;
            }
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.*);
        }
    }
    if (new_auth) |na| {
        try jw.objectField(registry.?);
        try jw.beginObject();
        try jw.objectField("auth");
        try jw.write(na);
        try jw.endObject();
    }
    try jw.endObject();
    try jw.endObject();
    try out.writeByte('\n');
    return found;
}

/// Replaces `base` atomically with a fresh 0600 file.
fn writeAuthFile(io: std.Io, dir: std.Io.Dir, base: []const u8, content: []const u8) !void {
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    var name_buf: [32]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&name_buf, ".zigpod-auth-{s}", .{hex}) catch unreachable;

    const file = dir.createFile(io, tmp_name, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    }) catch return ApiError.InvalidAuthFile;
    var renamed = false;
    defer if (!renamed) dir.deleteFile(io, tmp_name) catch {};
    {
        defer file.close(io);
        file.writeStreamingAll(io, content) catch return ApiError.InvalidAuthFile;
    }
    std.Io.Dir.rename(dir, tmp_name, dir, base, io) catch return ApiError.InvalidAuthFile;
    renamed = true;
}

/// Reads a password from `file` (`--password-stdin`), stripping one trailing
/// `\n` or `\r\n`. Caller frees with `std.crypto.secureZero` + free.
pub fn readPassword(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) ![]u8 {
    var buf: [256]u8 = undefined;
    var r = file.readerStreaming(io, &buf);
    defer std.crypto.secureZero(u8, &buf);
    const raw = r.interface.allocRemaining(allocator, .limited(max_password_bytes + 3)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ApiError.InvalidCredentials,
    };
    var len = raw.len;
    if (len > 0 and raw[len - 1] == '\n') len -= 1;
    if (len > 0 and raw[len - 1] == '\r') len -= 1;
    if (len == 0 or len > max_password_bytes) {
        secureFree(allocator, raw);
        return ApiError.InvalidCredentials;
    }
    std.crypto.secureZero(u8, raw[len..]);
    return allocator.realloc(raw, len) catch raw[0..len];
}

/// Prompts on the terminal with echo disabled. Fails with InvalidCredentials
/// when `in_fd` is not a TTY (scripts must use `--password-stdin`).
pub fn promptPassword(allocator: std.mem.Allocator, in_fd: std.posix.fd_t, prompt_out: *std.Io.Writer) ![]u8 {
    const orig = std.posix.tcgetattr(in_fd) catch return ApiError.InvalidCredentials;
    var quiet = orig;
    quiet.lflag.ECHO = false;
    std.posix.tcsetattr(in_fd, .FLUSH, quiet) catch return ApiError.InvalidCredentials;
    defer std.posix.tcsetattr(in_fd, .FLUSH, orig) catch {};
    prompt_out.writeAll("Password: ") catch {};
    prompt_out.flush() catch {};
    defer {
        prompt_out.writeAll("\n") catch {};
        prompt_out.flush() catch {};
    }

    var line: [max_password_bytes + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &line);
    var len: usize = 0;
    while (true) {
        if (len == line.len) return ApiError.InvalidCredentials;
        const rc = std.os.linux.read(in_fd, line[len..].ptr, 1);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return ApiError.InvalidCredentials,
        }
        if (rc == 0) break;
        if (line[len] == '\n') break;
        len += 1;
    }
    if (len > 0 and line[len - 1] == '\r') len -= 1;
    if (len == 0) return ApiError.InvalidCredentials;
    return allocator.dupe(u8, line[0..len]);
}

const AuthRequest = struct {
    username: []const u8,
    password: []const u8,
    serveraddress: []const u8,
};

/// Verifies credentials through the daemon and stores them in the auth file.
pub fn login(
    client: *const http.Client,
    logger: *log.Logger,
    loc: AuthFileLocation,
    registry: []const u8,
    username: []const u8,
    password: []const u8,
    writer: anytype,
) !void {
    const io = client.io;
    const alloc = client.allocator;
    try validateRegistry(registry);
    try validateCredentials(username, password);

    // Refuse an unusable auth file before any credential leaves the process.
    var dir = try openParentDir(io, loc, true);
    defer dir.close(io);
    const base = std.fs.path.basename(loc.path);
    const existing = try readExisting(io, alloc, dir, base);
    defer if (existing) |e| secureFree(alloc, e);
    {
        var discard: std.Io.Writer.Discarding = .init(&.{});
        _ = try renderAuthFile(alloc, existing, registry, null, &discard.writer);
    }

    const body = try std.json.Stringify.valueAlloc(alloc, AuthRequest{
        .username = username,
        .password = password,
        .serveraddress = registry,
    }, .{});
    defer secureFree(alloc, body);

    const path = api_prefix ++ "/auth";
    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, body);
    defer resp.deinit();
    if (!resp.ok()) {
        logger.err("login to {s} failed", .{registry});
        return logApiFailure(logger, "POST", path, resp);
    }

    const plain = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ username, password });
    defer secureFree(alloc, plain);
    const encoder = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(plain.len));
    defer secureFree(alloc, encoded);
    _ = encoder.encode(encoded, plain);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer {
        std.crypto.secureZero(u8, out.writer.buffer);
        out.deinit();
    }
    _ = try renderAuthFile(alloc, existing, registry, encoded, &out.writer);
    try writeAuthFile(io, dir, base, out.written());

    try writer.writeAll("Login Succeeded!\n");
    logger.info("logged in to registry {s}", .{registry});
}

/// Removes stored credentials for `registry`, or for every registry when null.
pub fn logout(
    io: std.Io,
    allocator: std.mem.Allocator,
    logger: *log.Logger,
    loc: AuthFileLocation,
    registry: ?[]const u8,
    writer: anytype,
) !void {
    if (registry) |r| try validateRegistry(r);

    var dir = openParentDir(io, loc, false) catch |e| switch (e) {
        error.FileNotFound => return notLoggedIn(logger, registry, writer),
        else => return e,
    };
    defer dir.close(io);
    const base = std.fs.path.basename(loc.path);
    const existing = (try readExisting(io, allocator, dir, base)) orelse
        return notLoggedIn(logger, registry, writer);
    defer secureFree(allocator, existing);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, out.writer.buffer);
        out.deinit();
    }
    const found = try renderAuthFile(allocator, existing, registry, null, &out.writer);
    if (!found) return notLoggedIn(logger, registry, writer);
    try writeAuthFile(io, dir, base, out.written());

    if (registry) |r| {
        try writer.print("Removed login credentials for {s}\n", .{r});
        logger.info("logged out of registry {s}", .{r});
    } else {
        try writer.writeAll("Removed login credentials for all registries\n");
        logger.info("logged out of all registries", .{});
    }
}

fn notLoggedIn(logger: *log.Logger, registry: ?[]const u8, writer: anytype) !void {
    if (registry) |r| {
        logger.err("not logged into {s}", .{r});
        return ApiError.NotLoggedIn;
    }
    // `logout --all` with nothing stored is a successful no-op.
    try writer.writeAll("Removed login credentials for all registries\n");
}

// ---------------------------------------------------------------- tests

test "validateRegistry accepts host[:port] and rejects everything else" {
    const ok = [_][]const u8{ "docker.io", "quay.io", "localhost", "localhost:5000", "my-reg.example.com:443", "10.0.0.1:5000" };
    for (ok) |r| try validateRegistry(r);
    const too_long: [256]u8 = @splat('a');
    const bad = [_][]const u8{
        "",                  "https://docker.io", "docker.io/library", "user@host",       "host:",
        "host:0",            "host:65536",        "host:+80",          "host:123456",     ":5000",
        "-bad.io",           "bad-.io",           "a..b",              ".io",             "io.",
        "host name",         "host\nx",           "[::1]:5000",        "ho_st",           &too_long,
    };
    for (bad) |r| try std.testing.expectError(ApiError.InvalidRegistry, validateRegistry(r));
}

test "validateCredentials bounds and rejects separators and control bytes" {
    try validateCredentials("alice", "pa ss:word!");
    const long_user: [max_username_bytes + 1]u8 = @splat('u');
    const long_pass: [max_password_bytes + 1]u8 = @splat('p');
    const max_pass: [max_password_bytes]u8 = @splat('p');
    try validateCredentials("u", &max_pass);
    const bad = [_][2][]const u8{
        .{ "", "pw" },        .{ "a:b", "pw" },     .{ "a b", "pw" },  .{ "a\x00", "pw" },
        .{ "alice", "" },     .{ "alice", "p\nw" }, .{ "alice", "\x7f" }, .{ &long_user, "pw" },
        .{ "alice", &long_pass },
    };
    for (bad) |c| try std.testing.expectError(ApiError.InvalidCredentials, validateCredentials(c[0], c[1]));
}

test "validateAuthPath rejects relative, traversal, and control paths" {
    try validateAuthPath("/run/user/1000/containers/auth.json");
    const bad = [_][]const u8{ "", "auth.json", "/a/../auth.json", "/a/./auth.json", "/a/b/", "/a/\x01" };
    for (bad) |p| try std.testing.expectError(ApiError.InvalidAuthFile, validateAuthPath(p));
}

test "renderAuthFile preserves other keys and entries, adds and removes" {
    const alloc = std.testing.allocator;
    const existing =
        \\{"auths":{"quay.io":{"auth":"cXVheTp4"},"docker.io":{"auth":"b2xkOm9sZA=="}},"credHelpers":{"gcr.io":"gcloud"}}
    ;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Replace docker.io, keep quay.io and credHelpers.
    try std.testing.expect(try renderAuthFile(alloc, existing, "docker.io", "bmV3Om5ldw==", &out.writer));
    {
        const p = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
        defer p.deinit();
        const auths = p.value.object.get("auths").?.object;
        try std.testing.expectEqualStrings("bmV3Om5ldw==", auths.get("docker.io").?.object.get("auth").?.string);
        try std.testing.expectEqualStrings("cXVheTp4", auths.get("quay.io").?.object.get("auth").?.string);
        try std.testing.expectEqualStrings("gcloud", p.value.object.get("credHelpers").?.object.get("gcr.io").?.string);
    }
    out.clearRetainingCapacity();

    // Remove one; a missing registry reports not found.
    try std.testing.expect(try renderAuthFile(alloc, existing, "quay.io", null, &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "quay.io") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "docker.io") != null);
    out.clearRetainingCapacity();
    try std.testing.expect(!try renderAuthFile(alloc, existing, "ghcr.io", null, &out.writer));
    out.clearRetainingCapacity();

    // Remove all.
    try std.testing.expect(try renderAuthFile(alloc, existing, null, null, &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"auth\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "credHelpers") != null);
    out.clearRetainingCapacity();

    // Fresh / empty file.
    try std.testing.expect(!try renderAuthFile(alloc, null, "localhost:5000", "eDp5", &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"localhost:5000\"") != null);
    out.clearRetainingCapacity();
    try std.testing.expect(!try renderAuthFile(alloc, " \n", "localhost:5000", "eDp5", &out.writer));
    out.clearRetainingCapacity();

    // Malformed documents fail closed instead of being overwritten.
    const malformed = [_][]const u8{ "{", "[]", "\"x\"", "{\"auths\":[]}", "{\"auths\":\"x\"}" };
    for (malformed) |m| {
        try std.testing.expectError(ApiError.InvalidAuthFile, renderAuthFile(alloc, m, "docker.io", "eDp5", &out.writer));
        out.clearRetainingCapacity();
    }
}

test "renderAuthFile handles allocation failure without leaking" {
    const existing = "{\"auths\":{\"quay.io\":{\"auth\":\"cXVheTp4\"}},\"x\":[1,2,{\"y\":null}]}";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            // The Allocating writer reports its OOM as WriteFailed.
            _ = renderAuthFile(alloc, existing, "docker.io", "eDp5", &out.writer) catch |e| switch (e) {
                error.WriteFailed => return error.OutOfMemory,
                else => return e,
            };
        }
    }.run, .{});
}

fn tmpLocation(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) !AuthFileLocation {
    const dir_path = try utils.realpathAlloc(std.testing.io, tmp.dir, ".", alloc);
    defer alloc.free(dir_path);
    return .{ .path = try std.fs.path.join(alloc, &.{ dir_path, name }), .create_parent = false };
}

test "readExisting refuses symlinks, FIFOs, and directories" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect((try readExisting(io, alloc, tmp.dir, "missing.json")) == null);

    const f = try tmp.dir.createFile(io, "real.json", .{});
    try f.writeStreamingAll(io, "{}");
    f.close(io);
    const got = (try readExisting(io, alloc, tmp.dir, "real.json")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("{}", got);

    try tmp.dir.symLink(io, "real.json", "link.json", .{});
    try std.testing.expectError(ApiError.InvalidAuthFile, readExisting(io, alloc, tmp.dir, "link.json"));

    const rc = std.os.linux.mknodat(tmp.dir.handle, "fifo.json", std.os.linux.S.IFIFO | 0o600, 0);
    try std.testing.expect(std.os.linux.errno(rc) == .SUCCESS);
    try std.testing.expectError(ApiError.InvalidAuthFile, readExisting(io, alloc, tmp.dir, "fifo.json"));

    try tmp.dir.createDir(io, "sub", .default_dir);
    try std.testing.expectError(ApiError.InvalidAuthFile, readExisting(io, alloc, tmp.dir, "sub"));
}

test "readPassword strips one newline and enforces bounds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]struct { in: []const u8, want: ?[]const u8 }{
        .{ .in = "s3cret\n", .want = "s3cret" },
        .{ .in = "s3cret\r\n", .want = "s3cret" },
        .{ .in = "s3cret", .want = "s3cret" },
        .{ .in = "two\n\n", .want = "two\n" },
        .{ .in = "", .want = null },
        .{ .in = "\n", .want = null },
    };
    for (cases) |c| {
        const f = try tmp.dir.createFile(io, "pw", .{ .read = true });
        defer f.close(io);
        try f.writeStreamingAll(io, c.in);
        const rf = try tmp.dir.openFile(io, "pw", .{});
        defer rf.close(io);
        if (c.want) |w| {
            const got = try readPassword(io, alloc, rf);
            defer alloc.free(got);
            try std.testing.expectEqualStrings(w, got);
        } else {
            try std.testing.expectError(ApiError.InvalidCredentials, readPassword(io, alloc, rf));
        }
    }

    const big: [max_password_bytes + 1]u8 = @splat('p');
    {
        const f = try tmp.dir.createFile(io, "pw", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, &big);
    }
    const rf = try tmp.dir.openFile(io, "pw", .{});
    defer rf.close(io);
    try std.testing.expectError(ApiError.InvalidCredentials, readPassword(io, alloc, rf));

    // A non-TTY cannot be prompted.
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(ApiError.InvalidCredentials, promptPassword(alloc, rf.handle, &sink.writer));
}

test "login verifies via daemon then writes a 0600 auth file; logout removes entries" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const loc = try tmpLocation(alloc, &tmp, "auth.json");
    defer alloc.free(loc.path);

    // Pre-existing foreign entry must survive.
    {
        const f = try tmp.dir.createFile(io, "auth.json", .{ .permissions = .fromMode(0o644) });
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"auths\":{\"quay.io\":{\"auth\":\"cXVheTp4\"}}}");
    }

    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-login-{d}.sock", .{std.Io.Clock.awake.now(io).nanoseconds});
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, sock_path) catch {};
    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(io, .{});
    defer server.deinit(io);

    const ok_body = "{\"Status\":\"Login Succeeded\"}";
    const denied = "{\"message\":\"unauthorized\"}";
    const replies = [_]th.ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/auth HTTP/1.1\r\n",
            .expected_substring = "{\"username\":\"alice\",\"password\":\"pa ss\",\"serveraddress\":\"localhost:5000\"}",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ ok_body.len, ok_body }),
        },
        .{
            .expected_prefix = "POST /v1.40/auth HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 401 Unauthorized\r\nContent-Length: {d}\r\n\r\n{s}", .{ denied.len, denied }),
        },
    };
    var ctx = th.MockApiCtx{ .io = io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, th.runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = io };
    var logger = log.Logger{ .io = io, .echo_stderr = false };
    defer logger.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Invalid input never reaches the socket.
    try std.testing.expectError(ApiError.InvalidRegistry, login(&client, &logger, loc, "https://x", "alice", "pw", &out.writer));
    try std.testing.expectError(ApiError.InvalidCredentials, login(&client, &logger, loc, "localhost:5000", "a:b", "pw", &out.writer));

    try login(&client, &logger, loc, "localhost:5000", "alice", "pa ss", &out.writer);
    try std.testing.expectEqualStrings("Login Succeeded!\n", out.written());
    out.clearRetainingCapacity();

    const st = try tmp.dir.statFile(io, "auth.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    {
        const raw = (try readExisting(io, alloc, tmp.dir, "auth.json")).?;
        defer alloc.free(raw);
        // base64("alice:pa ss") == "YWxpY2U6cGEgc3M="
        try std.testing.expect(std.mem.indexOf(u8, raw, "\"YWxpY2U6cGEgc3M=\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "\"quay.io\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "pa ss") == null);
    }

    // Daemon rejection leaves the file untouched.
    try std.testing.expectError(ApiError.PodmanApiError, login(&client, &logger, loc, "docker.io", "bob", "bad", &out.writer));
    {
        const raw = (try readExisting(io, alloc, tmp.dir, "auth.json")).?;
        defer alloc.free(raw);
        try std.testing.expect(std.mem.indexOf(u8, raw, "docker.io") == null);
    }

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);

    // logout
    try std.testing.expectError(ApiError.NotLoggedIn, logout(io, alloc, &logger, loc, "ghcr.io", &out.writer));
    try logout(io, alloc, &logger, loc, "localhost:5000", &out.writer);
    try std.testing.expectEqualStrings("Removed login credentials for localhost:5000\n", out.written());
    try std.testing.expectError(ApiError.NotLoggedIn, logout(io, alloc, &logger, loc, "localhost:5000", &out.writer));
    out.clearRetainingCapacity();
    try logout(io, alloc, &logger, loc, null, &out.writer);
    {
        const raw = (try readExisting(io, alloc, tmp.dir, "auth.json")).?;
        defer alloc.free(raw);
        try std.testing.expect(std.mem.indexOf(u8, raw, "quay.io") == null);
    }
    // No temp files are left behind.
    var it = tmp.dir.iterate();
    while (try it.next(io)) |e| try std.testing.expect(!std.mem.startsWith(u8, e.name, ".zigpod-auth-"));
}

test "login and logout refuse an unsafe or malformed auth file before network I/O" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No socket exists: any network attempt would fail with a socket error,
    // so InvalidAuthFile proves the check ran first.
    const client = http.Client{ .allocator = alloc, .socket_path = "/nonexistent/zp.sock", .io = io };
    var logger = log.Logger{ .io = io, .echo_stderr = false };
    defer logger.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    {
        const f = try tmp.dir.createFile(io, "bad.json", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{not json");
    }
    const bad = try tmpLocation(alloc, &tmp, "bad.json");
    defer alloc.free(bad.path);
    try std.testing.expectError(ApiError.InvalidAuthFile, login(&client, &logger, bad, "docker.io", "u", "p", &out.writer));
    try std.testing.expectError(ApiError.InvalidAuthFile, logout(io, alloc, &logger, bad, "docker.io", &out.writer));

    try tmp.dir.symLink(io, "/etc/passwd", "link.json", .{});
    const link = try tmpLocation(alloc, &tmp, "link.json");
    defer alloc.free(link.path);
    try std.testing.expectError(ApiError.InvalidAuthFile, login(&client, &logger, link, "docker.io", "u", "p", &out.writer));

    // Group/world-writable parent directory.
    try tmp.dir.createDir(io, "open", .fromMode(0o777));
    try tmp.dir.setFilePermissions(io, "open", .fromMode(0o777), .{});
    const open_loc = try tmpLocation(alloc, &tmp, "open/auth.json");
    defer alloc.free(open_loc.path);
    try std.testing.expectError(ApiError.InvalidAuthFile, login(&client, &logger, open_loc, "docker.io", "u", "p", &out.writer));

    // Missing parent: logout is "not logged in", logout --all is a no-op.
    const gone = try tmpLocation(alloc, &tmp, "gone/auth.json");
    defer alloc.free(gone.path);
    try std.testing.expectError(ApiError.NotLoggedIn, logout(io, alloc, &logger, gone, "docker.io", &out.writer));
    try logout(io, alloc, &logger, gone, null, &out.writer);
}
