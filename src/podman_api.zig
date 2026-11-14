//! Podman / Docker-compatible REST API (v1.40) client functions.
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
pub const CreateResponse = types.CreateResponse;
pub const ContainerSummary = types.ContainerSummary;
pub const ImageSummary = types.ImageSummary;
pub const WaitResponse = types.WaitResponse;
pub const VersionInfo = types.VersionInfo;
pub const ContainerInspect = types.ContainerInspect;
pub const ImageInspect = types.ImageInspect;
pub const ExecCreateRequest = types.ExecCreateRequest;
pub const ExecCreateResponse = types.ExecCreateResponse;
pub const ExecStartRequest = types.ExecStartRequest;
pub const ExecInspect = types.ExecInspect;
pub const ContainerStats = types.ContainerStats;
const PullStatusLine = types.PullStatusLine;

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
/// control chars and URL delimiters that could alter the request line.
pub fn validateResourceRef(ref: []const u8) ApiError!void {
    if (ref.len == 0 or ref.len > 256) return ApiError.InvalidIdentifier;
    if (std.mem.eql(u8, ref, ".") or std.mem.eql(u8, ref, "..")) return ApiError.InvalidIdentifier;
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
    // Defense in depth: validate identity/network/capability fields too (BUG-016).
    if (cfg.WorkingDir) |w| try validateWorkdir(w);
    if (cfg.User) |u| try validateUser(u);
    if (cfg.HostConfig) |hc| {
        if (hc.NetworkMode) |m| try validateNetworkMode(m);
        if (hc.CapDrop) |caps| for (caps) |c| try validateCapability(c);
        if (hc.CapAdd) |caps| for (caps) |c| try validateCapability(c);
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

pub fn fetchLogs(client: *const http.Client, logger: *log.Logger, id: []const u8, follow: bool, writer: anytype) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/{s}/logs?stdout=1&stderr=1{s}",
        .{ api_prefix, id, if (follow) "&follow=1" else "" },
    );
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const timeout = if (follow) http.blocking_timeout_ms else client.timeout_ms;
    const WriterType = @TypeOf(writer);
    var demuxer = LogDemuxer(WriterType){
        .allocator = client.allocator,
        .writer = writer,
    };
    defer demuxer.deinit();

    const resp = try client.streamRequest("GET", path, null, timeout, &demuxer, LogDemuxer(WriterType).push);
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "GET", path, err_resp);
    }
    try demuxer.flush();
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
    const WriterType = @TypeOf(writer);
    var pull_ctx = PullStreamCtx(WriterType){
        .allocator = client.allocator,
        .logger = logger,
        .image = image,
        .writer = writer,
    };
    defer pull_ctx.deinit();

    // Pulls stream progress for minutes on large layers and may pause while
    // extracting — use the blocking timeout, not the default (BUG-007).
    const resp = try client.streamRequest(
        "POST",
        path_buf.items,
        null,
        http.blocking_timeout_ms,
        &pull_ctx,
        PullStreamCtx(WriterType).onChunk,
    );
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "POST", path_buf.items, err_resp);
    }
    try pull_ctx.flush();
    if (pull_ctx.had_error) return ApiError.PodmanApiError;
    try writer.print("Pulled {s}\n", .{image});
    logger.info("pulled image {s}", .{image});
}

fn PullStreamCtx(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        logger: *log.Logger,
        image: []const u8,
        writer: WriterType,
        line_buf: std.ArrayListUnmanaged(u8) = .{},
        had_error: bool = false,

        fn deinit(self: *@This()) void {
            self.line_buf.deinit(self.allocator);
        }

        fn onChunk(self: *@This(), chunk: []const u8) !void {
            const projected = std.math.add(usize, self.line_buf.items.len, chunk.len) catch return http.Error.InvalidResponse;
            if (projected > 1024 * 1024) return http.Error.InvalidResponse;
            try self.line_buf.appendSlice(self.allocator, chunk);

            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, self.line_buf.items, start, '\n')) |nl| {
                const line = std.mem.trim(u8, self.line_buf.items[start..nl], " \r\t");
                if (line.len > 0) try self.handleLine(line);
                start = nl + 1;
            }
            if (start > 0) {
                const rem = self.line_buf.items.len - start;
                if (rem > 0) std.mem.copyForwards(u8, self.line_buf.items[0..rem], self.line_buf.items[start..]);
                self.line_buf.items.len = rem;
            }
        }

        fn flush(self: *@This()) !void {
            const line = std.mem.trim(u8, self.line_buf.items, " \r\t");
            if (line.len > 0) try self.handleLine(line);
            self.line_buf.items.len = 0;
        }

        fn handleLine(self: *@This(), line: []const u8) !void {
            const parsed = std.json.parseFromSlice(PullStatusLine, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch {
                try self.writer.print("{s}\n", .{line});
                return;
            };
            defer parsed.deinit();

            if (parsed.value.@"error") |err_msg| {
                self.logger.err("pull {s} failed: {s}", .{ self.image, err_msg });
                self.had_error = true;
                return;
            }
            if (parsed.value.status) |st| {
                if (parsed.value.id) |id| {
                    try self.writer.print("{s}: {s}\n", .{ id, st });
                } else {
                    try self.writer.print("{s}\n", .{st});
                }
            }
        }
    };
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

/// Inspects a container first, falling back to an image when the container
/// lookup returns 404. Prints state, IP, mounts, exit code, and hardening.
pub fn inspect(client: *const http.Client, logger: *log.Logger, target: []const u8, writer: anytype) !void {
    try validateResourceRef(target);

    const cpath = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/json", .{ api_prefix, target });
    defer client.allocator.free(cpath);

    logger.debug("GET {s}", .{cpath});
    const cresp = try client.request("GET", cpath, null);
    defer cresp.deinit();
    if (cresp.ok()) {
        const parsed = try std.json.parseFromSlice(ContainerInspect, client.allocator, cresp.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        try printContainerInspect(writer, parsed.value);
        logger.info("inspected container {s}", .{target});
        return;
    }
    if (cresp.status != 404) return logApiFailure(logger, "GET", cpath, cresp);

    const ipath = try std.fmt.allocPrint(client.allocator, "{s}/images/{s}/json", .{ api_prefix, target });
    defer client.allocator.free(ipath);

    logger.debug("GET {s}", .{ipath});
    const iresp = try client.request("GET", ipath, null);
    defer iresp.deinit();
    if (!iresp.ok()) {
        logger.err("no such container or image: {s}", .{target});
        return ApiError.NotFound;
    }

    const parsed = try std.json.parseFromSlice(ImageInspect, client.allocator, iresp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try printImageInspect(writer, parsed.value);
    logger.info("inspected image {s}", .{target});
}

fn printJoined(writer: anytype, label: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    try writer.print("{s:<15}", .{label});
    for (items, 0..) |item, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.writeAll(item);
    }
    try writer.writeByte('\n');
}

fn resolveInspectIp(ns: ?ContainerInspect.NetworkSettings) []const u8 {
    const settings = ns orelse return "";
    if (settings.IPAddress.len > 0) return settings.IPAddress;
    const networks = settings.Networks orelse return "";
    switch (networks) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const value = entry.value_ptr.*;
                if (value != .object) continue;
                const ip = value.object.get("IPAddress") orelse continue;
                if (ip == .string and ip.string.len > 0) return ip.string;
            }
        },
        else => {},
    }
    return "";
}

fn printContainerInspect(writer: anytype, c: ContainerInspect) !void {
    try writer.print("{s:<15}{s}\n", .{ "Id:", c.Id });
    if (c.Name.len > 0) try writer.print("{s:<15}{s}\n", .{ "Name:", std.mem.trimLeft(u8, c.Name, "/") });
    if (c.Image.len > 0) try writer.print("{s:<15}{s}\n", .{ "Image:", c.Image });
    if (c.Created.len > 0) try writer.print("{s:<15}{s}\n", .{ "Created:", c.Created });

    if (c.State) |state| {
        try writer.print("{s:<15}{s} (running={}, exit={d})\n", .{ "State:", state.Status, state.Running, state.ExitCode });
        if (state.StartedAt.len > 0) try writer.print("{s:<15}{s}\n", .{ "StartedAt:", state.StartedAt });
        if (state.FinishedAt.len > 0) try writer.print("{s:<15}{s}\n", .{ "FinishedAt:", state.FinishedAt });
    }

    const ip = resolveInspectIp(c.NetworkSettings);
    if (ip.len > 0) try writer.print("{s:<15}{s}\n", .{ "IPAddress:", ip });

    if (c.Config) |cfg| {
        if (cfg.WorkingDir.len > 0) try writer.print("{s:<15}{s}\n", .{ "WorkingDir:", cfg.WorkingDir });
        if (cfg.User.len > 0) try writer.print("{s:<15}{s}\n", .{ "User:", cfg.User });
    }

    if (c.HostConfig) |hc| {
        if (hc.NetworkMode.len > 0) try writer.print("{s:<15}{s}\n", .{ "NetworkMode:", hc.NetworkMode });
        try writer.print("{s:<15}{}\n", .{ "ReadonlyRootfs:", hc.ReadonlyRootfs });
        if (hc.Memory != 0) try writer.print("{s:<15}{d}\n", .{ "Memory:", hc.Memory });
        if (hc.PidsLimit != 0) try writer.print("{s:<15}{d}\n", .{ "PidsLimit:", hc.PidsLimit });
        if (hc.AutoRemove) try writer.print("{s:<15}{}\n", .{ "AutoRemove:", hc.AutoRemove });
        if (hc.CapDrop) |caps| try printJoined(writer, "CapDrop:", caps);
        if (hc.CapAdd) |caps| try printJoined(writer, "CapAdd:", caps);
        if (hc.SecurityOpt) |opts| try printJoined(writer, "SecurityOpt:", opts);
    }

    if (c.Mounts) |mounts| {
        if (mounts.len > 0) {
            try writer.writeAll("Mounts:\n");
            for (mounts) |m| {
                try writer.print("  {s} -> {s} ({s}, {s})\n", .{
                    m.Source,
                    m.Destination,
                    m.Type,
                    if (m.RW) "rw" else "ro",
                });
            }
        }
    }
}

fn printImageInspect(writer: anytype, img: ImageInspect) !void {
    try writer.print("{s:<15}{s}\n", .{ "Id:", img.Id });
    if (img.RepoTags) |tags| try printJoined(writer, "RepoTags:", tags);
    if (img.Size > 0) {
        var size_buf: [32]u8 = undefined;
        try writer.print("{s:<15}{s}\n", .{ "Size:", utils.formatSize(&size_buf, img.Size) });
    }
    if (img.Created.len > 0) try writer.print("{s:<15}{s}\n", .{ "Created:", img.Created });
    if (img.Os.len > 0 or img.Architecture.len > 0) {
        try writer.print("{s:<15}{s}/{s}\n", .{ "Os/Arch:", img.Os, img.Architecture });
    }
}

/// `POST /containers/{id}/exec`: validates the container and identity fields,
/// then returns the daemon-allocated exec ID.
pub fn createExec(client: *const http.Client, logger: *log.Logger, container: []const u8, req: ExecCreateRequest) ![]u8 {
    try validateIdentifier(container);
    if (req.User) |u| try validateUser(u);
    if (req.WorkingDir) |w| try validateWorkdir(w);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/exec", .{ api_prefix, container });
    defer client.allocator.free(path);

    const body = try std.json.stringifyAlloc(client.allocator, req, .{ .emit_null_optional_fields = false });
    defer client.allocator.free(body);

    logger.debug("POST {s} body={s}", .{ path, body });
    const resp = try client.request("POST", path, body);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    const parsed = try std.json.parseFromSlice(ExecCreateResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.Warnings) |warnings| {
        for (warnings) |w| logger.warn("exec create warning: {s}", .{w});
    }
    if (parsed.value.Id.len == 0) {
        logger.err("exec create response missing Id for container {s}", .{container});
        return ApiError.PodmanApiError;
    }
    logger.info("created exec {s} on container {s}", .{ parsed.value.Id, container });
    return client.allocator.dupe(u8, parsed.value.Id);
}

/// `POST /exec/{id}/start`: streams the multiplexed stdout/stderr to `writer`.
pub fn startExec(client: *const http.Client, logger: *log.Logger, exec_id: []const u8, writer: anytype) !void {
    try validateIdentifier(exec_id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/exec/{s}/start", .{ api_prefix, exec_id });
    defer client.allocator.free(path);

    const body = try std.json.stringifyAlloc(client.allocator, ExecStartRequest{}, .{});
    defer client.allocator.free(body);

    logger.debug("POST {s} body={s}", .{ path, body });
    // A command may legitimately stay silent until it exits; use the blocking
    // timeout so long-running commands are not cut off (BUG-007).
    const resp = try client.requestWithTimeout("POST", path, body, http.blocking_timeout_ms);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    try demuxLogs(resp.body, writer);
}

/// `GET /exec/{id}/json`: returns the exit code of a finished exec instance.
pub fn inspectExec(client: *const http.Client, logger: *log.Logger, exec_id: []const u8) !ExecInspect {
    try validateIdentifier(exec_id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/exec/{s}/json", .{ api_prefix, exec_id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{ path });
    const resp = try client.request("GET", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(ExecInspect, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value;
}

/// Runs a command in a live container: create exec → start → inspect, returning
/// the command's exit code. Output is demultiplexed to `writer`.
pub fn execCommand(
    client: *const http.Client,
    logger: *log.Logger,
    container: []const u8,
    req: ExecCreateRequest,
    writer: anytype,
) !i64 {
    return execCommandWithIo(client, logger, container, req, null, writer);
}

/// Interactive/TTY-capable variant of `execCommand`. When `req.AttachStdin` or
/// `req.Tty` is set, upgrades `POST /exec/{id}/start` via HTTP `101 Switching
/// Protocols`, enters raw terminal mode when `stdin_fd` is a TTY, and pumps I/O.
pub fn execCommandWithIo(
    client: *const http.Client,
    logger: *log.Logger,
    container: []const u8,
    req: ExecCreateRequest,
    stdin_fd: ?std.posix.fd_t,
    writer: anytype,
) !i64 {
    const exec_id = try createExec(client, logger, container, req);
    defer client.allocator.free(exec_id);

    if (req.AttachStdin or req.Tty) {
        try startExecInteractive(client, logger, exec_id, req.Tty, stdin_fd, writer);
    } else {
        try startExec(client, logger, exec_id, writer);
    }
    const result = try inspectExec(client, logger, exec_id);
    logger.info("exec on container {s} finished (exit={d})", .{ container, result.ExitCode });
    return result.ExitCode;
}

/// Upgrades `POST /exec/{id}/start` (`101 Switching Protocols`) for interactive/TTY exec.
pub fn startExecInteractive(
    client: *const http.Client,
    logger: *log.Logger,
    exec_id: []const u8,
    tty: bool,
    stdin_fd: ?std.posix.fd_t,
    writer: anytype,
) !void {
    try validateIdentifier(exec_id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/exec/{s}/start", .{ api_prefix, exec_id });
    defer client.allocator.free(path);

    const body = try std.json.stringifyAlloc(client.allocator, ExecStartRequest{
        .Detach = false,
        .Tty = tty,
    }, .{});
    defer client.allocator.free(body);

    logger.debug("UPGRADE POST {s} body={s}", .{ path, body });
    const up = try client.upgrade("POST", path, body, http.blocking_timeout_ms);
    defer up.deinit();

    if (up.status != 101 and (up.status < 200 or up.status >= 300)) {
        const err_resp = http.Response{
            .status = up.status,
            .body = up.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "POST", path, err_resp);
    }

    var term_guard = if (tty and stdin_fd != null)
        http.RawTermGuard.enter(stdin_fd.?)
    else
        http.RawTermGuard{ .fd = -1, .orig = undefined, .active = false };
    defer term_guard.restore();

    try pumpBidirectional(client.allocator, up.stream, up.initial_data, stdin_fd, writer, tty);
}

/// Attaches to a running container via `POST /containers/{id}/attach` (`101 Switching Protocols`).
pub fn attachContainer(
    client: *const http.Client,
    logger: *log.Logger,
    id: []const u8,
    interactive: bool,
    tty: bool,
    stdin_fd: ?std.posix.fd_t,
    writer: anytype,
) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/{s}/attach?stream=1&stdin={s}&stdout=1&stderr=1",
        .{ api_prefix, id, if (interactive) "1" else "0" },
    );
    defer client.allocator.free(path);

    logger.debug("UPGRADE POST {s}", .{path});
    const up = try client.upgrade("POST", path, null, http.blocking_timeout_ms);
    defer up.deinit();

    if (up.status != 101 and (up.status < 200 or up.status >= 300)) {
        const err_resp = http.Response{
            .status = up.status,
            .body = up.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "POST", path, err_resp);
    }

    var term_guard = if (tty and stdin_fd != null)
        http.RawTermGuard.enter(stdin_fd.?)
    else
        http.RawTermGuard{ .fd = -1, .orig = undefined, .active = false };
    defer term_guard.restore();

    try pumpBidirectional(client.allocator, up.stream, up.initial_data, if (interactive) stdin_fd else null, writer, tty);
}

/// Pumps bytes between an upgraded Unix socket `stream` and `stdin_fd` / `writer`.
fn pumpBidirectional(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    initial_data: []const u8,
    stdin_fd: ?std.posix.fd_t,
    writer: anytype,
    tty: bool,
) !void {
    const WriterType = @TypeOf(writer);
    var demuxer = LogDemuxer(WriterType){
        .allocator = allocator,
        .writer = writer,
    };
    defer demuxer.deinit();

    if (initial_data.len > 0) {
        if (tty) try writer.writeAll(initial_data) else try demuxer.push(initial_data);
    }

    var active_stdin = stdin_fd;
    var buf: [4096]u8 = undefined;
    while (true) {
        var fds: [2]std.posix.pollfd = undefined;
        var nfds: usize = 1;
        fds[0] = .{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        if (active_stdin) |in_fd| {
            fds[1] = .{
                .fd = in_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };
            nfds = 2;
        }

        _ = try std.posix.poll(fds[0..nfds], http.blocking_timeout_ms);

        if (nfds == 2 and (fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            const n = std.posix.read(active_stdin.?, &buf) catch 0;
            if (n == 0) {
                active_stdin = null;
            } else {
                try stream.writeAll(buf[0..n]);
            }
        }

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            const n = try stream.read(&buf);
            if (n == 0) break;
            if (tty) try writer.writeAll(buf[0..n]) else try demuxer.push(buf[0..n]);
        } else if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            break;
        }
    }
    if (!tty) try demuxer.flush();
}

/// Incremental Docker multiplexed log frame demuxer ([type,0,0,0,len_be32][payload...]).
/// Falls back to raw passthrough when the stream does not begin with a valid header.
pub fn LogDemuxer(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: WriterType,
        buf: std.ArrayListUnmanaged(u8) = .{},
        raw_mode: bool = false,
        seen_valid_frame: bool = false,

        pub fn deinit(self: *@This()) void {
            self.buf.deinit(self.allocator);
        }

        pub fn push(self: *@This(), chunk: []const u8) !void {
            if (chunk.len == 0) return;
            if (self.raw_mode) {
                try self.writer.writeAll(chunk);
                return;
            }
            const projected = std.math.add(usize, self.buf.items.len, chunk.len) catch return http.Error.InvalidResponse;
            if (projected > http.max_response_bytes) return http.Error.InvalidResponse;
            try self.buf.appendSlice(self.allocator, chunk);

            var pos: usize = 0;
            while (self.buf.items.len - pos >= 8) {
                const hdr = self.buf.items[pos .. pos + 8];
                const stream_type = hdr[0];
                const zeros_ok = hdr[1] == 0 and hdr[2] == 0 and hdr[3] == 0;
                if (stream_type > 2 or !zeros_ok) {
                    if (!self.seen_valid_frame) {
                        self.raw_mode = true;
                        try self.writer.writeAll(self.buf.items[pos..]);
                        self.buf.items.len = 0;
                        return;
                    }
                    break;
                }
                const frame_len: usize = std.mem.readInt(u32, hdr[4..8], .big);
                const payload_start = std.math.add(usize, pos, 8) catch break;
                const payload_end = std.math.add(usize, payload_start, frame_len) catch break;
                if (payload_end > self.buf.items.len) break;
                self.seen_valid_frame = true;
                try self.writer.writeAll(self.buf.items[payload_start..payload_end]);
                pos = payload_end;
            }
            if (pos > 0) {
                const rem = self.buf.items.len - pos;
                if (rem > 0) std.mem.copyForwards(u8, self.buf.items[0..rem], self.buf.items[pos..]);
                self.buf.items.len = rem;
            }
        }

        pub fn flush(self: *@This()) !void {
            if (!self.seen_valid_frame and self.buf.items.len > 0) {
                try self.writer.writeAll(self.buf.items);
            }
            self.buf.items.len = 0;
        }
    };
}

/// Computes Docker-compatible CPU percentage from `cpu_stats` and `precpu_stats`.
pub fn computeCpuPercent(s: ContainerStats) f64 {
    const cpu = s.cpu_stats orelse return 0.0;
    const pre = s.precpu_stats orelse return 0.0;
    const cur_total = (cpu.cpu_usage orelse return 0.0).total_usage orelse return 0.0;
    const pre_total = (pre.cpu_usage orelse return 0.0).total_usage orelse 0;
    const cur_sys = cpu.system_cpu_usage orelse return 0.0;
    const pre_sys = pre.system_cpu_usage orelse 0;

    if (cur_total <= pre_total or cur_sys <= pre_sys) return 0.0;

    const cpu_delta = cur_total - pre_total;
    const sys_delta = cur_sys - pre_sys;

    const online_cpus: u32 = blk: {
        if (cpu.online_cpus) |n| {
            if (n > 0) break :blk n;
        }
        if (cpu.cpu_usage) |usage| {
            if (usage.percpu_usage) |percpu| {
                if (percpu.len > 0) break :blk @intCast(@min(percpu.len, std.math.maxInt(u32)));
            }
        }
        break :blk 1;
    };

    return (@as(f64, @floatFromInt(cpu_delta)) / @as(f64, @floatFromInt(sys_delta))) *
        @as(f64, @floatFromInt(online_cpus)) * 100.0;
}

/// Computes effective memory usage (subtracting page cache / inactive_file) and percentage of limit.
pub fn computeMemoryUsage(ms_opt: ?ContainerStats.MemoryStats) struct { used: u64, limit: u64, percent: f64 } {
    const ms = ms_opt orelse return .{ .used = 0, .limit = 0, .percent = 0.0 };
    const raw_usage = ms.usage orelse 0;
    const reclaimable: u64 = if (ms.stats) |st| (st.inactive_file orelse st.cache orelse 0) else 0;
    const used = if (raw_usage > reclaimable) raw_usage - reclaimable else 0;
    const limit = ms.limit orelse 0;
    const percent: f64 = if (limit > 0)
        (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(limit))) * 100.0
    else
        0.0;
    return .{ .used = used, .limit = limit, .percent = percent };
}

fn formatSizeU64(buf: []u8, bytes: u64) []const u8 {
    const clamped: i64 = if (bytes > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(bytes);
    return utils.formatSize(buf, clamped);
}

fn formatStatsRow(writer: anytype, fallback_id: []const u8, s: ContainerStats) !void {
    const id = if (s.id.len > 0) s.id else fallback_id;
    const name = std.mem.trimLeft(u8, s.name, "/");
    const cpu_pct = computeCpuPercent(s);
    const mem = computeMemoryUsage(s.memory_stats);
    const pids: u64 = if (s.pids_stats) |p| p.current orelse 0 else 0;

    var cpu_buf: [24]u8 = undefined;
    const cpu_str = std.fmt.bufPrint(&cpu_buf, "{d:.2}%", .{cpu_pct}) catch "0.00%";

    var used_buf: [32]u8 = undefined;
    var limit_buf: [32]u8 = undefined;
    const used_str = formatSizeU64(&used_buf, mem.used);
    const limit_str = if (mem.limit > 0) formatSizeU64(&limit_buf, mem.limit) else "--";
    var mem_col_buf: [68]u8 = undefined;
    const mem_col = std.fmt.bufPrint(&mem_col_buf, "{s} / {s}", .{ used_str, limit_str }) catch "?";

    var mem_pct_buf: [24]u8 = undefined;
    const mem_pct_str = std.fmt.bufPrint(&mem_pct_buf, "{d:.2}%", .{mem.percent}) catch "0.00%";

    try writer.print("{s:<14} {s:<20} {s:<9} {s:<24} {s:<9} {d}\n", .{
        utils.shortId(id),
        name,
        cpu_str,
        mem_col,
        mem_pct_str,
        pids,
    });
}

fn fetchAndPrintStats(
    client: *const http.Client,
    logger: *log.Logger,
    id: []const u8,
    writer: anytype,
) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/stats?stream=false", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(ContainerStats, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try formatStatsRow(writer, id, parsed.value);
}

/// Fetches a one-shot (`stream=false`) snapshot of CPU, memory, and PIDs metrics
/// for the specified containers (or all running/listed containers when empty).
pub fn statsContainers(
    client: *const http.Client,
    logger: *log.Logger,
    containers: []const []const u8,
    all: bool,
    writer: anytype,
) !void {
    if (containers.len > 0) {
        // Validate every target before opening any socket connection.
        for (containers) |c| try validateIdentifier(c);

        try writer.print("{s:<14} {s:<20} {s:<9} {s:<24} {s:<9} {s}\n", .{
            "CONTAINER ID", "NAME", "CPU %", "MEM USAGE / LIMIT", "MEM %", "PIDS",
        });
        for (containers) |c| {
            try fetchAndPrintStats(client, logger, c, writer);
        }
        logger.info("fetched stats for {d} container(s)", .{containers.len});
        return;
    }

    const list_path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/json?all={s}",
        .{ api_prefix, if (all) "true" else "false" },
    );
    defer client.allocator.free(list_path);

    logger.debug("GET {s}", .{list_path});
    const list_resp = try client.request("GET", list_path, null);
    defer list_resp.deinit();
    if (!list_resp.ok()) return logApiFailure(logger, "GET", list_path, list_resp);

    const list_parsed = try std.json.parseFromSlice([]ContainerSummary, client.allocator, list_resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer list_parsed.deinit();

    // Defense-in-depth: validate daemon-returned IDs before assembling /stats paths.
    for (list_parsed.value) |c| try validateIdentifier(c.Id);

    try writer.print("{s:<14} {s:<20} {s:<9} {s:<24} {s:<9} {s}\n", .{
        "CONTAINER ID", "NAME", "CPU %", "MEM USAGE / LIMIT", "MEM %", "PIDS",
    });
    for (list_parsed.value) |c| {
        try fetchAndPrintStats(client, logger, c.Id, writer);
    }
    logger.info("fetched stats for {d} container(s)", .{list_parsed.value.len});
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

    // Invalid network/identity/capability fields fail closed before any socket traffic.
    try std.testing.expectError(
        ApiError.InvalidNetwork,
        createContainer(&client, &logger, .{ .Image = "alpine:3.20", .HostConfig = .{ .NetworkMode = "bogus" } }, null),
    );
    try std.testing.expectError(
        ApiError.InvalidWorkdir,
        createContainer(&client, &logger, .{ .Image = "alpine:3.20", .WorkingDir = "relative" }, null),
    );
    const bad_caps = [_][]const u8{"net_admin"};
    try std.testing.expectError(
        ApiError.InvalidCapability,
        createContainer(&client, &logger, .{ .Image = "alpine:3.20", .HostConfig = .{ .CapAdd = &bad_caps } }, null),
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
    try fetchLogs(&client, &logger, id, false, logs_out.writer());
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
}

test "inspect renders container state, network, mounts, and hardening" {
    const alloc = std.testing.allocator;
    const json =
        \\{"Id":"abc123","Name":"/web","Image":"alpine:3.20","Created":"2026-01-01T00:00:00Z",
        \\"State":{"Status":"running","Running":true,"ExitCode":0,"StartedAt":"2026-01-01T00:00:01Z","FinishedAt":""},
        \\"Config":{"WorkingDir":"/work","User":"1000:1000"},
        \\"HostConfig":{"Memory":67108864,"PidsLimit":32,"ReadonlyRootfs":true,"NetworkMode":"none","CapDrop":["ALL"],"CapAdd":["NET_BIND_SERVICE"],"SecurityOpt":["no-new-privileges"],"AutoRemove":true},
        \\"NetworkSettings":{"IPAddress":"","Networks":{"podman":{"IPAddress":"10.88.0.2"}}},
        \\"Mounts":[{"Type":"bind","Source":"/srv/data","Destination":"/data","RW":false}]}
    ;
    const parsed = try std.json.parseFromSlice(ContainerInspect, alloc, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();
    try printContainerInspect(out.writer(), parsed.value);

    const s = out.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "running (running=true, exit=0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "10.88.0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "1000:1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "NetworkMode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "CapDrop:") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "/srv/data -> /data (bind, ro)") != null);
}

test "inspect falls back from container to image over mock Unix socket" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-inspect-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const image_json = "{\"Id\":\"sha256:deadbeef\",\"RepoTags\":[\"alpine:3.20\"],\"Size\":7700000,\"Os\":\"linux\",\"Architecture\":\"amd64\"}";
    const image_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ image_json.len, image_json },
    );

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/containers/alpine:3.20/json HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 21\r\n\r\n{\"message\":\"no such\"}",
        },
        .{
            .expected_prefix = "GET /v1.40/images/alpine:3.20/json HTTP/1.1\r\n",
            .raw_response = image_resp,
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

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try inspect(&client, &logger, "alpine:3.20", out.writer());

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 2), ctx.matched);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "sha256:deadbeef") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "alpine:3.20") != null);
}

test "exec command over mock Unix socket streams output and returns exit code" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-exec-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const create_json = "{\"Id\":\"exec123\"}";
    const create_resp = std.fmt.comptimePrint(
        "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ create_json.len, create_json },
    );
    const start_raw = "\x01\x00\x00\x00\x00\x00\x00\x03hi\n";
    const start_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ start_raw.len, start_raw },
    );
    const inspect_json = "{\"Running\":false,\"ExitCode\":7}";
    const inspect_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ inspect_json.len, inspect_json },
    );

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/containers/web/exec HTTP/1.1\r\n",
            .raw_response = create_resp,
        },
        .{
            .expected_prefix = "POST /v1.40/exec/exec123/start HTTP/1.1\r\n",
            .raw_response = start_resp,
        },
        .{
            .expected_prefix = "GET /v1.40/exec/exec123/json HTTP/1.1\r\n",
            .raw_response = inspect_resp,
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

    // Validation fails before any socket traffic.
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        createExec(&client, &logger, "../bad", .{ .Cmd = &.{"ls"} }),
    );
    try std.testing.expectError(
        ApiError.InvalidUser,
        createExec(&client, &logger, "web", .{ .Cmd = &.{"ls"}, .User = "bad user" }),
    );
    try std.testing.expectError(
        ApiError.InvalidWorkdir,
        createExec(&client, &logger, "web", .{ .Cmd = &.{"ls"}, .WorkingDir = "relative" }),
    );

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const code = try execCommand(&client, &logger, "web", .{ .Cmd = &.{"echo", "hi"} }, out.writer());

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(i64, 7), code);
    try std.testing.expectEqualStrings("hi\n", out.items);
    try std.testing.expectEqual(replies.len, ctx.matched);
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

test "computeCpuPercent and computeMemoryUsage handle normal and boundary cases" {
    const s = ContainerStats{
        .cpu_stats = .{
            .cpu_usage = .{ .total_usage = 200_000_000 },
            .system_cpu_usage = 2_000_000_000,
            .online_cpus = 4,
        },
        .precpu_stats = .{
            .cpu_usage = .{ .total_usage = 100_000_000 },
            .system_cpu_usage = 1_000_000_000,
        },
        .memory_stats = .{
            .usage = 100 * 1024 * 1024,
            .limit = 512 * 1024 * 1024,
            .stats = .{ .inactive_file = 36 * 1024 * 1024 },
        },
    };
    // (100M / 1000M) * 4 * 100 = 40.0%
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), computeCpuPercent(s), 0.001);

    const mem = computeMemoryUsage(s.memory_stats);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), mem.used);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), mem.limit);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), mem.percent, 0.001);

    // Underflow / zero / missing stats must return 0 safely without panic.
    const empty = ContainerStats{};
    try std.testing.expectEqual(@as(f64, 0.0), computeCpuPercent(empty));
    const zero_mem = computeMemoryUsage(null);
    try std.testing.expectEqual(@as(u64, 0), zero_mem.used);
    try std.testing.expectEqual(@as(f64, 0.0), zero_mem.percent);

    const underflow = ContainerStats{
        .cpu_stats = .{
            .cpu_usage = .{ .total_usage = 50 },
            .system_cpu_usage = 100,
        },
        .precpu_stats = .{
            .cpu_usage = .{ .total_usage = 100 },
            .system_cpu_usage = 200,
        },
        .memory_stats = .{
            .usage = 100,
            .limit = 0,
            .stats = .{ .cache = 200 },
        },
    };
    try std.testing.expectEqual(@as(f64, 0.0), computeCpuPercent(underflow));
    const umem = computeMemoryUsage(underflow.memory_stats);
    try std.testing.expectEqual(@as(u64, 0), umem.used);
    try std.testing.expectEqual(@as(f64, 0.0), umem.percent);
}

test "statsContainers fetches metrics via mock Unix socket and enforces identifier guard" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-stats-test-{d}.sock",
        .{std.time.milliTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const list_json = "[{\"Id\":\"abcdef1234567890\",\"Image\":\"alpine:3.20\",\"Status\":\"Up\",\"Names\":[\"/web\"]}]";
    const list_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ list_json.len, list_json },
    );
    const stats_json =
        "{\"id\":\"abcdef1234567890\",\"name\":\"/web\"," ++
        "\"cpu_stats\":{\"cpu_usage\":{\"total_usage\":200000000},\"system_cpu_usage\":2000000000,\"online_cpus\":2}," ++
        "\"precpu_stats\":{\"cpu_usage\":{\"total_usage\":100000000},\"system_cpu_usage\":1000000000}," ++
        "\"memory_stats\":{\"usage\":67108864,\"limit\":268435456,\"stats\":{\"inactive_file\":16777216}}," ++
        "\"pids_stats\":{\"current\":12}}";
    const stats_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ stats_json.len, stats_json },
    );

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/containers/json?all=false HTTP/1.1\r\n",
            .raw_response = list_resp,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/abcdef1234567890/stats?stream=false HTTP/1.1\r\n",
            .raw_response = stats_resp,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/stats?stream=false HTTP/1.1\r\n",
            .raw_response = stats_resp,
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

    // Invalid identifier must be rejected before any socket traffic.
    var bad_out = std.ArrayList(u8).init(std.testing.allocator);
    defer bad_out.deinit();
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        statsContainers(&client, &logger, &.{"../bad"}, false, bad_out.writer()),
    );

    // 1) All running containers (empty list -> GET /containers/json -> GET /stats?stream=false)
    var out1 = std.ArrayList(u8).init(std.testing.allocator);
    defer out1.deinit();
    try statsContainers(&client, &logger, &.{}, false, out1.writer());
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "CONTAINER ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "abcdef123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "web") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "20.00%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "48.0 MB / 256.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "18.75%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.items, "12") != null);

    // 2) Explicit container name
    var out2 = std.ArrayList(u8).init(std.testing.allocator);
    defer out2.deinit();
    try statsContainers(&client, &logger, &.{"web"}, false, out2.writer());
    try std.testing.expect(std.mem.indexOf(u8, out2.items, "48.0 MB / 256.0 MB") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "LogDemuxer handles split frames and raw TTY passthrough" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    var d = LogDemuxer(@TypeOf(out.writer())){
        .allocator = std.testing.allocator,
        .writer = out.writer(),
    };
    defer d.deinit();

    // Split an 8-byte header + 5-byte payload across multiple pushes.
    const frame = "\x01\x00\x00\x00\x00\x00\x00\x05hello\x02\x00\x00\x00\x00\x00\x00\x06 world";
    try d.push(frame[0..4]);
    try d.push(frame[4..10]);
    try d.push(frame[10..]);
    try d.flush();
    try std.testing.expectEqualStrings("hello world", out.items);

    // Raw TTY text without multiplexed header.
    var raw_out = std.ArrayList(u8).init(std.testing.allocator);
    defer raw_out.deinit();
    var d_raw = LogDemuxer(@TypeOf(raw_out.writer())){
        .allocator = std.testing.allocator,
        .writer = raw_out.writer(),
    };
    defer d_raw.deinit();
    try d_raw.push("plain tty ");
    try d_raw.push("output\n");
    try d_raw.flush();
    try std.testing.expectEqualStrings("plain tty output\n", raw_out.items);
}

fn runPhase2MockServer(server: *std.net.Server) void {
    // 1) pullImage streaming chunked JSON lines
    if (server.accept()) |conn| {
        defer conn.stream.close();
        var req_buf: [512]u8 = undefined;
        _ = conn.stream.read(&req_buf) catch {};
        conn.stream.writeAll(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "1e\r\n{\"status\":\"Pulling\",\"id\":\"1\"}\n\r\n" ++
                "18\r\n{\"status\":\"Downloaded\"}\n\r\n0\r\n\r\n",
        ) catch {};
    } else |_| {}

    // 2) logs -f (follow=1) chunked multiplexed frames
    if (server.accept()) |conn| {
        defer conn.stream.close();
        var req_buf: [512]u8 = undefined;
        _ = conn.stream.read(&req_buf) catch {};
        conn.stream.writeAll(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "d\r\n\x01\x00\x00\x00\x00\x00\x00\x05live\n\r\n0\r\n\r\n",
        ) catch {};
    } else |_| {}

    // 3) attachContainer 101 upgrade with stdin -> echo
    if (server.accept()) |conn| {
        defer conn.stream.close();
        var req_buf: [512]u8 = undefined;
        _ = conn.stream.read(&req_buf) catch {};
        conn.stream.writeAll("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n$") catch {};
        var in_buf: [64]u8 = undefined;
        const n = conn.stream.read(&in_buf) catch 0;
        if (n > 0) conn.stream.writeAll(in_buf[0..n]) catch {};
    } else |_| {}
}

test "pullImage streaming, logs -f, and attachContainer 101 upgrade" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-phase2-test-{d}.sock",
        .{std.time.milliTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, runPhase2MockServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
    };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    // 1) pullImage streaming
    var pull_out = std.ArrayList(u8).init(std.testing.allocator);
    defer pull_out.deinit();
    try pullImage(&client, &logger, "alpine:3.20", pull_out.writer());
    try std.testing.expect(std.mem.indexOf(u8, pull_out.items, "1: Pulling") != null);
    try std.testing.expect(std.mem.indexOf(u8, pull_out.items, "Downloaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, pull_out.items, "Pulled alpine:3.20") != null);

    // 2) logs -f (follow=1)
    var log_out = std.ArrayList(u8).init(std.testing.allocator);
    defer log_out.deinit();
    try fetchLogs(&client, &logger, "web", true, log_out.writer());
    try std.testing.expectEqualStrings("live\n", log_out.items);

    // 3) attachContainer 101 upgrade with pipe stdin
    const pipe_fds = try std.posix.pipe();
    var read_open = true;
    var write_open = true;
    defer {
        if (read_open) std.posix.close(pipe_fds[0]);
        if (write_open) std.posix.close(pipe_fds[1]);
    }
    _ = try std.posix.write(pipe_fds[1], "id\n");
    std.posix.close(pipe_fds[1]);
    write_open = false;

    var tty_out = std.ArrayList(u8).init(std.testing.allocator);
    defer tty_out.deinit();
    try attachContainer(&client, &logger, "web", true, true, pipe_fds[0], tty_out.writer());
    std.posix.close(pipe_fds[0]);
    read_open = false;

    try std.testing.expectEqualStrings("$id\n", tty_out.items);

    // Invalid identifier must still fail before any socket traffic.
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        attachContainer(&client, &logger, "../bad", true, true, null, tty_out.writer()),
    );

    thread.join();
    joined = true;
}
