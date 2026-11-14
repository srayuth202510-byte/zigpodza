//! Input, path, port, identity, and signal validation for Podman API requests.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
pub const types = @import("podman_types.zig");

pub const api_prefix = "/v1.40";

pub const ApiError = types.ApiError;
pub const TmpfsBounds = types.TmpfsBounds;
pub const HostConfig = types.HostConfig;
pub const Mount = types.Mount;
pub const PortMapping = types.PortMapping;
pub const ExposedPorts = types.ExposedPorts;
pub const PortBindings = types.PortBindings;
pub const ContainerCreateRequest = types.ContainerCreateRequest;

/// Validates a container ID or name to prevent path traversal, query injection,
/// and HTTP request-line tampering.
pub fn validateIdentifier(id: []const u8) ApiError!void {
    if (id.len == 0 or id.len > 128) return ApiError.InvalidIdentifier;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return ApiError.InvalidIdentifier;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':') continue;
        return ApiError.InvalidIdentifier;
    }
}

/// Validates a container/image reference used inside an inspect URL path.
/// Allows image-reference characters (including `/` and `:`) while rejecting
/// control chars, URL delimiters that could alter the request line, and any
/// `..` path segment that could escape the API prefix (BUG-021).
pub fn validateResourceRef(ref: []const u8) ApiError!void {
    if (ref.len == 0 or ref.len > 256) return ApiError.InvalidIdentifier;
    if (std.mem.eql(u8, ref, ".") or std.mem.eql(u8, ref, "..")) return ApiError.InvalidIdentifier;
    var segments = std.mem.splitScalar(u8, ref, '/');
    while (segments.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return ApiError.InvalidIdentifier;
    }
    for (ref) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':' or c == '/' or c == '@') continue;
        return ApiError.InvalidIdentifier;
    }
}

/// Host directories whose subtree must never be bind-mounted into a container.
/// Matched as `path == prefix` or `path` living under `prefix/`.
const blocked_host_prefixes = [_][]const u8{
    "/proc",
    "/sys",
    "/dev",
    "/boot",
    "/run",
    "/var/run",
    "/var/lib/docker",
    "/var/lib/containers",
    "/etc",
    "/root",
};

/// Specific `/etc` files that are safe to bind-mount, but only read-only.
const safe_etc_files = [_][]const u8{
    "/etc/localtime",
    "/etc/timezone",
    "/etc/hosts",
    "/etc/resolv.conf",
    "/etc/nsswitch.conf",
    "/etc/hostname",
};

/// True when `path` equals `prefix` or is a descendant of `prefix/`.
fn isUnder(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// Rejects empty, relative, over-long, control-char, `..`/`.`-containing, and
/// `//`/trailing-slash paths. Used for both host sources and container targets.
fn validateAbsolutePath(path: []const u8) ApiError!void {
    if (path.len == 0 or path.len > 4096) return ApiError.InvalidHostPath;
    if (path[0] != '/') return ApiError.InvalidHostPath;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidHostPath;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next(); // leading empty component produced by the root slash
    while (it.next()) |comp| {
        if (comp.len == 0) return ApiError.InvalidHostPath; // "//" or trailing "/"
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return ApiError.InvalidHostPath;
    }
}

/// Fail-closed host-path policy for bind mounts (BUG-014). Rejects dangerous
/// system roots, traversal, and read-write mounts of sensitive `/etc` files.
pub fn validateHostPath(path: []const u8, readonly: bool) ApiError!void {
    try validateAbsolutePath(path);

    for (safe_etc_files) |f| {
        if (std.mem.eql(u8, path, f)) {
            if (!readonly) return ApiError.InvalidHostPath;
            return;
        }
    }
    for (blocked_host_prefixes) |prefix| {
        if (isUnder(path, prefix)) return ApiError.InvalidHostPath;
    }
}

/// Validates the in-container mount destination (must be an absolute,
/// traversal-free path).
pub fn validateContainerPath(path: []const u8) ApiError!void {
    return validateAbsolutePath(path) catch ApiError.InvalidMountTarget;
}

/// Validates a Podman named volume (no host path involved).
pub fn validateVolumeName(name: []const u8) ApiError!void {
    if (name.len == 0 or name.len > 128) return ApiError.InvalidHostPath;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return ApiError.InvalidHostPath;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return ApiError.InvalidHostPath;
    }
}

/// Classifies and validates a `-v` mount: absolute sources become `bind`
/// mounts (policy-checked), everything else a named `volume`.
pub fn makeMount(source: []const u8, target: []const u8, readonly: bool) ApiError!Mount {
    try validateContainerPath(target);
    if (std.mem.startsWith(u8, source, "/")) {
        try validateHostPath(source, readonly);
        return .{ .Type = "bind", .Source = source, .Target = target, .ReadOnly = readonly };
    }
    try validateVolumeName(source);
    return .{ .Type = "volume", .Source = source, .Target = target, .ReadOnly = readonly };
}

pub fn validateMount(m: Mount) ApiError!void {
    if (std.mem.eql(u8, m.Type, "bind")) {
        try validateHostPath(m.Source, m.ReadOnly);
    } else if (std.mem.eql(u8, m.Type, "volume")) {
        try validateVolumeName(m.Source);
    } else {
        return ApiError.InvalidHostPath;
    }
    try validateContainerPath(m.Target);
}

/// Validates a published port: container/host ports are 1..65535, the protocol
/// is tcp/udp/sctp, and any host address must be a valid IPv4 literal (BUG-015).
pub fn validatePortMapping(p: PortMapping) ApiError!void {
    if (p.container_port == 0) return ApiError.InvalidPort;
    if (p.host_port) |hp| {
        if (hp == 0) return ApiError.InvalidPort;
    }
    if (!(std.mem.eql(u8, p.proto, "tcp") or std.mem.eql(u8, p.proto, "udp") or std.mem.eql(u8, p.proto, "sctp"))) {
        return ApiError.InvalidPort;
    }
    if (p.host_ip) |ip| {
        _ = std.net.Address.parseIp4(ip, 0) catch return ApiError.InvalidPort;
    }
}

/// Validates and constructs a `PortMapping` (defense-in-depth re-check used by
/// `main` before the request is serialized).
pub fn makePortMapping(
    host_ip: ?[]const u8,
    host_port: ?u16,
    container_port: u16,
    proto: []const u8,
) ApiError!PortMapping {
    const mapping = PortMapping{
        .host_ip = host_ip,
        .host_port = host_port,
        .container_port = container_port,
        .proto = proto,
    };
    try validatePortMapping(mapping);
    return mapping;
}

/// Network modes accepted for `--network` (BUG-016). Any other value is
/// rejected so the daemon never receives an unexpected network configuration.
const allowed_network_modes = [_][]const u8{ "none", "bridge", "host", "pasta", "slirp4netns" };

pub fn validateNetworkMode(mode: []const u8) ApiError!void {
    for (allowed_network_modes) |m| {
        if (std.mem.eql(u8, mode, m)) return;
    }
    return ApiError.InvalidNetwork;
}

/// Validates the in-container working directory (same path policy as mount
/// targets: absolute, traversal-free, control-char-free, ≤ 4096 bytes).
pub fn validateWorkdir(path: []const u8) ApiError!void {
    validateAbsolutePath(path) catch return ApiError.InvalidWorkdir;
}

/// Validates `USER[:GROUP]`: one or two non-empty fields of alphanumerics plus
/// `_`, `-`, `.`, each not starting with `-`/`.` (BUG-016).
pub fn validateUser(user: []const u8) ApiError!void {
    if (user.len == 0 or user.len > 128) return ApiError.InvalidUser;
    var it = std.mem.splitScalar(u8, user, ':');
    var fields: usize = 0;
    while (it.next()) |field| {
        fields += 1;
        if (fields > 2) return ApiError.InvalidUser;
        if (field.len == 0 or field.len > 64) return ApiError.InvalidUser;
        for (field, 0..) |c, idx| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
                if (idx == 0 and (c == '-' or c == '.')) return ApiError.InvalidUser;
                continue;
            }
            return ApiError.InvalidUser;
        }
    }
    return;
}

/// Validates a Linux capability name: `ALL` or an uppercase `[A-Z][A-Z0-9_]*`
/// token (BUG-016). Rejects injection characters and lowercase names.
pub fn validateCapability(cap: []const u8) ApiError!void {
    if (cap.len == 0 or cap.len > 64) return ApiError.InvalidCapability;
    if (std.mem.eql(u8, cap, "ALL")) return;
    if (!std.ascii.isUpper(cap[0])) return ApiError.InvalidCapability;
    for (cap) |c| {
        if (std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_') continue;
        return ApiError.InvalidCapability;
    }
}

/// Signals accepted by `zigpod kill -s` (`POST /containers/{id}/kill?signal=...`).
/// Restricted to a strict allow-list so arbitrary query strings cannot reach the daemon.
const allowed_signals = [_][]const u8{
    "SIGTERM",
    "SIGKILL",
    "SIGINT",
    "SIGHUP",
    "SIGQUIT",
    "SIGUSR1",
    "SIGUSR2",
    "TERM",
    "KILL",
    "INT",
    "HUP",
    "QUIT",
    "USR1",
    "USR2",
};

pub fn validateSignal(sig: []const u8) ApiError!void {
    for (allowed_signals) |s| {
        if (std.mem.eql(u8, sig, s)) return;
    }
    return ApiError.InvalidSignal;
}

pub fn appendQueryEncoded(out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(c);
        } else {
            try out.writer().print("%{X:0>2}", .{c});
        }
    }
}

pub fn logApiFailure(logger: *log.Logger, method: []const u8, path: []const u8, resp: http.Response) ApiError {
    const trimmed = std.mem.trim(u8, resp.body, " \r\n\t");
    if (trimmed.len > 0) {
        logger.err("API {s} {s} failed (HTTP {d}): {s}", .{ method, path, resp.status, trimmed });
    } else {
        logger.err("API {s} {s} failed (HTTP {d})", .{ method, path, resp.status });
    }
    return ApiError.PodmanApiError;
}


pub fn formatSizeU64(buf: []u8, bytes: u64) []const u8 {
    const clamped: i64 = if (bytes > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(bytes);
    return utils.formatSize(buf, clamped);
}

// ---------------------------------------------------------------- tests

test "validateIdentifier rejects traversal, injection, and invalid sizes" {
    try validateIdentifier("abcdef123456");
    try validateIdentifier("web-1");
    try validateIdentifier("my_container.service");
    try validateIdentifier("sha256:abcdef0123");

    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier(""));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("."));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier(".."));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("../containers"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("abc/def"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("id?force=true"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("id#frag"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("id\r\nX-Evil: 1"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("has space"));

    const too_long = "a" ** 129;
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier(too_long));
}

test "validateHostPath enforces the fail-closed bind-mount policy" {
    try validateHostPath("/home/user/data", true);
    try validateHostPath("/home/user/data", false);
    try validateHostPath("/srv/app", false);
    try validateHostPath("/etc/hosts", true);
    try validateHostPath("/etc/localtime", true);

    const bad = [_][]const u8{
        "",               "relative/path",        "/",
        "/etc",           "/etc/passwd",          "/etc/ssh",
        "/proc",          "/proc/1",              "/sys",
        "/dev",           "/dev/sda",             "/boot",
        "/run",           "/run/podman/podman.sock",
        "/var/run/docker.sock",                    "/root",
        "/root/.ssh",     "/var/lib/docker",      "/var/lib/containers",
        "/home/user/../etc", "/home/user/..",     "/home//user",
        "/srv/data/",     "/etc/../etc/hosts",
    };
    for (bad) |p| {
        try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath(p, true));
    }

    // Sensitive /etc files may only be mounted read-only.
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath("/etc/hosts", false));
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath("/etc/resolv.conf", false));
    // Control characters are rejected.
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath("/srv/\x00evil", true));
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath("/srv/a\nb", true));
}

test "makeMount classifies bind vs named volume and validates the target" {
    const b = try makeMount("/srv/data", "/data", true);
    try std.testing.expectEqualStrings("bind", b.Type);
    try std.testing.expectEqualStrings("/srv/data", b.Source);
    try std.testing.expectEqualStrings("/data", b.Target);
    try std.testing.expect(b.ReadOnly);

    const v = try makeMount("myvol", "/var/lib/data", false);
    try std.testing.expectEqualStrings("volume", v.Type);
    try std.testing.expect(!v.ReadOnly);

    try std.testing.expectError(ApiError.InvalidHostPath, makeMount("/etc", "/data", true));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount("../evil", "/data", true));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount("bad/name", "/data", true));
    try std.testing.expectError(ApiError.InvalidMountTarget, makeMount("/srv/data", "data", true));
    try std.testing.expectError(ApiError.InvalidMountTarget, makeMount("/srv/data", "/data/../etc", true));
}

test "ContainerCreateRequest serializes bind mounts" {
    const alloc = std.testing.allocator;
    const mounts = [_]Mount{
        .{ .Type = "bind", .Source = "/srv/data", .Target = "/data", .ReadOnly = true },
        .{ .Type = "volume", .Source = "myvol", .Target = "/vol", .ReadOnly = false },
    };
    const req = ContainerCreateRequest{ .Image = "alpine:3.20", .Mounts = &mounts };
    const json = try std.json.stringifyAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"Mounts\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Type\":\"bind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Source\":\"/srv/data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Target\":\"/data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Type\":\"volume\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadOnly\":false") != null);
}

test "validatePortMapping and makePortMapping reject invalid ports" {
    try validatePortMapping(.{ .container_port = 80 });
    try validatePortMapping(.{ .host_ip = "127.0.0.1", .host_port = 8080, .container_port = 80, .proto = "udp" });

    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 0 }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .host_port = 0 }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .proto = "icmp" }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .host_ip = "not-an-ip" }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .host_ip = "1.2.3.4.5" }));

    const m = try makePortMapping("10.0.0.1", 9000, 9000, "sctp");
    try std.testing.expectEqualStrings("10.0.0.1", m.host_ip.?);
    try std.testing.expectEqual(@as(?u16, 9000), m.host_port);
    try std.testing.expectError(ApiError.InvalidPort, makePortMapping(null, null, 0, "tcp"));
}

test "ExposedPorts and PortBindings serialize to Docker JSON" {
    const alloc = std.testing.allocator;
    const ports = [_]PortMapping{
        .{ .host_port = 8080, .container_port = 80 },
        .{ .host_port = 53, .container_port = 53, .proto = "udp" },
        .{ .host_ip = "127.0.0.1", .host_port = 9000, .container_port = 9000 },
        .{ .container_port = 3000 },
    };
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .ExposedPorts = .{ .ports = &ports },
        .HostConfig = .{ .PortBindings = .{ .ports = &ports } },
    };
    const json = try std.json.stringifyAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"ExposedPorts\":{\"80/tcp\":{},\"53/udp\":{},\"9000/tcp\":{},\"3000/tcp\":{}}") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"PortBindings\":{\"80/tcp\":[{\"HostPort\":\"8080\"}],\"53/udp\":[{\"HostPort\":\"53\"}],\"9000/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"9000\"}]}",
    ) != null);
}

test "validate network, workdir, user, and capability fields" {
    for (allowed_network_modes) |m| try validateNetworkMode(m);
    try std.testing.expectError(ApiError.InvalidNetwork, validateNetworkMode("bogus"));
    try std.testing.expectError(ApiError.InvalidNetwork, validateNetworkMode(""));
    try std.testing.expectError(ApiError.InvalidNetwork, validateNetworkMode("host;rm -rf /"));

    try validateWorkdir("/work");
    try validateWorkdir("/var/lib/data");
    try std.testing.expectError(ApiError.InvalidWorkdir, validateWorkdir("relative"));
    try std.testing.expectError(ApiError.InvalidWorkdir, validateWorkdir("/work/../etc"));
    try std.testing.expectError(ApiError.InvalidWorkdir, validateWorkdir("/work/"));

    try validateUser("1000");
    try validateUser("1000:1000");
    try validateUser("nobody:nogroup");
    try std.testing.expectError(ApiError.InvalidUser, validateUser(""));
    try std.testing.expectError(ApiError.InvalidUser, validateUser(":"));
    try std.testing.expectError(ApiError.InvalidUser, validateUser("a:b:c"));
    try std.testing.expectError(ApiError.InvalidUser, validateUser("bad user"));
    try std.testing.expectError(ApiError.InvalidUser, validateUser("-root"));

    try validateCapability("ALL");
    try validateCapability("NET_ADMIN");
    try validateCapability("CHOWN");
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability(""));
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability("net_admin"));
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability("1BAD"));
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability("NET ADMIN"));
}

test "ContainerCreateRequest serializes network, workdir, user, and capabilities" {
    const alloc = std.testing.allocator;
    const cap_drop = [_][]const u8{"ALL"};
    const cap_add = [_][]const u8{"NET_BIND_SERVICE"};
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .WorkingDir = "/work",
        .User = "1000:1000",
        .HostConfig = .{
            .NetworkMode = "none",
            .CapDrop = &cap_drop,
            .CapAdd = &cap_add,
        },
    };
    const json = try std.json.stringifyAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"WorkingDir\":\"/work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"User\":\"1000:1000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NetworkMode\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"CapDrop\":[\"ALL\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"CapAdd\":[\"NET_BIND_SERVICE\"]") != null);
}


test "validateResourceRef accepts image refs and rejects injection" {
    try validateResourceRef("alpine:3.20");
    try validateResourceRef("docker.io/library/alpine:3.20");
    try validateResourceRef("sha256:abc123");
    try validateResourceRef("web");
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef(""));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef(".."));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a b"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a?b"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a\nb"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("alpine;rm-rf /"));
}


test "validateResourceRef rejects traversal path segments (BUG-021)" {
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a/../b"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("web/../../etc/shadow"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("..hidden/../etc"));
    try validateResourceRef("a/./b");
    try validateResourceRef("docker.io/library/alpine:3.20");
    try validateResourceRef("reg.mirror/team/name:1.2.3");
}


test "validateResourceRef accepts image refs at the 256-byte boundary and rejects longer" {
    const ref_256 = "docker.io/library/" ++ ("a" ** 233) ++ ":3.20";
    try std.testing.expectEqual(@as(usize, 256), ref_256.len);
    try validateResourceRef(ref_256);

    const ref_257 = "docker.io/library/" ++ ("a" ** 234) ++ ":3.20";
    try std.testing.expectEqual(@as(usize, 257), ref_257.len);
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef(ref_257));

    const digest_ref = "docker.io/library/alpine@sha256:" ++ ("0123456789abcdef" ** 4);
    try std.testing.expectEqual(@as(usize, 96), digest_ref.len);
    try validateResourceRef(digest_ref);
}


test "validateIdentifier enforces the 128-byte length boundary" {
    try validateIdentifier("x" ** 128);
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("x" ** 129));
}


test "ContainerCreateRequest serializes hardening HostConfig fields" {
    const alloc = std.testing.allocator;
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .HostConfig = HostConfig{
            .AutoRemove = true,
            .ReadonlyRootfs = true,
            .Memory = 67_108_864,
            .PidsLimit = 32,
            .SecurityOpt = &.{"no-new-privileges"},
        },
    };
    const json = try std.json.stringifyAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadonlyRootfs\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Memory\":67108864") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"PidsLimit\":32") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SecurityOpt\":[\"no-new-privileges\"]") != null);
}

