//! Podman / Docker-compatible REST API (v1.40) client functions.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");

pub const api_prefix = "/v1.40";

pub const ApiError = error{
    PodmanApiError,
    InvalidIdentifier,
    InvalidHostPath,
    InvalidMountTarget,
    InvalidPort,
};

pub const HostConfig = struct {
    AutoRemove: bool = false,
    ReadonlyRootfs: bool = false,
    Memory: ?i64 = null,
    PidsLimit: ?i64 = null,
    SecurityOpt: ?[]const []const u8 = null,
    PortBindings: ?PortBindings = null,
};

/// A bind mount or named-volume mount, serialized into the container-create
/// request. `Type` is `"bind"` or `"volume"`; `Target` is the in-container path.
pub const Mount = struct {
    Type: []const u8,
    Source: []const u8,
    Target: []const u8,
    ReadOnly: bool = true,
};

/// A validated port mapping. `host_ip`/`host_port` are null when only a
/// container port is exposed.
pub const PortMapping = struct {
    host_ip: ?[]const u8 = null,
    host_port: ?u16 = null,
    container_port: u16,
    proto: []const u8 = "tcp",
};

/// Serializes the Docker `ExposedPorts` object: `{"80/tcp":{},...}`.
pub const ExposedPorts = struct {
    ports: []const PortMapping,

    pub fn jsonStringify(self: ExposedPorts, jw: anytype) !void {
        try jw.beginObject();
        for (self.ports) |p| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}/{s}", .{ p.container_port, p.proto }) catch unreachable;
            try jw.objectField(key);
            try jw.beginObject();
            try jw.endObject();
        }
        try jw.endObject();
    }
};

/// Serializes the Docker `HostConfig.PortBindings` object, skipping entries
/// without an explicit host port: `{"80/tcp":[{"HostPort":"8080"}],...}`.
pub const PortBindings = struct {
    ports: []const PortMapping,

    pub fn jsonStringify(self: PortBindings, jw: anytype) !void {
        try jw.beginObject();
        for (self.ports) |p| {
            const host_port = p.host_port orelse continue;
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}/{s}", .{ p.container_port, p.proto }) catch unreachable;
            try jw.objectField(key);
            try jw.beginArray();
            try jw.beginObject();
            if (p.host_ip) |ip| {
                try jw.objectField("HostIp");
                try jw.write(ip);
            }
            try jw.objectField("HostPort");
            var port_buf: [8]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&port_buf, "{d}", .{host_port}) catch unreachable);
            try jw.endObject();
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const ContainerCreateRequest = struct {
    Image: []const u8,
    Cmd: ?[]const []const u8 = null,
    Env: ?[]const []const u8 = null,
    ExposedPorts: ?ExposedPorts = null,
    Mounts: ?[]const Mount = null,
    HostConfig: ?HostConfig = null,
};

pub const CreateResponse = struct {
    Id: []const u8,
    Warnings: ?[]const []const u8 = null,
};

pub const ContainerSummary = struct {
    Id: []const u8,
    Image: []const u8 = "",
    Command: []const u8 = "",
    Status: []const u8 = "",
    State: []const u8 = "",
    Names: ?[]const []const u8 = null,
};

pub const ImageSummary = struct {
    Id: []const u8,
    RepoTags: ?[]const []const u8 = null,
    Size: i64 = 0,
    Created: i64 = 0,
};

pub const WaitResponse = struct {
    StatusCode: i64 = 0,
};

pub const VersionInfo = struct {
    Version: []const u8 = "unknown",
    ApiVersion: []const u8 = "unknown",
    Os: []const u8 = "unknown",
    Arch: []const u8 = "unknown",
};

const PullStatusLine = struct {
    status: ?[]const u8 = null,
    id: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

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

fn validateMount(m: Mount) ApiError!void {
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

fn appendQueryEncoded(out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(c);
        } else {
            try out.writer().print("%{X:0>2}", .{c});
        }
    }
}

fn logApiFailure(logger: *log.Logger, method: []const u8, path: []const u8, resp: http.Response) ApiError {
    const trimmed = std.mem.trim(u8, resp.body, " \r\n\t");
    if (trimmed.len > 0) {
        logger.err("API {s} {s} failed (HTTP {d}): {s}", .{ method, path, resp.status, trimmed });
    } else {
        logger.err("API {s} {s} failed (HTTP {d})", .{ method, path, resp.status });
    }
    return ApiError.PodmanApiError;
}

/// Creates a container and returns its allocated container ID.
pub fn createContainer(
    client: *const http.Client,
    logger: *log.Logger,
    cfg: ContainerCreateRequest,
    name: ?[]const u8,
) ![]u8 {
    if (name) |n| try validateIdentifier(n);
    // Defense in depth: never serialize an unsafe mount even if a caller
    // constructed `Mount` values by hand (BUG-014).
    if (cfg.Mounts) |mounts| {
        for (mounts) |m| try validateMount(m);
    }
    if (cfg.ExposedPorts) |exposed| {
        for (exposed.ports) |p| try validatePortMapping(p);
    }

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/containers/create");
    if (name) |n| {
        try path_buf.appendSlice("?name=");
        try appendQueryEncoded(&path_buf, n);
    }

    const req_body = try std.json.stringifyAlloc(client.allocator, cfg, .{
        .emit_null_optional_fields = false,
    });
    defer client.allocator.free(req_body);

    logger.debug("POST {s} body={s}", .{ path_buf.items, req_body });
    const resp = try client.request("POST", path_buf.items, req_body);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path_buf.items, resp);

    const parsed = try std.json.parseFromSlice(CreateResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.Warnings) |warnings| {
        for (warnings) |w| {
            logger.warn("container create warning: {s}", .{w});
        }
    }

    logger.info("created container {s} (image={s})", .{ utils.shortId(parsed.value.Id), cfg.Image });
    return client.allocator.dupe(u8, parsed.value.Id);
}

pub fn startContainer(client: *const http.Client, logger: *log.Logger, id: []const u8) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/start", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and resp.status != 304) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("started container {s}", .{utils.shortId(id)});
}

pub fn stopContainer(client: *const http.Client, logger: *log.Logger, id: []const u8) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/stop", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and resp.status != 304) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("stopped container {s}", .{utils.shortId(id)});
}

pub fn removeContainer(client: *const http.Client, logger: *log.Logger, id: []const u8, force: bool) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/{s}?force={s}",
        .{ api_prefix, id, if (force) "true" else "false" },
    );
    defer client.allocator.free(path);

    logger.debug("DELETE {s}", .{path});
    const resp = try client.request("DELETE", path, null);
    defer resp.deinit();

    if (resp.status != 204) {
        return logApiFailure(logger, "DELETE", path, resp);
    }
    logger.info("removed container {s}", .{utils.shortId(id)});
}

pub fn waitContainer(client: *const http.Client, logger: *log.Logger, id: []const u8) !i64 {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/wait", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    // The daemon holds this response until the container exits, which can
    // legitimately take hours — use the blocking timeout, not the default (BUG-007).
    const resp = try client.requestWithTimeout("POST", path, null, http.blocking_timeout_ms);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    const parsed = try std.json.parseFromSlice(WaitResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    logger.debug("container {s} exited with status {d}", .{ utils.shortId(id), parsed.value.StatusCode });
    return parsed.value.StatusCode;
}

pub fn fetchLogs(client: *const http.Client, logger: *log.Logger, id: []const u8, writer: anytype) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/logs?stdout=1&stderr=1", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);
    try demuxLogs(resp.body, writer);
}

pub fn listContainers(client: *const http.Client, logger: *log.Logger, all: bool, writer: anytype) !void {
    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/json?all={s}",
        .{ api_prefix, if (all) "true" else "false" },
    );
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice([]ContainerSummary, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try writer.print("{s:<14} {s:<28} {s:<22} {s}\n", .{ "CONTAINER ID", "IMAGE", "STATUS", "NAME" });
    for (parsed.value) |c| {
        const name = if (c.Names) |names|
            if (names.len > 0) std.mem.trimLeft(u8, names[0], "/") else ""
        else
            "";
        const status = if (c.Status.len > 0) c.Status else c.State;
        try writer.print("{s:<14} {s:<28} {s:<22} {s}\n", .{
            utils.shortId(c.Id),
            c.Image,
            status,
            name,
        });
    }
    logger.info("listed {d} container(s) (all={})", .{ parsed.value.len, all });
}

pub fn listImages(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const path = api_prefix ++ "/images/json";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice([]ImageSummary, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try writer.print("{s:<14} {s:<38} {s}\n", .{ "IMAGE ID", "REPOSITORY:TAG", "SIZE" });
    var size_buf: [32]u8 = undefined;
    for (parsed.value) |img| {
        const tag = if (img.RepoTags) |tags|
            if (tags.len > 0) tags[0] else "<none>:<none>"
        else
            "<none>:<none>";
        try writer.print("{s:<14} {s:<38} {s}\n", .{
            utils.shortId(img.Id),
            tag,
            utils.formatSize(&size_buf, img.Size),
        });
    }
    logger.info("listed {d} image(s)", .{parsed.value.len});
}

pub fn pullImage(client: *const http.Client, logger: *log.Logger, image: []const u8, writer: anytype) !void {
    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/images/create?fromImage=");
    try appendQueryEncoded(&path_buf, image);

    logger.info("pulling image {s}", .{image});
    // Pulls stream progress for minutes on large layers and may pause while
    // extracting — use the blocking timeout, not the default (BUG-007).
    const resp = try client.requestWithTimeout("POST", path_buf.items, null, http.blocking_timeout_ms);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path_buf.items, resp);

    var lines = std.mem.tokenizeAny(u8, resp.body, "\r\n");
    while (lines.next()) |line| {
        const parsed = std.json.parseFromSlice(PullStatusLine, client.allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch {
            try writer.print("{s}\n", .{line});
            continue;
        };
        defer parsed.deinit();

        if (parsed.value.@"error") |err_msg| {
            logger.err("pull {s} failed: {s}", .{ image, err_msg });
            return ApiError.PodmanApiError;
        }
        if (parsed.value.status) |st| {
            if (parsed.value.id) |id| {
                try writer.print("{s}: {s}\n", .{ id, st });
            } else {
                try writer.print("{s}\n", .{st});
            }
        }
    }
    try writer.print("Pulled {s}\n", .{image});
    logger.info("pulled image {s}", .{image});
}

pub fn showVersion(client: *const http.Client, logger: *log.Logger, client_version: []const u8, writer: anytype) !void {
    const path = api_prefix ++ "/version";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(VersionInfo, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const v = parsed.value;
    try writer.print("Client: zigpod {s}\n", .{client_version});
    try writer.print("Server: {s} (API {s}, {s}/{s})\n", .{ v.Version, v.ApiVersion, v.Os, v.Arch });
    logger.info("fetched server version {s} (API {s})", .{ v.Version, v.ApiVersion });
}

/// Demultiplexes Docker/Podman attached log frames ([stream_type, 0, 0, 0, size_be32][payload...]).
/// Falls back to writing `raw` verbatim when the payload is plain text (e.g., TTY containers).
pub fn demuxLogs(raw: []const u8, writer: anytype) !void {
    if (raw.len == 0) return;

    var pos: usize = 0;
    var valid_frames = false;
    while (raw.len - pos >= 8) {
        const stream_type = raw[pos];
        if (stream_type > 2 or raw[pos + 1] != 0 or raw[pos + 2] != 0 or raw[pos + 3] != 0) {
            valid_frames = false;
            break;
        }
        const size = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big);
        const next_pos = std.math.add(usize, pos + 8, @as(usize, size)) catch {
            valid_frames = false;
            break;
        };
        if (next_pos > raw.len) {
            valid_frames = false;
            break;
        }
        valid_frames = true;
        pos = next_pos;
        if (pos == raw.len) break;
    } else {
        valid_frames = false;
    }

    if (!valid_frames or pos != raw.len) {
        try writer.writeAll(raw);
        return;
    }

    pos = 0;
    while (raw.len - pos >= 8) {
        const size = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big);
        const start = pos + 8;
        const end = start + @as(usize, size);
        try writer.writeAll(raw[start..end]);
        pos = end;
    }
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

test "demuxLogs handles multiplexed docker stream frames and zero-length frame" {    const frame = [_]u8{
        1, 0, 0, 0, 0, 0, 0, 6, 'h', 'e', 'l', 'l', 'o', '\n',
        1, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 4, 'e', 'r', 'r', '\n',
    };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs(&frame, out.writer());
    try std.testing.expectEqualStrings("hello\nerr\n", out.items);
}

test "demuxLogs falls back to plain text on malformed frames" {
    const plain = "plain log output\nline 2\n";
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs(plain, out.writer());
    try std.testing.expectEqualStrings(plain, out.items);

    // Invalid stream type 3
    out.clearRetainingCapacity();
    const bad_stream = [_]u8{ 3, 0, 0, 0, 0, 0, 0, 2, 'h', 'i' };
    try demuxLogs(&bad_stream, out.writer());
    try std.testing.expectEqualSlices(u8, &bad_stream, out.items);

    // Non-zero reserved byte
    out.clearRetainingCapacity();
    const bad_reserved = [_]u8{ 1, 0, 1, 0, 0, 0, 0, 2, 'h', 'i' };
    try demuxLogs(&bad_reserved, out.writer());
    try std.testing.expectEqualSlices(u8, &bad_reserved, out.items);

    // Frame size exceeds buffer length
    out.clearRetainingCapacity();
    const truncated_payload = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 99, 'h', 'i' };
    try demuxLogs(&truncated_payload, out.writer());
    try std.testing.expectEqualSlices(u8, &truncated_payload, out.items);

    // Truncated header (< 8 bytes)
    out.clearRetainingCapacity();
    const short_hdr = [_]u8{ 1, 0, 0, 0, 0 };
    try demuxLogs(&short_hdr, out.writer());
    try std.testing.expectEqualSlices(u8, &short_hdr, out.items);
}

test "demuxLogs handles empty slice" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs("", out.writer());
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "JSON deserialize CreateResponse" {
    const json = "{\"Id\":\"1234567890abcdef\",\"Warnings\":[\"warn1\"]}";
    const parsed = try std.json.parseFromSlice(CreateResponse, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("1234567890abcdef", parsed.value.Id);
    try std.testing.expectEqualStrings("warn1", parsed.value.Warnings.?[0]);
}

test "JSON deserialize ContainerSummary list" {
    const json =
        \\[{"Id":"abcdef1234567890","Image":"alpine:3.20","Command":"sh","Status":"Up 5s","State":"running","Names":["/web"],"ExtraField":123}]
    ;
    const parsed = try std.json.parseFromSlice([]ContainerSummary, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("alpine:3.20", parsed.value[0].Image);
    try std.testing.expectEqualStrings("/web", parsed.value[0].Names.?[0]);
}

test "JSON deserialize ImageSummary list" {
    const json =
        \\[{"Id":"sha256:9988776655443322","RepoTags":["docker.io/library/alpine:3.20"],"Size":7340032,"Created":1700000000,"Containers":1}]
    ;
    const parsed = try std.json.parseFromSlice([]ImageSummary, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqual(@as(i64, 7340032), parsed.value[0].Size);
    try std.testing.expectEqualStrings("docker.io/library/alpine:3.20", parsed.value[0].RepoTags.?[0]);
}

fn runDelayedWaitServer(server: *std.net.Server) void {
    const conn = server.accept() catch return;
    defer conn.stream.close();
    var buf: [4096]u8 = undefined;
    _ = readHttpRequest(conn.stream, &buf) catch return;
    // BUG-007 regression: the daemon holds /wait until the container exits.
    // The reply arrives well after the client's short default timeout.
    std.time.sleep(150 * std.time.ns_per_ms);
    conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\n{\"StatusCode\":0}") catch return;
}

test "waitContainer uses the blocking timeout when daemon delays response" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-delayed-wait-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, runDelayedWaitServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .timeout_ms = 30,
    };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    const status = try waitContainer(&client, &logger, "abcdef123456");
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(i64, 0), status);
}

fn readHttpRequest(stream: std.net.Stream, buf: []u8) ![]const u8 {    var total: usize = 0;
    var header_end: ?usize = null;
    var expected_total: ?usize = null;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) break;
        total += n;
        if (header_end == null) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                header_end = idx;
                var cl: usize = 0;
                if (std.ascii.indexOfIgnoreCase(buf[0..idx], "content-length:")) |cl_pos| {
                    const after = buf[cl_pos + "content-length:".len .. idx];
                    const eol = std.mem.indexOfScalar(u8, after, '\r') orelse after.len;
                    cl = std.fmt.parseInt(usize, std.mem.trim(u8, after[0..eol], " \t"), 10) catch 0;
                }
                expected_total = idx + 4 + cl;
            }
        }
        if (expected_total) |exp| {
            if (total >= exp) break;
        }
    }
    return buf[0..total];
}

const ScriptedReply = struct {
    expected_prefix: []const u8,
    raw_response: []const u8,
};

const MockApiCtx = struct {
    server: *std.net.Server,
    replies: []const ScriptedReply,
    matched: usize = 0,
};

fn runMockPodmanServer(ctx: *MockApiCtx) void {
    var buf: [4096]u8 = undefined;
    for (ctx.replies) |reply| {
        const conn = ctx.server.accept() catch return;
        defer conn.stream.close();
        const req = readHttpRequest(conn.stream, &buf) catch return;
        if (std.mem.startsWith(u8, req, reply.expected_prefix)) {
            ctx.matched += 1;
        }
        conn.stream.writeAll(reply.raw_response) catch return;
    }
}

test "end-to-end container lifecycle over mock Unix socket has zero memory leaks" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-lifecycle-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const log_raw = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n\x01\x00\x00\x00\x00\x00\x00\x03hi\n";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=test-box HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 201 Created\r\nContent-Length: 27\r\n\r\n{\"Id\":\"abcdef1234567890ff\"}",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/abcdef1234567890ff/start HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/abcdef1234567890ff/wait HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\n{\"StatusCode\":0}",
        },
        .{
            .expected_prefix = "GET /v1.40/containers/abcdef1234567890ff/logs?stdout=1&stderr=1 HTTP/1.1\r\n",
            .raw_response = log_raw,
        },
        .{
            .expected_prefix = "DELETE /v1.40/containers/abcdef1234567890ff?force=false HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "DELETE /v1.40/containers/missing?force=false HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 21\r\n\r\n{\"message\":\"no such\"}",
        },
    };

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
    };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    // Validation errors fail before hitting the socket.
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        createContainer(&client, &logger, .{ .Image = "alpine:3.20" }, "../bad"),
    );
    try std.testing.expectError(ApiError.InvalidIdentifier, removeContainer(&client, &logger, "../bad", true));

    // Unsafe bind mounts fail closed before any socket traffic.
    const bad_mounts = [_]Mount{.{ .Type = "bind", .Source = "/etc", .Target = "/data", .ReadOnly = true }};
    try std.testing.expectError(
        ApiError.InvalidHostPath,
        createContainer(&client, &logger, .{ .Image = "alpine:3.20", .Mounts = &bad_mounts }, null),
    );

    // Invalid published ports also fail closed before any socket traffic.
    const bad_ports = [_]PortMapping{.{ .container_port = 0 }};
    try std.testing.expectError(
        ApiError.InvalidPort,
        createContainer(&client, &logger, .{ .Image = "alpine:3.20", .ExposedPorts = .{ .ports = &bad_ports } }, null),
    );

    const id = try createContainer(&client, &logger, .{
        .Image = "alpine:3.20",
        .Cmd = &.{ "echo", "hi" },
    }, "test-box");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("abcdef1234567890ff", id);

    try startContainer(&client, &logger, id);
    const exit_code = try waitContainer(&client, &logger, id);
    try std.testing.expectEqual(@as(i64, 0), exit_code);

    var logs_out = std.ArrayList(u8).init(std.testing.allocator);
    defer logs_out.deinit();
    try fetchLogs(&client, &logger, id, logs_out.writer());
    try std.testing.expectEqualStrings("hi\n", logs_out.items);

    try removeContainer(&client, &logger, id, false);
    try std.testing.expectError(ApiError.PodmanApiError, removeContainer(&client, &logger, "missing", false));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "listContainers over mock Unix socket" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-ps-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const json_body =
        \\[{"Id":"abcdef1234567890","Image":"alpine:3.20","Status":"Up 5s","Names":["/web"]}]
    ;
    const raw_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ json_body.len, json_body },
    );

    const replies = [_]ScriptedReply{.{
        .expected_prefix = "GET /v1.40/containers/json?all=true HTTP/1.1\r\n",
        .raw_response = raw_resp,
    }};

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
    };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try listContainers(&client, &logger, true, out.writer());

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 1), ctx.matched);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "abcdef123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "alpine:3.20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "web") != null);
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
