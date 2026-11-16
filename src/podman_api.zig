//! Podman / Docker-compatible REST API (v1.40) client functions.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
pub const types = @import("podman_types.zig");
pub const validate = @import("podman_validate.zig");
pub const logs = @import("podman_logs.zig");
pub const images = @import("podman_images.zig");
pub const system = @import("podman_system.zig");
const th = @import("podman_test_helpers.zig");

pub const api_prefix = validate.api_prefix;

pub const ApiError = types.ApiError;
pub const TmpfsBounds = types.TmpfsBounds;
pub const RestartPolicy = types.RestartPolicy;
pub const Ulimit = types.Ulimit;
pub const HealthConfig = types.HealthConfig;
pub const HostConfig = types.HostConfig;
pub const Mount = types.Mount;
pub const PortMapping = types.PortMapping;
pub const ExposedPorts = types.ExposedPorts;
pub const PortBindings = types.PortBindings;
pub const LabelEntry = types.LabelEntry;
pub const LabelsMap = types.LabelsMap;
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
pub const ContainerTop = types.ContainerTop;
pub const VolumeCreateRequest = types.VolumeCreateRequest;
pub const VolumeInfo = types.VolumeInfo;
pub const VolumeListResponse = types.VolumeListResponse;
pub const NetworkInfo = types.NetworkInfo;
pub const NetworkCreateRequest = types.NetworkCreateRequest;
pub const NetworkCreateResponse = types.NetworkCreateResponse;
pub const SystemDfResponse = types.SystemDfResponse;
pub const ContainerPruneResponse = types.ContainerPruneResponse;
pub const ImagePruneItem = types.ImagePruneItem;
pub const ImagePruneResponse = types.ImagePruneResponse;
pub const StatsJsonEntry = types.StatsJsonEntry;

// Re-exported validators & builders
pub const validateIdentifier = validate.validateIdentifier;
pub const validateResourceRef = validate.validateResourceRef;
pub const validateHostPath = validate.validateHostPath;
pub const validateContainerPath = validate.validateContainerPath;
pub const validateVolumeName = validate.validateVolumeName;
pub const makeMount = validate.makeMount;
pub const validatePortMapping = validate.validatePortMapping;
pub const makePortMapping = validate.makePortMapping;
pub const validateNetworkMode = validate.validateNetworkMode;
pub const validateWorkdir = validate.validateWorkdir;
pub const validateUser = validate.validateUser;
pub const validateCapability = validate.validateCapability;
pub const validateSignal = validate.validateSignal;
pub const validateNanoCpus = validate.validateNanoCpus;
pub const validateHostname = validate.validateHostname;
pub const validateRestartPolicy = validate.validateRestartPolicy;
pub const validateLabel = validate.validateLabel;
pub const validateNetworkDriver = validate.validateNetworkDriver;
pub const validateCpContainerPath = validate.validateCpContainerPath;
pub const validateShmSize = validate.validateShmSize;
pub const validateUlimit = validate.validateUlimit;
pub const validateHealthConfig = validate.validateHealthConfig;
pub const loadAndMergeEnv = validate.loadAndMergeEnv;
const validateMount = validate.validateMount;
const appendQueryEncoded = validate.appendQueryEncoded;
const logApiFailure = validate.logApiFailure;

// Re-exported log demuxer & stats
pub const LogDemuxer = logs.LogDemuxer;
pub const computeCpuPercent = logs.computeCpuPercent;
pub const computeMemoryUsage = logs.computeMemoryUsage;
pub const statsContainers = logs.statsContainers;
pub const streamContainerStats = logs.streamContainerStats;
pub const statsContainersJson = logs.statsContainersJson;
pub const demuxLogs = logs.demuxLogs;

// Re-exported image endpoints
pub const removeImage = images.removeImage;
pub const listImages = images.listImages;
pub const listImagesJson = images.listImagesJson;
pub const pullImage = images.pullImage;
pub const tagImage = images.tagImage;
pub const imageHistory = images.imageHistory;
pub const commitContainer = images.commitContainer;

// Re-exported volume, network, system & inspect endpoints
pub const listVolumes = system.listVolumes;
pub const createVolume = system.createVolume;
pub const removeVolume = system.removeVolume;
pub const inspectVolume = system.inspectVolume;
pub const listNetworks = system.listNetworks;
pub const inspectNetwork = system.inspectNetwork;
pub const createNetwork = system.createNetwork;
pub const removeNetwork = system.removeNetwork;
pub const systemPing = system.systemPing;
pub const systemDf = system.systemDf;
pub const systemPrune = system.systemPrune;
pub const showVersion = system.showVersion;
pub const inspect = system.inspect;
pub const inspectJson = system.inspectJson;
pub const portContainer = system.portContainer;
pub const diffContainer = system.diffContainer;
pub const fetchEvents = system.fetchEvents;

const ScriptedReply = th.ScriptedReply;
const MockApiCtx = th.MockApiCtx;
const runMockPodmanServer = th.runMockPodmanServer;
const readHttpRequest = th.readHttpRequest;

/// Creates a container and returns its allocated container ID.
pub fn createContainer(
    client: *const http.Client,
    logger: *log.Logger,
    cfg: ContainerCreateRequest,
    name: ?[]const u8,
) ![]u8 {
    const io = client.io;
    if (name) |n| try validateIdentifier(n);
    // Defense in depth: validate image reference before touching the socket (BUG-043).
    try validateResourceRef(cfg.Image);
    // Defense in depth: never serialize an unsafe mount even if a caller
    // constructed `Mount` values by hand (BUG-014).
    if (cfg.Mounts) |mounts| {
        for (mounts) |m| try validateMount(io, m);
    }
    if (cfg.ExposedPorts) |exposed| {
        for (exposed.ports) |p| try validatePortMapping(p);
    }
    // Defense in depth: validate identity/network/capability/resource fields (BUG-016).
    if (cfg.Hostname) |h| try validateHostname(h);
    if (cfg.Labels) |labels| for (labels.entries) |entry| try validateLabel(entry);
    if (cfg.Healthcheck) |hc| try validateHealthConfig(hc);
    if (cfg.WorkingDir) |w| try validateWorkdir(w);
    if (cfg.User) |u| try validateUser(u);
    if (cfg.HostConfig) |hc| {
        if (hc.PortBindings) |pb| {
            for (pb.ports) |p| try validatePortMapping(p);
        }
        if (hc.ShmSize) |shm| try validateShmSize(shm);
        if (hc.Ulimits) |ulimits| for (ulimits) |u| try validateUlimit(u);
        if (hc.NanoCpus) |nc| try validateNanoCpus(nc);
        if (hc.RestartPolicy) |rp| try validateRestartPolicy(rp);
        if (hc.NetworkMode) |m| try validateNetworkMode(m);
        if (hc.CapDrop) |caps| for (caps) |c| try validateCapability(c);
        if (hc.CapAdd) |caps| for (caps) |c| try validateCapability(c);
    }
    if (cfg.NetworkingConfig) |nc| {
        if (nc.EndpointsConfig.networks.len == 0) return ApiError.InvalidNetwork;
        for (nc.EndpointsConfig.networks) |net_name| {
            validateIdentifier(net_name) catch return ApiError.InvalidNetwork;
        }
        if (cfg.HostConfig) |hc| {
            if (hc.NetworkMode != null) return ApiError.InvalidNetwork;
        }
    }

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(client.allocator);
    try path_buf.appendSlice(client.allocator, api_prefix ++ "/containers/create");
    if (name) |n| {
        try path_buf.appendSlice(client.allocator, "?name=");
        try appendQueryEncoded(client.allocator, &path_buf, n);
    }

    const req_body = try std.json.Stringify.valueAlloc(client.allocator, cfg, .{
        .emit_null_optional_fields = false,
    });
    defer client.allocator.free(req_body);

    logger.debug("POST {s} (image={s}, env_count={d}, cmd_len={d}, body_len={d})", .{
        path_buf.items,
        cfg.Image,
        if (cfg.Env) |e| e.len else 0,
        if (cfg.Cmd) |c| c.len else 0,
        req_body.len,
    });
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

    if (resp.status != 204 and resp.status != 304 and !resp.ok()) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("started container {s}", .{utils.shortId(id)});
}

/// Stops a container (`POST /containers/{id}/stop[?t={secs}]`).
pub fn stopContainer(client: *const http.Client, logger: *log.Logger, id: []const u8, timeout_secs: ?u32) !void {
    try validateIdentifier(id);
    if (timeout_secs) |t| {
        if (t > 3600) return ApiError.InvalidTimeout;
    }

    const path = if (timeout_secs) |t|
        try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/stop?t={d}", .{ api_prefix, id, t })
    else
        try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/stop", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and resp.status != 304 and !resp.ok()) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("stopped container {s}", .{utils.shortId(id)});
}

/// Restarts a container (`POST /containers/{id}/restart[?t={secs}]`).
pub fn restartContainer(client: *const http.Client, logger: *log.Logger, id: []const u8, timeout_secs: ?u32) !void {
    try validateIdentifier(id);
    if (timeout_secs) |t| {
        if (t > 3600) return ApiError.InvalidTimeout;
    }

    const path = if (timeout_secs) |t|
        try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/restart?t={d}", .{ api_prefix, id, t })
    else
        try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/restart", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("restarted container {s}", .{utils.shortId(id)});
}

/// Pauses all processes inside a container (`POST /containers/{id}/pause`).
pub fn pauseContainer(client: *const http.Client, logger: *log.Logger, id: []const u8) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/pause", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("paused container {s}", .{utils.shortId(id)});
}

/// Unpauses a paused container (`POST /containers/{id}/unpause`).
pub fn unpauseContainer(client: *const http.Client, logger: *log.Logger, id: []const u8) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/unpause", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("unpaused container {s}", .{utils.shortId(id)});
}

/// Renames an existing container (`POST /containers/{id}/rename?name={new_name}`).
/// Both `id` and `new_name` are validated with `validateIdentifier`.
pub fn renameContainer(client: *const http.Client, logger: *log.Logger, id: []const u8, new_name: []const u8) !void {
    try validateIdentifier(id);
    try validateIdentifier(new_name);

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/{s}/rename?name={s}",
        .{ api_prefix, id, new_name },
    );
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("renamed container {s} -> {s}", .{ utils.shortId(id), new_name });
}

/// Removes a local container image (`DELETE /images/{name}?force={true|false}`).
/// Sends an allow-listed signal to a running container (`POST /containers/{id}/kill?signal={sig}`).
pub fn killContainer(client: *const http.Client, logger: *log.Logger, id: []const u8, signal: []const u8) !void {
    try validateIdentifier(id);
    try validateSignal(signal);

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/{s}/kill?signal={s}",
        .{ api_prefix, id, signal },
    );
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "POST", path, resp);
    }
    logger.info("killed container {s} (signal={s})", .{ utils.shortId(id), signal });
}

/// Displays running processes inside a container (`GET /containers/{id}/top`).
pub fn topContainer(client: *const http.Client, logger: *log.Logger, id: []const u8, writer: anytype) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/top", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(ContainerTop, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.Titles) |titles| {
        for (titles, 0..) |t, idx| {
            if (idx > 0) try writer.writeAll("\t");
            try writer.writeAll(t);
        }
        try writer.writeAll("\n");
    }
    if (parsed.value.Processes) |procs| {
        for (procs) |row| {
            for (row, 0..) |col, idx| {
                if (idx > 0) try writer.writeAll("\t");
                try writer.writeAll(col);
            }
            try writer.writeAll("\n");
        }
        logger.info("listed {d} process(es) in container {s}", .{ procs.len, utils.shortId(id) });
    }
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

    if (resp.status != 204 and !resp.ok()) {
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

pub const LogOptions = struct {
    follow: bool = false,
    timestamps: bool = false,
    tail: ?u32 = null,
    since: ?u64 = null,
};

pub fn fetchLogs(client: *const http.Client, logger: *log.Logger, id: []const u8, follow: bool, writer: anytype) !void {
    return fetchLogsWithOptions(client, logger, id, .{ .follow = follow }, writer);
}

pub fn fetchLogsWithOptions(client: *const http.Client, logger: *log.Logger, id: []const u8, opts: LogOptions, writer: anytype) !void {
    try validateIdentifier(id);
    const follow = opts.follow;

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(client.allocator);
    try query.appendSlice(client.allocator, "stdout=1&stderr=1");
    if (follow) try query.appendSlice(client.allocator, "&follow=1");
    if (opts.timestamps) try query.appendSlice(client.allocator, "&timestamps=1");
    if (opts.tail) |n| try query.print(client.allocator, "&tail={d}", .{n});
    if (opts.since) |ts| try query.print(client.allocator, "&since={d}", .{ts});

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/{s}/logs?{s}",
        .{ api_prefix, id, query.items },
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
            if (names.len > 0) std.mem.trimStart(u8, names[0], "/") else ""
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

/// Emits validated JSON array for `zigpod ps [--json]` (`GET /containers/json?all={true|false}`).
pub fn listContainersJson(client: *const http.Client, logger: *log.Logger, all: bool, writer: anytype) !void {
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

    const json_out = try std.json.Stringify.valueAlloc(client.allocator, parsed.value, .{});
    defer client.allocator.free(json_out);
    try writer.print("{s}\n", .{json_out});
    logger.info("listed {d} container(s) as JSON (all={})", .{ parsed.value.len, all });
}

/// `POST /containers/{id}/exec`: validates the container and identity fields,
/// then returns the daemon-allocated exec ID.
pub fn createExec(client: *const http.Client, logger: *log.Logger, container: []const u8, req: ExecCreateRequest) ![]u8 {
    try validateIdentifier(container);
    if (req.User) |u| try validateUser(u);
    if (req.WorkingDir) |w| try validateWorkdir(w);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/exec", .{ api_prefix, container });
    defer client.allocator.free(path);

    const body = try std.json.Stringify.valueAlloc(client.allocator, req, .{ .emit_null_optional_fields = false });
    defer client.allocator.free(body);

    logger.debug("POST {s} (cmd_len={d}, body_len={d})", .{ path, req.Cmd.len, body.len });
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

    const body = try std.json.Stringify.valueAlloc(client.allocator, ExecStartRequest{}, .{});
    defer client.allocator.free(body);

    logger.debug("POST {s} (body_len={d})", .{ path, body.len });
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

    logger.debug("GET {s}", .{path});
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

fn interactiveTimeoutMs(client: *const http.Client) i32 {
    return if (client.timeout_ms != http.default_timeout_ms)
        client.timeout_ms
    else
        http.interactive_timeout_ms;
}

fn runUpgradedSession(
    client: *const http.Client,
    logger: *log.Logger,
    path: []const u8,
    up: http.UpgradedConn,
    tty: bool,
    stdin_fd: ?std.posix.fd_t,
    writer: anytype,
    timeout_ms: i32,
) !void {
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

    try pumpBidirectional(client.io, client.allocator, up.stream, up.initial_data, stdin_fd, writer, tty, timeout_ms);
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

    const body = try std.json.Stringify.valueAlloc(client.allocator, ExecStartRequest{
        .Detach = false,
        .Tty = tty,
    }, .{});
    defer client.allocator.free(body);

    const io_timeout_ms = interactiveTimeoutMs(client);
    logger.debug("UPGRADE POST {s} (tty={}, body_len={d})", .{ path, tty, body.len });
    const up = try client.upgrade("POST", path, body, io_timeout_ms);
    defer up.deinit();

    try runUpgradedSession(client, logger, path, up, tty, stdin_fd, writer, io_timeout_ms);
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

    const io_timeout_ms = interactiveTimeoutMs(client);
    logger.debug("UPGRADE POST {s}", .{path});
    const up = try client.upgrade("POST", path, null, io_timeout_ms);
    defer up.deinit();

    const active_in = if (interactive) stdin_fd else null;
    try runUpgradedSession(client, logger, path, up, tty, active_in, writer, io_timeout_ms);
}

/// Pumps bytes between an upgraded Unix socket `stream` and `stdin_fd` / `writer`,
/// enforcing `timeout_ms` across `poll` and socket writes so silent or broken
/// peers fail cleanly instead of spinning forever (BUG-032, BUG-037).
fn pumpBidirectional(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    initial_data: []const u8,
    stdin_fd: ?std.posix.fd_t,
    writer: anytype,
    tty: bool,
    timeout_ms: i32,
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
            .fd = stream.socket.handle,
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

        const ready = try std.posix.poll(fds[0..nfds], timeout_ms);
        if (ready == 0) return http.Error.Timeout;

        var handled = false;
        if (nfds == 2 and fds[1].revents != 0) {
            handled = true;
            if ((fds[1].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0 and
                (fds[1].revents & std.posix.POLL.IN) == 0)
            {
                active_stdin = null;
                // Signal EOF to peer on local stdin error (BUG-042).
                stream.shutdown(io, .send) catch {};
            } else if ((fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
                const n = std.posix.read(active_stdin.?, &buf) catch 0;
                if (n == 0) {
                    active_stdin = null;
                    // Forward local stdin EOF by shutting down the send half of the socket (BUG-042).
                    stream.shutdown(io, .send) catch {};
                } else {
                    try http.socket.writeAllWithTimeout(io, stream.socket.handle, buf[0..n], timeout_ms);
                }
            }
        }

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            handled = true;
            const n = try http.socket.readOnce(io, stream.socket.handle, &buf, timeout_ms);
            if (n == 0) break;
            if (tty) try writer.writeAll(buf[0..n]) else try demuxer.push(buf[0..n]);
        } else if ((fds[0].revents & std.posix.POLL.HUP) != 0) {
            break;
        } else if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return http.Error.InvalidResponse;
        }

        if (!handled) return http.Error.Timeout;
    }
    if (!tty) try demuxer.flush();
}

// ---------------------------------------------------------------- tests

test {
    _ = types;
    _ = validate;
    _ = logs;
    _ = images;
    _ = system;
    _ = th;
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

fn runDelayedWaitServer(server: *std.Io.net.Server) void {
    const conn = server.accept(std.testing.io) catch return;
    defer conn.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    _ = readHttpRequest(std.testing.io, conn, &buf) catch return;
    // BUG-007 regression: the daemon holds /wait until the container exits.
    // The reply arrives well after the client's short default timeout.
    std.Io.sleep(std.testing.io, .fromNanoseconds(150 * std.time.ns_per_ms), .awake) catch {};
    http.socket.streamWriteAll(conn, "HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\n{\"StatusCode\":0}") catch return;
}

test "waitContainer uses the blocking timeout when daemon delays response" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-delayed-wait-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer std.testing.allocator.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const thread = try std.Thread.spawn(.{}, runDelayedWaitServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .timeout_ms = 30,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    const status = try waitContainer(&client, &logger, "abcdef123456");
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(i64, 0), status);
}

test "end-to-end container lifecycle over mock Unix socket has zero memory leaks" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-lifecycle-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer std.testing.allocator.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

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

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    // Validation errors fail before hitting the socket.
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        createContainer(&client, &logger, .{ .Image = "alpine:3.20" }, "../bad"),
    );
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        createContainer(&client, &logger, .{ .Image = "alpine;rm -rf /" }, null),
    );
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        createContainer(&client, &logger, .{ .Image = "web/../../etc/shadow" }, null),
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
        ApiError.InvalidNetwork,
        createContainer(&client, &logger, .{
            .Image = "alpine:3.20",
            .NetworkingConfig = .{ .EndpointsConfig = .{ .networks = &.{"../evil"} } },
        }, null),
    );
    try std.testing.expectError(
        ApiError.InvalidNetwork,
        createContainer(&client, &logger, .{
            .Image = "alpine:3.20",
            .HostConfig = .{ .NetworkMode = "none" },
            .NetworkingConfig = .{ .EndpointsConfig = .{ .networks = &.{"back"} } },
        }, null),
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

    var logs_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer logs_out.deinit();
    try fetchLogs(&client, &logger, id, false, &logs_out.writer);
    try std.testing.expectEqualStrings("hi\n", logs_out.written());

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
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer std.testing.allocator.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

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

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try listContainers(&client, &logger, true, &out.writer);

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 1), ctx.matched);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "abcdef123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "alpine:3.20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "web") != null);
}

test "exec command over mock Unix socket streams output and returns exit code" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-api-exec-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer std.testing.allocator.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

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

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const code = try execCommand(&client, &logger, "web", .{ .Cmd = &.{ "echo", "hi" } }, &out.writer);

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(i64, 7), code);
    try std.testing.expectEqualStrings("hi\n", out.written());
    try std.testing.expectEqual(replies.len, ctx.matched);
}

fn runPhase2MockServer(server: *std.Io.net.Server) void {
    // 1) pullImage streaming chunked JSON lines
    if (server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        var req_buf: [512]u8 = undefined;
        _ = http.socket.streamRead(std.testing.io, conn, &req_buf) catch {};
        http.socket.streamWriteAll(
            conn,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "1e\r\n{\"status\":\"Pulling\",\"id\":\"1\"}\n\r\n" ++
                "18\r\n{\"status\":\"Downloaded\"}\n\r\n0\r\n\r\n",
        ) catch {};
    } else |_| {}

    // 2) logs -f (follow=1) chunked multiplexed frames
    if (server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        var req_buf: [512]u8 = undefined;
        _ = http.socket.streamRead(std.testing.io, conn, &req_buf) catch {};
        http.socket.streamWriteAll(
            conn,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
                "d\r\n\x01\x00\x00\x00\x00\x00\x00\x05live\n\r\n0\r\n\r\n",
        ) catch {};
    } else |_| {}

    // 3) attachContainer 101 upgrade with stdin -> echo
    if (server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        var req_buf: [512]u8 = undefined;
        _ = http.socket.streamRead(std.testing.io, conn, &req_buf) catch {};
        http.socket.streamWriteAll(conn, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n$") catch {};
        var in_buf: [64]u8 = undefined;
        const n = http.socket.streamRead(std.testing.io, conn, &in_buf) catch 0;
        if (n > 0) http.socket.streamWriteAll(conn, in_buf[0..n]) catch {};
    } else |_| {}
}

test "pullImage streaming, logs -f, and attachContainer 101 upgrade" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-phase2-test-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer std.testing.allocator.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const thread = try std.Thread.spawn(.{}, runPhase2MockServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    // 1) pullImage streaming
    var pull_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer pull_out.deinit();
    try pullImage(&client, &logger, "alpine:3.20", &pull_out.writer);
    try std.testing.expect(std.mem.indexOf(u8, pull_out.written(), "1: Pulling") != null);
    try std.testing.expect(std.mem.indexOf(u8, pull_out.written(), "Downloaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, pull_out.written(), "Pulled alpine:3.20") != null);

    // 2) logs -f (follow=1)
    var log_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer log_out.deinit();
    try fetchLogs(&client, &logger, "web", true, &log_out.writer);
    try std.testing.expectEqualStrings("live\n", log_out.written());

    // 3) attachContainer 101 upgrade with pipe stdin
    const pipe_fds = try utils.pipe();
    var read_open = true;
    var write_open = true;
    defer {
        if (read_open) utils.closeFd(pipe_fds[0]);
        if (write_open) utils.closeFd(pipe_fds[1]);
    }
    _ = try utils.writeFd(pipe_fds[1], "id\n");
    utils.closeFd(pipe_fds[1]);
    write_open = false;

    var tty_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tty_out.deinit();
    try attachContainer(&client, &logger, "web", true, true, pipe_fds[0], &tty_out.writer);
    utils.closeFd(pipe_fds[0]);
    read_open = false;

    try std.testing.expectEqualStrings("$id\n", tty_out.written());

    // Invalid identifier must still fail before any socket traffic.
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        attachContainer(&client, &logger, "../bad", true, true, null, &tty_out.writer),
    );

    thread.join();
    joined = true;
}

const InteractiveExecMockCtx = struct {
    server: *std.Io.net.Server,
    saw_attach_stdin: bool = false,
};

fn runInteractiveExecMockServer(ctx: *InteractiveExecMockCtx) void {
    // 1) POST /v1.40/containers/web/exec -> 201 Created {"Id":"execinteractive1"}
    if (ctx.server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        var req_buf: [1024]u8 = undefined;
        const n = http.socket.streamRead(std.testing.io, conn, &req_buf) catch 0;
        if (std.mem.indexOf(u8, req_buf[0..n], "\"AttachStdin\":true") != null and
            std.mem.indexOf(u8, req_buf[0..n], "\"Tty\":true") != null)
        {
            ctx.saw_attach_stdin = true;
        }
        http.socket.streamWriteAll(
            conn,
            "HTTP/1.1 201 Created\r\nContent-Length: 25\r\n\r\n{\"Id\":\"execinteractive1\"}",
        ) catch return;
    } else |_| return;

    // 2) POST /v1.40/exec/execinteractive1/start -> 101 Switching Protocols + echo
    if (ctx.server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        var req_buf: [512]u8 = undefined;
        _ = http.socket.streamRead(std.testing.io, conn, &req_buf) catch {};
        http.socket.streamWriteAll(
            conn,
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n# ",
        ) catch return;
        var in_buf: [64]u8 = undefined;
        const n = http.socket.streamRead(std.testing.io, conn, &in_buf) catch 0;
        if (n > 0) {
            http.socket.streamWriteAll(conn, in_buf[0..n]) catch {};
            http.socket.streamWriteAll(conn, "root\n") catch {};
        }
    } else |_| return;

    // 3) GET /v1.40/exec/execinteractive1/json -> 200 OK {"Running":false,"ExitCode":0}
    if (ctx.server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        var req_buf: [512]u8 = undefined;
        _ = http.socket.streamRead(std.testing.io, conn, &req_buf) catch {};
        http.socket.streamWriteAll(
            conn,
            "HTTP/1.1 200 OK\r\nContent-Length: 30\r\n\r\n{\"Running\":false,\"ExitCode\":0}",
        ) catch return;
    } else |_| return;
}

test "execCommandWithIo interactive 101 upgrade and TmpfsBounds JSON serialization" {
    const alloc = std.testing.allocator;

    // 1) Verify TmpfsBounds serializes as {"/tmp":"..."} inside HostConfig.
    const create_req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .HostConfig = .{
            .ReadonlyRootfs = true,
            .Tmpfs = .{ .tmp_options = "rw,noexec,nosuid,nodev,size=67108864" },
        },
    };
    const json_bytes = try std.json.Stringify.valueAlloc(alloc, create_req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json_bytes);
    try std.testing.expect(
        std.mem.indexOf(u8, json_bytes, "\"Tmpfs\":{\"/tmp\":\"rw,noexec,nosuid,nodev,size=67108864\"}") != null,
    );

    // 2) Verify execCommandWithIo (AttachStdin=true, Tty=true) over 101 Switching Protocols.
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-exec-interactive-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    var ctx = InteractiveExecMockCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runInteractiveExecMockServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    const pipe_fds = try utils.pipe();
    var read_open = true;
    var write_open = true;
    defer {
        if (read_open) utils.closeFd(pipe_fds[0]);
        if (write_open) utils.closeFd(pipe_fds[1]);
    }
    _ = try utils.writeFd(pipe_fds[1], "whoami\n");
    utils.closeFd(pipe_fds[1]);
    write_open = false;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const exit_code = try execCommandWithIo(&client, &logger, "web", .{
        .AttachStdin = true,
        .Tty = true,
        .Cmd = &.{"sh"},
    }, pipe_fds[0], &out.writer);
    utils.closeFd(pipe_fds[0]);
    read_open = false;

    thread.join();
    joined = true;

    try std.testing.expect(ctx.saw_attach_stdin);
    try std.testing.expectEqual(@as(i64, 0), exit_code);
    try std.testing.expectEqualStrings("# whoami\nroot\n", out.written());
}

test "kill, top, volume, and network endpoints + signal/name validation" {
    const alloc = std.testing.allocator;

    // 1) Pre-flight validator unit checks
    try validateSignal("SIGTERM");
    try validateSignal("SIGKILL");
    try validateSignal("INT");
    try std.testing.expectError(ApiError.InvalidSignal, validateSignal(""));
    try std.testing.expectError(ApiError.InvalidSignal, validateSignal("sigterm"));
    try std.testing.expectError(ApiError.InvalidSignal, validateSignal("9"));
    try std.testing.expectError(ApiError.InvalidSignal, validateSignal("SIGKILL&force=true"));

    // 2) Mock Unix socket server covering kill, top, volume (ls/create/inspect/rm), network (ls/inspect)
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-phase4-api-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const top_json = "{\"Titles\":[\"UID\",\"PID\",\"CMD\"],\"Processes\":[[\"root\",\"1234\",\"sleep 60\"]]}";
    const vol_list_json = "{\"Volumes\":[{\"Name\":\"app-data\",\"Driver\":\"local\",\"Mountpoint\":\"/var/lib/containers/storage/volumes/app-data/_data\"}]}";
    const vol_info_json = "{\"Name\":\"app-data\",\"Driver\":\"local\",\"Mountpoint\":\"/var/lib/containers/storage/volumes/app-data/_data\",\"CreatedAt\":\"2026-11-14T00:00:00Z\"}";
    const net_list_json = "[{\"Id\":\"abcdef0123456789\",\"Name\":\"podman\",\"Driver\":\"bridge\",\"Scope\":\"local\"}]";
    const net_info_json = "{\"Id\":\"abcdef0123456789\",\"Name\":\"podman\",\"Driver\":\"bridge\",\"Scope\":\"local\",\"Internal\":false}";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/containers/web/kill?signal=SIGKILL HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/top HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ top_json.len, top_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/volumes HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ vol_list_json.len, vol_list_json }),
        },
        .{
            .expected_prefix = "POST /v1.40/volumes/create HTTP/1.1\r\n",
            .expected_substring = "\"Name\":\"app-data\"",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}", .{ vol_info_json.len, vol_info_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/volumes/app-data HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ vol_info_json.len, vol_info_json }),
        },
        .{
            .expected_prefix = "DELETE /v1.40/volumes/app-data?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "GET /v1.40/networks HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ net_list_json.len, net_list_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/networks/podman HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ net_info_json.len, net_info_json }),
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Reject bad signal or traversal names before touching the socket.
    try std.testing.expectError(ApiError.InvalidSignal, killContainer(&client, &logger, "web", "SIGBAD"));
    try std.testing.expectError(ApiError.InvalidHostPath, createVolume(&client, &logger, "../bad", &out.writer));
    try std.testing.expectError(ApiError.InvalidIdentifier, inspectNetwork(&client, &logger, "../bad", &out.writer));

    try killContainer(&client, &logger, "web", "SIGKILL");

    try topContainer(&client, &logger, "web", &out.writer);
    try std.testing.expectEqualStrings("UID\tPID\tCMD\nroot\t1234\tsleep 60\n", out.written());

    out.clearRetainingCapacity();
    try listVolumes(&client, &logger, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "app-data") != null);

    out.clearRetainingCapacity();
    try createVolume(&client, &logger, "app-data", &out.writer);
    try std.testing.expectEqualStrings("app-data\n", out.written());

    out.clearRetainingCapacity();
    try inspectVolume(&client, &logger, "app-data", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Mountpoint:") != null);

    try removeVolume(&client, &logger, "app-data", true);

    out.clearRetainingCapacity();
    try listNetworks(&client, &logger, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "podman") != null);

    out.clearRetainingCapacity();
    try inspectNetwork(&client, &logger, "podman", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Driver:        bridge") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "restart, pause, unpause, rename, and removeImage endpoints + validation" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-phase5-api-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const replies = [_]ScriptedReply{
        .{
            // Test that 200 OK (from proxies) is accepted alongside 204 No Content.
            .expected_prefix = "POST /v1.40/containers/web/restart?t=5 HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/web/pause HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/web/unpause HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/web/rename?name=web2 HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "DELETE /v1.40/images/alpine:3.20?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]",
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Pre-flight validation must reject bad identifiers before touching the socket.
    try std.testing.expectError(ApiError.InvalidIdentifier, restartContainer(&client, &logger, "../bad", 5));
    try std.testing.expectError(ApiError.InvalidTimeout, restartContainer(&client, &logger, "web", 99999));
    try std.testing.expectError(ApiError.InvalidIdentifier, pauseContainer(&client, &logger, "../bad"));
    try std.testing.expectError(ApiError.InvalidIdentifier, unpauseContainer(&client, &logger, "../bad"));
    try std.testing.expectError(ApiError.InvalidIdentifier, renameContainer(&client, &logger, "web", "../bad"));
    try std.testing.expectError(ApiError.InvalidIdentifier, removeImage(&client, &logger, "alpine?evil=1", true, &out.writer));

    try restartContainer(&client, &logger, "web", 5);
    try pauseContainer(&client, &logger, "web");
    try unpauseContainer(&client, &logger, "web");
    try renameContainer(&client, &logger, "web", "web2");
    try removeImage(&client, &logger, "alpine:3.20", true, &out.writer);
    try std.testing.expectEqualStrings("Removed alpine:3.20\n", out.written());

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "stopContainer timeout and fetchLogsWithOptions query parameters" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-stop-logs-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const frame = "\x01\x00\x00\x00\x00\x00\x00\x03hi\n";
    const log_resp = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n" ++ frame;
    const replies = [_]ScriptedReply{
        .{ .expected_prefix = "POST /v1.40/containers/web/stop?t=7 HTTP/1.1\r\n", .raw_response = "HTTP/1.1 204 No Content\r\n\r\n" },
        .{ .expected_prefix = "POST /v1.40/containers/web/stop HTTP/1.1\r\n", .raw_response = "HTTP/1.1 204 No Content\r\n\r\n" },
        .{ .expected_prefix = "GET /v1.40/containers/web/logs?stdout=1&stderr=1&timestamps=1&tail=20&since=1700000000 HTTP/1.1\r\n", .raw_response = log_resp },
        .{ .expected_prefix = "GET /v1.40/containers/web/logs?stdout=1&stderr=1&tail=0 HTTP/1.1\r\n", .raw_response = log_resp },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Validation happens before any socket traffic.
    try std.testing.expectError(ApiError.InvalidIdentifier, stopContainer(&client, &logger, "../bad", 5));
    try std.testing.expectError(ApiError.InvalidTimeout, stopContainer(&client, &logger, "web", 3601));
    try std.testing.expectError(ApiError.InvalidIdentifier, fetchLogsWithOptions(&client, &logger, "a?b=1", .{}, &out.writer));

    try stopContainer(&client, &logger, "web", 7);
    try stopContainer(&client, &logger, "web", null);
    try fetchLogsWithOptions(&client, &logger, "web", .{ .timestamps = true, .tail = 20, .since = 1700000000 }, &out.writer);
    try fetchLogsWithOptions(&client, &logger, "web", .{ .tail = 0 }, &out.writer);
    try std.testing.expectEqualStrings("hi\nhi\n", out.written());

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "listContainersJson, listImagesJson, inspectJson, and statsContainersJson endpoints" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-json-api-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const ps_json = "[{\"Id\":\"c1234567890\",\"Image\":\"alpine:3.20\",\"Status\":\"Up\",\"State\":\"running\",\"Names\":[\"/web\"]}]";
    const img_json = "[{\"Id\":\"sha256:abcd\",\"RepoTags\":[\"alpine:3.20\"],\"Size\":7340032}]";
    const insp_json = "{\"Id\":\"c1234567890\",\"Name\":\"/web\",\"Image\":\"alpine:3.20\"}";
    const stats_json =
        "{\"id\":\"c1234567890\",\"name\":\"/web\"," ++
        "\"cpu_stats\":{\"cpu_usage\":{\"total_usage\":200000000},\"system_cpu_usage\":2000000000,\"online_cpus\":2}," ++
        "\"precpu_stats\":{\"cpu_usage\":{\"total_usage\":100000000},\"system_cpu_usage\":1000000000}," ++
        "\"memory_stats\":{\"usage\":67108864,\"limit\":268435456,\"stats\":{\"inactive_file\":16777216}}," ++
        "\"pids_stats\":{\"current\":12}}";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/containers/json?all=true HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ ps_json.len, ps_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/images/json HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ img_json.len, img_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/json HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ insp_json.len, insp_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/stats?stream=false HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ stats_json.len, stats_json }),
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try listContainersJson(&client, &logger, true, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"Id\":\"c1234567890\"") != null);

    out.clearRetainingCapacity();
    try listImagesJson(&client, &logger, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"alpine:3.20\"") != null);

    out.clearRetainingCapacity();
    try inspectJson(&client, &logger, "web", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"Name\":\"/web\"") != null);

    out.clearRetainingCapacity();
    try statsContainersJson(&client, &logger, &.{"web"}, false, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"mem_used_bytes\":50331648") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"pids\":12") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "BUG-024: createContainer and createExec never write raw Env or Cmd secrets to logs" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-api-redact-{d}.sock", .{std.Io.Clock.awake.now(std.testing.io).nanoseconds});
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const create_body = "{\"Id\":\"abcdef1234567890ff\",\"Warnings\":[]}";
    const exec_body = "{\"Id\":\"execid123456\"}";
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/containers/create HTTP/1.1\r\n",
            .raw_response = try std.fmt.allocPrint(alloc, "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}", .{ create_body.len, create_body }),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/box1/exec HTTP/1.1\r\n",
            .raw_response = try std.fmt.allocPrint(alloc, "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}", .{ exec_body.len, exec_body }),
        },
    };
    defer for (replies) |r| alloc.free(r.raw_response);

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger.init(std.testing.io, dir_path, true);
    logger.echo_stderr = false;
    defer logger.deinit();

    const cid = try createContainer(&client, &logger, .{
        .Image = "alpine:3.20",
        .Env = &.{"DB_PASSWORD=supersecret999"},
        .Cmd = &.{ "sh", "-c", "echo cmdsecret888" },
    }, null);
    defer alloc.free(cid);

    const eid = try createExec(&client, &logger, "box1", .{
        .Cmd = &.{ "mysql", "-pexecsecret777" },
    });
    defer alloc.free(eid);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);

    const sys_log = try tmp.dir.readFileAlloc(std.testing.io, "system.log", alloc, .limited(16384));
    defer alloc.free(sys_log);
    const audit_log = try tmp.dir.readFileAlloc(std.testing.io, "audit.log", alloc, .limited(16384));
    defer alloc.free(audit_log);

    for ([_][]const u8{ "supersecret999", "cmdsecret888", "execsecret777" }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, sys_log, secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, audit_log, secret) == null);
    }
}

test "BUG-034: createContainer validates HostConfig.PortBindings fail-closed without panicking" {
    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = "/tmp/nonexistent-zigpod-portbindings.sock",
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    const bad_bindings = [_]PortMapping{.{
        .host_port = 8080,
        .container_port = 80,
        .proto = "unexpected-long-proto",
    }};
    try std.testing.expectError(
        ApiError.InvalidPort,
        createContainer(&client, &logger, .{
            .Image = "alpine:3.20",
            .HostConfig = .{ .PortBindings = .{ .ports = &bad_bindings } },
        }, null),
    );
}

const SilentUpgradeMode = enum { attach_only, exec_create_then_upgrade };

const SilentUpgradeMockCtx = struct {
    server: *std.Io.net.Server,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mode: SilentUpgradeMode = .attach_only,
};

fn waitAcceptReady(server: *std.Io.net.Server, done: *const std.atomic.Value(bool)) bool {
    var accept_fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (!done.load(.acquire)) {
        const ready = std.posix.poll(&accept_fds, 5) catch return false;
        if (ready > 0) return true;
    }
    return false;
}

fn runSilentUpgradeMockServer(ctx: *SilentUpgradeMockCtx) void {
    if (ctx.mode == .exec_create_then_upgrade) {
        if (!waitAcceptReady(ctx.server, &ctx.done)) return;
        if (ctx.server.accept(std.testing.io)) |conn| {
            defer conn.close(std.testing.io);
            var req_buf: [1024]u8 = undefined;
            _ = http.socket.streamRead(std.testing.io, conn, &req_buf) catch {};
            const exec_body = "{\"Id\":\"execsilent1\"}";
            const resp = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ exec_body.len, exec_body },
            );
            http.socket.streamWriteAll(conn, resp) catch return;
        } else |_| return;
    }

    if (!waitAcceptReady(ctx.server, &ctx.done)) return;
    const conn = ctx.server.accept(std.testing.io) catch return;
    defer conn.close(std.testing.io);
    var req_buf: [1024]u8 = undefined;
    _ = http.socket.streamRead(std.testing.io, conn, &req_buf) catch {};
    http.socket.streamWriteAll(conn, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n") catch return;

    while (!ctx.done.load(.acquire)) {
        std.Io.sleep(std.testing.io, .fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
    }
}

fn runSilentUpgradeCase(
    alloc: std.mem.Allocator,
    sock_tag: []const u8,
    mode: SilentUpgradeMode,
    stdin_fd: ?std.posix.fd_t,
) !void {
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-bug032-{s}-{d}.sock", .{ sock_tag, std.Io.Clock.awake.now(std.testing.io).nanoseconds });
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    var ctx = SilentUpgradeMockCtx{ .server = &server, .mode = mode };
    const thread = try std.Thread.spawn(.{}, runSilentUpgradeMockServer, .{&ctx});
    var joined = false;
    defer {
        ctx.done.store(true, .release);
        if (!joined) thread.join();
    }

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .timeout_ms = 25, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const call_res = switch (mode) {
        .attach_only => attachContainer(&client, &logger, "web", stdin_fd != null, true, stdin_fd, &out.writer),
        .exec_create_then_upgrade => blk: {
            _ = execCommandWithIo(&client, &logger, "web", .{
                .AttachStdin = true,
                .Tty = true,
                .Cmd = &.{"sh"},
            }, stdin_fd, &out.writer) catch |e| break :blk @as(anyerror!void, e);
            break :blk @as(anyerror!void, {});
        },
    };
    try std.testing.expectError(http.Error.Timeout, call_res);

    ctx.done.store(true, .release);
    thread.join();
    joined = true;
}

test "BUG-032: interactive attach and exec return Error.Timeout on silent upgraded stream" {
    const alloc = std.testing.allocator;
    try std.testing.expect(http.interactive_timeout_ms < http.blocking_timeout_ms);

    // 1) attachContainer with null stdin and silent peer after 101 upgrade.
    try runSilentUpgradeCase(alloc, "attach", .attach_only, null);

    // 2) execCommandWithIo (interactive Tty) with idle open stdin pipe and silent peer.
    const pipe_fds = try utils.pipe();
    defer {
        utils.closeFd(pipe_fds[0]);
        utils.closeFd(pipe_fds[1]);
    }
    try runSilentUpgradeCase(alloc, "exec", .exec_create_then_upgrade, pipe_fds[0]);

    // 3) pumpBidirectional surfaces POLL.ERR cleanly instead of spinning.
    const err_pipe = try utils.pipe();
    utils.closeFd(err_pipe[0]);
    defer utils.closeFd(err_pipe[1]);
    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try std.testing.expectError(
        http.Error.InvalidResponse,
        pumpBidirectional(std.testing.io, alloc, .{ .socket = .{ .handle = err_pipe[1], .address = .{ .ip4 = .unspecified(0) } } }, "", null, &sink.writer, true, 25),
    );
}

test "BUG-042: pumpBidirectional shuts down send half on stdin EOF" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-stdin-eof-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const ServerContext = struct {
        srv: *std.Io.net.Server,
        saw_eof: bool = false,

        fn run(ctx: *@This()) void {
            var fds = [_]std.posix.pollfd{.{
                .fd = ctx.srv.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&fds, 2000) catch return;
            if (ready == 0) return;

            const conn = ctx.srv.accept(std.testing.io) catch return;
            defer conn.close(std.testing.io);

            var conn_fds = [_]std.posix.pollfd{.{
                .fd = conn.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};

            // 1. Read input forwarded by pumpBidirectional
            if ((std.posix.poll(&conn_fds, 2000) catch return) == 0) return;
            var in_buf: [32]u8 = undefined;
            const n1 = http.socket.streamRead(std.testing.io, conn, &in_buf) catch return;
            if (!std.mem.eql(u8, in_buf[0..n1], "ping\n")) return;

            // 2. Next read must return 0 because pumpBidirectional shut down send on stdin EOF
            if ((std.posix.poll(&conn_fds, 2000) catch return) == 0) return;
            const n2 = http.socket.streamRead(std.testing.io, conn, &in_buf) catch return;
            if (n2 == 0) {
                ctx.saw_eof = true;
                http.socket.streamWriteAll(conn, "pong\n") catch {};
            }
        }
    };

    var server_ctx = ServerContext{ .srv = &server };
    const thread = try std.Thread.spawn(.{}, ServerContext.run, .{&server_ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client_stream = try (try std.Io.net.UnixAddress.init(sock_path)).connect(std.testing.io);
    defer client_stream.close(std.testing.io);

    const pipe_fds = try utils.pipe();
    _ = try utils.writeFd(pipe_fds[1], "ping\n");
    utils.closeFd(pipe_fds[1]); // Close pipe write end to trigger EOF after "ping\n"

    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    try pumpBidirectional(std.testing.io, alloc, client_stream, "", pipe_fds[0], &output.writer, true, 500);
    utils.closeFd(pipe_fds[0]);

    thread.join();
    joined = true;

    try std.testing.expect(server_ctx.saw_eof);
    try std.testing.expectEqualStrings("pong\n", output.written());
}

fn pipeStream(fd: std.posix.fd_t) std.Io.net.Stream {
    return .{ .socket = .{ .handle = fd, .address = .{ .ip4 = .unspecified(0) } } };
}

test "pumpBidirectional ends cleanly when peer closes and flushes initial data (tty)" {
    const alloc = std.testing.allocator;
    const fds = try utils.pipe();
    defer utils.closeFd(fds[0]);
    utils.closeFd(fds[1]); // peer hangs up immediately -> POLL.HUP

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try pumpBidirectional(std.testing.io, alloc, pipeStream(fds[0]), "banner\n", null, &out.writer, true, 500);
    try std.testing.expectEqualStrings("banner\n", out.written());
}

test "pumpBidirectional demultiplexes initial data when not tty" {
    const alloc = std.testing.allocator;
    const fds = try utils.pipe();
    defer utils.closeFd(fds[0]);
    utils.closeFd(fds[1]);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const frame = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 5 } ++ "hello".*;
    try pumpBidirectional(std.testing.io, alloc, pipeStream(fds[0]), &frame, null, &out.writer, false, 500);
    try std.testing.expectEqualStrings("hello", out.written());
}

test "pumpBidirectional times out on a silent peer with idle stdin" {
    const alloc = std.testing.allocator;
    const peer = try utils.pipe(); // write end stays open and silent
    defer utils.closeFd(peer[0]);
    defer utils.closeFd(peer[1]);
    const stdin_pipe = try utils.pipe(); // idle, never written or closed
    defer utils.closeFd(stdin_pipe[0]);
    defer utils.closeFd(stdin_pipe[1]);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.testing.expectError(
        http.Error.Timeout,
        pumpBidirectional(std.testing.io, alloc, pipeStream(peer[0]), "", stdin_pipe[0], &out.writer, true, 25),
    );
    try std.testing.expectEqualStrings("", out.written());
}
