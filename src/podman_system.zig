//! Volume, network, system (ping/df/prune), version, and inspect endpoints.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const validate = @import("podman_validate.zig");
const th = @import("podman_test_helpers.zig");

const api_prefix = validate.api_prefix;
const validateVolumeName = validate.validateVolumeName;
const validateIdentifier = validate.validateIdentifier;
const validateResourceRef = validate.validateResourceRef;
const validateNetworkDriver = validate.validateNetworkDriver;
const appendQueryEncoded = validate.appendQueryEncoded;
const logApiFailure = validate.logApiFailure;
const formatSizeU64 = validate.formatSizeU64;

const ApiError = types.ApiError;
const ContainerDiffItem = types.ContainerDiffItem;
const DaemonEvent = types.DaemonEvent;
const VolumeCreateRequest = types.VolumeCreateRequest;
const VolumeInfo = types.VolumeInfo;
const VolumeListResponse = types.VolumeListResponse;
const NetworkInfo = types.NetworkInfo;
const NetworkCreateRequest = types.NetworkCreateRequest;
const NetworkCreateResponse = types.NetworkCreateResponse;
const SystemDfResponse = types.SystemDfResponse;
const ImageSummary = types.ImageSummary;
const ContainerPruneResponse = types.ContainerPruneResponse;
const ImagePruneResponse = types.ImagePruneResponse;
const VersionInfo = types.VersionInfo;
const ContainerInspect = types.ContainerInspect;
const ImageInspect = types.ImageInspect;

const MockApiCtx = th.MockApiCtx;
const ScriptedReply = th.ScriptedReply;
const runMockPodmanServer = th.runMockPodmanServer;

/// Lists named volumes (`GET /volumes`).
pub fn listVolumes(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const path = api_prefix ++ "/volumes";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    try writer.print("{s:<20} {s}\n", .{ "DRIVER", "VOLUME NAME" });

    const trimmed = std.mem.trimStart(u8, resp.body, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '[') {
        const parsed_arr = try std.json.parseFromSlice([]VolumeInfo, client.allocator, resp.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_arr.deinit();
        for (parsed_arr.value) |v| {
            try writer.print("{s:<20} {s}\n", .{ v.Driver, v.Name });
        }
        logger.info("listed {d} volume(s)", .{parsed_arr.value.len});
        return;
    }

    const parsed = try std.json.parseFromSlice(VolumeListResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const vols = parsed.value.Volumes orelse &[_]VolumeInfo{};
    for (vols) |v| {
        try writer.print("{s:<20} {s}\n", .{ v.Driver, v.Name });
    }
    logger.info("listed {d} volume(s)", .{vols.len});
}

/// Creates a named volume (`POST /volumes/create`).
pub fn createVolume(client: *const http.Client, logger: *log.Logger, name: []const u8, writer: anytype) !void {
    try validateVolumeName(name);

    const path = api_prefix ++ "/volumes/create";
    const req_body = try std.json.Stringify.valueAlloc(client.allocator, VolumeCreateRequest{ .Name = name }, .{});
    defer client.allocator.free(req_body);

    logger.debug("POST {s} (volume={s}, body_len={d})", .{ path, name, req_body.len });
    const resp = try client.request("POST", path, req_body);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    const parsed = try std.json.parseFromSlice(VolumeInfo, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const created_name = if (parsed.value.Name.len > 0) parsed.value.Name else name;
    try writer.print("{s}\n", .{created_name});
    logger.info("created volume {s}", .{created_name});
}

/// Removes a named volume (`DELETE /volumes/{name}?force={true|false}`).
pub fn removeVolume(client: *const http.Client, logger: *log.Logger, name: []const u8, force: bool) !void {
    try validateVolumeName(name);

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/volumes/{s}?force={s}",
        .{ api_prefix, name, if (force) "true" else "false" },
    );
    defer client.allocator.free(path);

    logger.debug("DELETE {s}", .{path});
    const resp = try client.request("DELETE", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "DELETE", path, resp);
    }
    logger.info("removed volume {s}", .{name});
}

/// Inspects a named volume (`GET /volumes/{name}`).
pub fn inspectVolume(client: *const http.Client, logger: *log.Logger, name: []const u8, writer: anytype) !void {
    try validateVolumeName(name);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/volumes/{s}", .{ api_prefix, name });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(VolumeInfo, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const v = parsed.value;
    try writer.print("{s:<15}{s}\n", .{ "Name:", v.Name });
    try writer.print("{s:<15}{s}\n", .{ "Driver:", v.Driver });
    if (v.Mountpoint.len > 0) try writer.print("{s:<15}{s}\n", .{ "Mountpoint:", v.Mountpoint });
    if (v.CreatedAt.len > 0) try writer.print("{s:<15}{s}\n", .{ "CreatedAt:", v.CreatedAt });
    logger.info("inspected volume {s}", .{name});
}

/// Lists container networks (`GET /networks`).
pub fn listNetworks(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const path = api_prefix ++ "/networks";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice([]NetworkInfo, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try writer.print("{s:<14} {s:<20} {s:<14} {s}\n", .{ "NETWORK ID", "NAME", "DRIVER", "SCOPE" });
    for (parsed.value) |net| {
        try writer.print("{s:<14} {s:<20} {s:<14} {s}\n", .{
            utils.shortId(net.Id),
            net.Name,
            net.Driver,
            net.Scope,
        });
    }
    logger.info("listed {d} network(s)", .{parsed.value.len});
}

/// Inspects a container network (`GET /networks/{name}`).
pub fn inspectNetwork(client: *const http.Client, logger: *log.Logger, name: []const u8, writer: anytype) !void {
    try validateIdentifier(name);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/networks/{s}", .{ api_prefix, name });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(NetworkInfo, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const net = parsed.value;
    if (net.Id.len > 0) try writer.print("{s:<15}{s}\n", .{ "Id:", net.Id });
    try writer.print("{s:<15}{s}\n", .{ "Name:", net.Name });
    if (net.Driver.len > 0) try writer.print("{s:<15}{s}\n", .{ "Driver:", net.Driver });
    if (net.Scope.len > 0) try writer.print("{s:<15}{s}\n", .{ "Scope:", net.Scope });
    try writer.print("{s:<15}{s}\n", .{ "Internal:", if (net.Internal) "true" else "false" });
    logger.info("inspected network {s}", .{name});
}

/// Creates a container network (`POST /networks/create`).
pub fn createNetwork(
    client: *const http.Client,
    logger: *log.Logger,
    name: []const u8,
    driver: []const u8,
    internal: bool,
    writer: anytype,
) !void {
    try validateIdentifier(name);
    try validateNetworkDriver(driver);

    const path = api_prefix ++ "/networks/create";
    const req_body = try std.json.Stringify.valueAlloc(client.allocator, NetworkCreateRequest{
        .Name = name,
        .Driver = driver,
        .Internal = internal,
    }, .{});
    defer client.allocator.free(req_body);

    logger.debug("POST {s} (network={s}, body_len={d})", .{ path, name, req_body.len });
    const resp = try client.request("POST", path, req_body);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    const parsed = try std.json.parseFromSlice(NetworkCreateResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.Warning.len > 0) {
        logger.warn("network create warning: {s}", .{parsed.value.Warning});
    }

    const out_id = if (parsed.value.Id.len > 0) parsed.value.Id else name;
    try writer.print("{s}\n", .{out_id});
    logger.info("created network {s} (id={s}, driver={s}, internal={any})", .{
        name, out_id, driver, internal,
    });
}

/// Removes a container network (`DELETE /networks/{name}[?force=true]`).
pub fn removeNetwork(client: *const http.Client, logger: *log.Logger, name: []const u8, force: bool) !void {
    try validateIdentifier(name);

    const path = if (force)
        try std.fmt.allocPrint(client.allocator, "{s}/networks/{s}?force=true", .{ api_prefix, name })
    else
        try std.fmt.allocPrint(client.allocator, "{s}/networks/{s}", .{ api_prefix, name });
    defer client.allocator.free(path);

    logger.debug("DELETE {s}", .{path});
    const resp = try client.request("DELETE", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "DELETE", path, resp);
    }
    logger.info("removed network {s}", .{name});
}

/// Pings the Podman/Docker daemon (`GET /_ping`).
pub fn systemPing(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const path = api_prefix ++ "/_ping";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const body = std.mem.trim(u8, resp.body, " \t\r\n");
    try writer.print("{s}\n", .{if (body.len > 0) body else "OK"});
    logger.info("system ping succeeded", .{});
}

/// Displays disk usage summary for images, containers, and local volumes (`GET /system/df`).
pub fn systemDf(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const path = api_prefix ++ "/system/df";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(SystemDfResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const df = parsed.value;
    const imgs = df.Images orelse &[_]ImageSummary{};
    var img_bytes: i64 = if (df.LayersSize > 0) df.LayersSize else 0;
    if (img_bytes == 0) {
        for (imgs) |img| {
            if (img.Size > 0) img_bytes +|= img.Size;
        }
    }

    const ctrs = df.Containers orelse &[_]SystemDfResponse.DfContainer{};
    var active_ctrs: usize = 0;
    var ctr_bytes: i64 = 0;
    for (ctrs) |c| {
        if (std.mem.eql(u8, c.State, "running")) active_ctrs += 1;
        if (c.SizeRw > 0) ctr_bytes +|= c.SizeRw;
    }

    const vols = df.Volumes orelse &[_]SystemDfResponse.DfVolume{};
    var active_vols: usize = 0;
    var vol_bytes: i64 = 0;
    for (vols) |v| {
        if (v.UsageData) |u| {
            if (u.RefCount > 0) active_vols += 1;
            if (u.Size > 0) vol_bytes +|= u.Size;
        }
    }

    var img_buf: [32]u8 = undefined;
    var ctr_buf: [32]u8 = undefined;
    var vol_buf: [32]u8 = undefined;

    try writer.print("{s:<18} {s:<10} {s:<10} {s}\n", .{ "TYPE", "TOTAL", "ACTIVE", "SIZE" });
    try writer.print("{s:<18} {d:<10} {d:<10} {s}\n", .{
        "Images",
        imgs.len,
        imgs.len,
        utils.formatSize(&img_buf, img_bytes),
    });
    try writer.print("{s:<18} {d:<10} {d:<10} {s}\n", .{
        "Containers",
        ctrs.len,
        active_ctrs,
        utils.formatSize(&ctr_buf, ctr_bytes),
    });
    try writer.print("{s:<18} {d:<10} {d:<10} {s}\n", .{
        "Local Volumes",
        vols.len,
        active_vols,
        utils.formatSize(&vol_buf, vol_bytes),
    });
    logger.info("fetched system disk usage (images={d}, containers={d}, volumes={d})", .{
        imgs.len, ctrs.len, vols.len,
    });
}

/// Prunes stopped containers (`POST /containers/prune`) and dangling images (`POST /images/prune`).
pub fn systemPrune(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const c_path = api_prefix ++ "/containers/prune";
    logger.debug("POST {s}", .{c_path});
    const c_resp = try client.request("POST", c_path, null);
    defer c_resp.deinit();
    if (!c_resp.ok()) return logApiFailure(logger, "POST", c_path, c_resp);

    const c_parsed = try std.json.parseFromSlice(ContainerPruneResponse, client.allocator, c_resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer c_parsed.deinit();

    const i_path = api_prefix ++ "/images/prune";
    logger.debug("POST {s}", .{i_path});
    const i_resp = try client.request("POST", i_path, null);
    defer i_resp.deinit();
    if (!i_resp.ok()) return logApiFailure(logger, "POST", i_path, i_resp);

    const i_parsed = try std.json.parseFromSlice(ImagePruneResponse, client.allocator, i_resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer i_parsed.deinit();

    var deleted_ctrs: usize = 0;
    if (c_parsed.value.ContainersDeleted) |ids| {
        deleted_ctrs = ids.len;
        if (ids.len > 0) {
            try writer.writeAll("Deleted Containers:\n");
            for (ids) |id| {
                try writer.print("  {s}\n", .{utils.shortId(id)});
            }
        }
    }

    var deleted_imgs: usize = 0;
    if (i_parsed.value.ImagesDeleted) |items| {
        deleted_imgs = items.len;
    }

    const reclaimed = c_parsed.value.SpaceReclaimed +| i_parsed.value.SpaceReclaimed;
    var size_buf: [32]u8 = undefined;
    try writer.print("Total reclaimed space: {s}\n", .{formatSizeU64(&size_buf, reclaimed)});
    logger.info("pruned {d} container(s) and {d} image(s) (reclaimed={d} bytes)", .{
        deleted_ctrs, deleted_imgs, reclaimed,
    });
}

pub const PruneTarget = enum { container, image, volume, network };

/// Prunes one resource class (`POST /{containers,images,volumes,networks}/prune`)
/// and prints what was removed plus reclaimed space.
pub fn pruneResource(client: *const http.Client, logger: *log.Logger, target: PruneTarget, writer: anytype) !void {
    const path = switch (target) {
        .container => api_prefix ++ "/containers/prune",
        .image => api_prefix ++ "/images/prune",
        .volume => api_prefix ++ "/volumes/prune",
        .network => api_prefix ++ "/networks/prune",
    };
    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    var count: usize = 0;
    var reclaimed: u64 = 0;
    switch (target) {
        .container => {
            const p = try std.json.parseFromSlice(ContainerPruneResponse, client.allocator, resp.body, .{ .ignore_unknown_fields = true });
            defer p.deinit();
            reclaimed = p.value.SpaceReclaimed;
            if (p.value.ContainersDeleted) |ids| {
                count = ids.len;
                if (ids.len > 0) try writer.writeAll("Deleted Containers:\n");
                for (ids) |id| try writer.print("  {s}\n", .{utils.shortId(id)});
            }
        },
        .image => {
            const p = try std.json.parseFromSlice(ImagePruneResponse, client.allocator, resp.body, .{ .ignore_unknown_fields = true });
            defer p.deinit();
            reclaimed = p.value.SpaceReclaimed;
            if (p.value.ImagesDeleted) |items| {
                count = items.len;
                if (items.len > 0) try writer.writeAll("Deleted Images:\n");
                for (items) |it| {
                    if (it.Deleted orelse it.Untagged) |ref| try writer.print("  {s}\n", .{ref});
                }
            }
        },
        .volume => {
            const p = try std.json.parseFromSlice(types.VolumePruneResponse, client.allocator, resp.body, .{ .ignore_unknown_fields = true });
            defer p.deinit();
            reclaimed = p.value.SpaceReclaimed;
            if (p.value.VolumesDeleted) |names| {
                count = names.len;
                if (names.len > 0) try writer.writeAll("Deleted Volumes:\n");
                for (names) |n| try writer.print("  {s}\n", .{n});
            }
        },
        .network => {
            const p = try std.json.parseFromSlice(types.NetworkPruneResponse, client.allocator, resp.body, .{ .ignore_unknown_fields = true });
            defer p.deinit();
            if (p.value.NetworksDeleted) |names| {
                count = names.len;
                if (names.len > 0) try writer.writeAll("Deleted Networks:\n");
                for (names) |n| try writer.print("  {s}\n", .{n});
            }
        },
    }

    if (target != .network) {
        var size_buf: [32]u8 = undefined;
        try writer.print("Total reclaimed space: {s}\n", .{formatSizeU64(&size_buf, reclaimed)});
    }
    logger.info("pruned {d} {s}(s) (reclaimed={d} bytes)", .{ count, @tagName(target), reclaimed });
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

/// Inspects a container or image and outputs the validated JSON document (`zigpod inspect --json`).
pub fn inspectJson(client: *const http.Client, logger: *log.Logger, target: []const u8, writer: anytype) !void {
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
        const trimmed = std.mem.trim(u8, cresp.body, " \t\r\n");
        try writer.print("{s}\n", .{trimmed});
        logger.info("inspected container {s} as JSON", .{target});
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
    const trimmed = std.mem.trim(u8, iresp.body, " \t\r\n");
    try writer.print("{s}\n", .{trimmed});
    logger.info("inspected image {s} as JSON", .{target});
}

/// Inspects a container (falling back to an image) and renders `format`, a
/// subset of Go templates: literal text plus `{{.A.B}}` and `{{json .A.B}}`.
pub fn inspectFormat(client: *const http.Client, logger: *log.Logger, target: []const u8, format: []const u8, writer: anytype) !void {
    try validateResourceRef(target);
    // Reject a malformed template before any socket traffic.
    try validateFormat(format);

    const cpath = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/json", .{ api_prefix, target });
    defer client.allocator.free(cpath);

    logger.debug("GET {s}", .{cpath});
    const cresp = try client.request("GET", cpath, null);
    defer cresp.deinit();
    if (cresp.ok()) {
        try renderFormatBody(client.allocator, format, cresp.body, writer);
        logger.info("inspected container {s} with format", .{target});
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
    try renderFormatBody(client.allocator, format, iresp.body, writer);
    logger.info("inspected image {s} with format", .{target});
}

fn renderFormatBody(allocator: std.mem.Allocator, format: []const u8, body: []const u8, writer: anytype) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return http.Error.InvalidResponse,
    };
    defer parsed.deinit();
    try renderFormat(allocator, format, parsed.value, writer);
    try writer.writeByte('\n');
}

const FormatAction = struct {
    as_json: bool,
    /// Dotted path without the leading dot; empty means the whole document.
    path: []const u8,
};

/// Parses the text between `{{` and `}}`. Only `.A.B` and `json .A.B` are
/// supported; anything else (pipes, `range`, `index`, ...) fails closed.
fn parseFormatAction(raw: []const u8) ApiError!FormatAction {
    var text = std.mem.trim(u8, raw, " \t");
    var as_json = false;
    if (std.mem.startsWith(u8, text, "json ") or std.mem.startsWith(u8, text, "json\t")) {
        as_json = true;
        text = std.mem.trim(u8, text[4..], " \t");
    }
    if (text.len == 0 or text[0] != '.') return ApiError.InvalidFormat;
    const path = text[1..];
    if (path.len > 0) {
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            if (seg.len == 0) return ApiError.InvalidFormat;
            for (seg) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') return ApiError.InvalidFormat;
            }
        }
    }
    return .{ .as_json = as_json, .path = path };
}

fn validateFormat(format: []const u8) ApiError!void {
    if (format.len == 0 or format.len > 1024) return ApiError.InvalidFormat;
    var rest = format;
    while (std.mem.indexOf(u8, rest, "{{")) |open| {
        const after = rest[open + 2 ..];
        const close = std.mem.indexOf(u8, after, "}}") orelse return ApiError.InvalidFormat;
        _ = try parseFormatAction(after[0..close]);
        rest = after[close + 2 ..];
    }
    if (std.mem.indexOf(u8, rest, "}}") != null) return ApiError.InvalidFormat;
}

fn lookupPath(root: std.json.Value, path: []const u8) ?std.json.Value {
    var cur = root;
    if (path.len == 0) return cur;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        switch (cur) {
            .object => |obj| cur = obj.get(seg) orelse return null,
            else => return null,
        }
    }
    return cur;
}

fn renderFormat(allocator: std.mem.Allocator, format: []const u8, root: std.json.Value, writer: anytype) !void {
    try validateFormat(format);
    var rest = format;
    while (std.mem.indexOf(u8, rest, "{{")) |open| {
        try writer.writeAll(rest[0..open]);
        const after = rest[open + 2 ..];
        const close = std.mem.indexOf(u8, after, "}}") orelse return ApiError.InvalidFormat;
        const action = try parseFormatAction(after[0..close]);
        rest = after[close + 2 ..];

        const value = lookupPath(root, action.path) orelse {
            try writer.writeAll("<no value>");
            continue;
        };
        const scalar_text: ?[]const u8 = if (action.as_json) null else switch (value) {
            .string => |s| s,
            .number_string => |s| s,
            .null => "<nil>",
            else => null,
        };
        if (scalar_text) |t| {
            try writer.writeAll(t);
        } else {
            // Numbers, booleans, objects and arrays are rendered as JSON.
            const out = try std.json.Stringify.valueAlloc(allocator, value, .{});
            defer allocator.free(out);
            try writer.writeAll(out);
        }
    }
    try writer.writeAll(rest);
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

fn resolveInspectIp(ns: ?ContainerInspect.ContainerInspectNetworkSettings) []const u8 {
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
    if (c.Name.len > 0) try writer.print("{s:<15}{s}\n", .{ "Name:", std.mem.trimStart(u8, c.Name, "/") });
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

fn portMatchesFilter(key: []const u8, filter: []const u8) bool {
    if (std.mem.eql(u8, key, filter)) return true;
    if (std.mem.indexOfScalar(u8, filter, '/') == null) {
        if (std.mem.indexOfScalar(u8, key, '/')) |slash| {
            return std.mem.eql(u8, key[0..slash], filter);
        }
    }
    return false;
}

/// Lists published port mappings for a container (`GET /containers/{id}/json`).
pub fn portContainer(
    client: *const http.Client,
    logger: *log.Logger,
    id: []const u8,
    filter_port: ?[]const u8,
    writer: anytype,
) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/json", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(ContainerInspect, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const ns = parsed.value.NetworkSettings orelse return;
    const ports_val = ns.Ports orelse return;
    if (ports_val != .object) return;

    var it = ports_val.object.iterator();
    var count: usize = 0;
    while (it.next()) |entry| {
        const cport = entry.key_ptr.*;
        if (filter_port) |fp| {
            if (!portMatchesFilter(cport, fp)) continue;
        }
        if (entry.value_ptr.* != .array) continue;
        for (entry.value_ptr.array.items) |binding| {
            if (binding != .object) continue;
            const hip = if (binding.object.get("HostIp")) |v_ip|
                (if (v_ip == .string and v_ip.string.len > 0) v_ip.string else "0.0.0.0")
            else
                "0.0.0.0";
            const hport = if (binding.object.get("HostPort")) |v_hp|
                (if (v_hp == .string) v_hp.string else "")
            else
                "";
            if (hport.len > 0) {
                try writer.print("{s} -> {s}:{s}\n", .{ cport, hip, hport });
                count += 1;
            }
        }
    }
    logger.info("listed {d} port mapping(s) for {s}", .{ count, utils.shortId(id) });
}

/// Shows filesystem changes in a container (`GET /containers/{id}/changes`).
pub fn diffContainer(client: *const http.Client, logger: *log.Logger, id: []const u8, writer: anytype) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/changes", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const trimmed = std.mem.trim(u8, resp.body, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return;

    const parsed = try std.json.parseFromSlice([]ContainerDiffItem, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    for (parsed.value) |item| {
        const kind_ch: u8 = switch (item.Kind) {
            1 => 'A',
            2 => 'D',
            else => 'C',
        };
        try writer.print("{c} {s}\n", .{ kind_ch, item.Path });
    }
    logger.info("listed {d} filesystem change(s) for {s}", .{ parsed.value.len, utils.shortId(id) });
}

fn EventsStreamCtx(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: WriterType,
        json_mode: bool,
        line_buf: std.ArrayList(u8) = .empty,
        count: usize = 0,

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
            const parsed = std.json.parseFromSlice(DaemonEvent, self.allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();

            if (self.json_mode) {
                try self.writer.print("{s}\n", .{line});
            } else {
                const ev = parsed.value;
                const action = if (ev.Action.len > 0) ev.Action else ev.status;
                const actor_id = if (ev.Actor) |a| (if (a.ID.len > 0) a.ID else ev.id) else ev.id;
                try self.writer.print("{d} {s} {s} {s}\n", .{
                    ev.time,
                    if (ev.Type.len > 0) ev.Type else "daemon",
                    action,
                    utils.shortId(actor_id),
                });
            }
            self.count += 1;
        }
    };
}

/// Streams or queries daemon events (`GET /events` with optional `since`/`until`).
pub fn fetchEvents(
    client: *const http.Client,
    logger: *log.Logger,
    since: ?[]const u8,
    until: ?[]const u8,
    json_mode: bool,
    writer: anytype,
) !void {
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(client.allocator);
    try path_buf.appendSlice(client.allocator, api_prefix ++ "/events");

    var has_q = false;
    if (since) |s| {
        try path_buf.appendSlice(client.allocator, "?since=");
        try appendQueryEncoded(client.allocator, &path_buf, s);
        has_q = true;
    }
    if (until) |u| {
        try path_buf.appendSlice(client.allocator, if (has_q) "&until=" else "?until=");
        try appendQueryEncoded(client.allocator, &path_buf, u);
    }

    logger.debug("STREAM GET {s}", .{path_buf.items});
    const WriterType = @TypeOf(writer);
    var ctx = EventsStreamCtx(WriterType){
        .allocator = client.allocator,
        .writer = writer,
        .json_mode = json_mode,
    };
    defer ctx.deinit();

    const resp = try client.streamRequest(
        "GET",
        path_buf.items,
        null,
        http.blocking_timeout_ms,
        &ctx,
        EventsStreamCtx(WriterType).onChunk,
    );
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "GET", path_buf.items, err_resp);
    }
    try ctx.flush();
    logger.info("received {d} daemon event(s)", .{ctx.count});
}

// ---------------------------------------------------------------- tests

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

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try printContainerInspect(&out.writer, parsed.value);

    const s = out.written();
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
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer std.testing.allocator.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

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
    try inspect(&client, &logger, "alpine:3.20", &out.writer);

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 2), ctx.matched);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sha256:deadbeef") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "alpine:3.20") != null);
}

test "renderFormat supports field paths and json, rejects other template syntax" {
    const alloc = std.testing.allocator;
    const doc =
        \\{"Id":"abc123","State":{"Status":"running","Running":true,"ExitCode":0,"Error":null},
        \\ "Config":{"Env":["A=1","B=2"],"Labels":{"app":"web"}},"Size":7700000}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, doc, .{});
    defer parsed.deinit();

    const cases = [_]struct { fmt: []const u8, want: []const u8 }{
        .{ .fmt = "{{.State.Status}}", .want = "running" },
        .{ .fmt = "id={{ .Id }} run={{.State.Running}} code={{.State.ExitCode}}", .want = "id=abc123 run=true code=0" },
        .{ .fmt = "{{.State.Error}}", .want = "<nil>" },
        .{ .fmt = "{{.Missing.Field}}", .want = "<no value>" },
        .{ .fmt = "{{.Id.Sub}}", .want = "<no value>" },
        .{ .fmt = "{{json .Config.Env}}", .want = "[\"A=1\",\"B=2\"]" },
        .{ .fmt = "{{json .Id}}", .want = "\"abc123\"" },
        .{ .fmt = "{{.Config.Labels}}", .want = "{\"app\":\"web\"}" },
        .{ .fmt = "{{.Size}}", .want = "7700000" },
        .{ .fmt = "plain text", .want = "plain text" },
    };
    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try renderFormat(alloc, c.fmt, parsed.value, &out.writer);
        try std.testing.expectEqualStrings(c.want, out.written());
    }

    const bad = [_][]const u8{
        "", "{{.Id", "{{.Id}} }}", "{{Id}}", "{{range .Config.Env}}", "{{.Id | upper}}",
        "{{index .Config.Env 0}}", "{{..Id}}", "{{.Id.}}", "{{.a-b}}", "{{json}}", "{{}}",
    };
    for (bad) |f| {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.testing.expectError(ApiError.InvalidFormat, renderFormat(alloc, f, parsed.value, &out.writer));
        try std.testing.expectEqualStrings("", out.written());
    }
    const too_long: [1025]u8 = @splat('x');
    try std.testing.expectError(ApiError.InvalidFormat, validateFormat(&too_long));
}

test "inspectFormat renders container then falls back to image" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-inspfmt-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const c_json = "{\"Id\":\"c1\",\"State\":{\"Status\":\"exited\",\"ExitCode\":3}}";
    const i_json = "{\"Id\":\"sha256:deadbeef\",\"Os\":\"linux\"}";
    const nf = "{\"message\":\"no such\"}";
    const hdr = "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}";
    const nf_resp = std.fmt.comptimePrint("HTTP/1.1 404 Not Found\r\nContent-Length: {d}\r\n\r\n{s}", .{ nf.len, nf });
    const replies = [_]ScriptedReply{
        .{ .expected_prefix = "GET /v1.40/containers/web/json HTTP/1.1\r\n", .raw_response = std.fmt.comptimePrint(hdr, .{ c_json.len, c_json }) },
        .{ .expected_prefix = "GET /v1.40/containers/alpine:3.20/json HTTP/1.1\r\n", .raw_response = nf_resp },
        .{ .expected_prefix = "GET /v1.40/images/alpine:3.20/json HTTP/1.1\r\n", .raw_response = std.fmt.comptimePrint(hdr, .{ i_json.len, i_json }) },
        .{ .expected_prefix = "GET /v1.40/containers/gone/json HTTP/1.1\r\n", .raw_response = nf_resp },
        .{ .expected_prefix = "GET /v1.40/images/gone/json HTTP/1.1\r\n", .raw_response = nf_resp },
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

    // Bad template / target are rejected before any request is sent.
    try std.testing.expectError(ApiError.InvalidFormat, inspectFormat(&client, &logger, "web", "{{range .X}}", &out.writer));
    try std.testing.expect(std.meta.isError(inspectFormat(&client, &logger, "a?b", "{{.Id}}", &out.writer)));

    try inspectFormat(&client, &logger, "web", "{{.State.Status}}:{{.State.ExitCode}}", &out.writer);
    try inspectFormat(&client, &logger, "alpine:3.20", "{{.Os}}", &out.writer);
    try std.testing.expectEqualStrings("exited:3\nlinux\n", out.written());
    try std.testing.expectError(ApiError.NotFound, inspectFormat(&client, &logger, "gone", "{{.Id}}", &out.writer));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "pruneResource handles each resource class" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-prune-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const c_json = "{\"ContainersDeleted\":[\"deadbeef12345678\"],\"SpaceReclaimed\":2048}";
    const i_json = "{\"ImagesDeleted\":[{\"Deleted\":\"sha256:2222\"}],\"SpaceReclaimed\":0}";
    const v_json = "{\"VolumesDeleted\":[\"data1\"],\"SpaceReclaimed\":4096}";
    const n_json = "{\"NetworksDeleted\":[\"net1\",\"net2\"]}";
    const hdr = "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}";
    const replies = [_]ScriptedReply{
        .{ .expected_prefix = "POST /v1.40/containers/prune HTTP/1.1\r\n", .raw_response = std.fmt.comptimePrint(hdr, .{ c_json.len, c_json }) },
        .{ .expected_prefix = "POST /v1.40/images/prune HTTP/1.1\r\n", .raw_response = std.fmt.comptimePrint(hdr, .{ i_json.len, i_json }) },
        .{ .expected_prefix = "POST /v1.40/volumes/prune HTTP/1.1\r\n", .raw_response = std.fmt.comptimePrint(hdr, .{ v_json.len, v_json }) },
        .{ .expected_prefix = "POST /v1.40/networks/prune HTTP/1.1\r\n", .raw_response = std.fmt.comptimePrint(hdr, .{ n_json.len, n_json }) },
        .{ .expected_prefix = "POST /v1.40/volumes/prune HTTP/1.1\r\n", .raw_response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 17\r\n\r\n{\"message\":\"bad\"}" },
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

    try pruneResource(&client, &logger, .container, &out.writer);
    try pruneResource(&client, &logger, .image, &out.writer);
    try pruneResource(&client, &logger, .volume, &out.writer);
    try pruneResource(&client, &logger, .network, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Deleted Containers:\n  deadbeef1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  sha256:2222\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Deleted Volumes:\n  data1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Deleted Networks:\n  net1\n  net2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Total reclaimed space: ") != null);

    try std.testing.expect(std.meta.isError(pruneResource(&client, &logger, .volume, &out.writer)));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "systemPing, systemDf, and systemPrune endpoints" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-system-api-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const df_json =
        "{\"LayersSize\":8388608," ++
        "\"Images\":[{\"Id\":\"sha256:1111\",\"Size\":8388608}]," ++
        "\"Containers\":[{\"Id\":\"c1\",\"State\":\"running\",\"SizeRw\":4096}]," ++
        "\"Volumes\":[{\"Name\":\"v1\",\"UsageData\":{\"Size\":67108864,\"RefCount\":1}}]}";
    const c_prune_json = "{\"ContainersDeleted\":[\"deadbeef12345678\"],\"SpaceReclaimed\":1048576}";
    const i_prune_json = "{\"ImagesDeleted\":[{\"Deleted\":\"sha256:2222\"}],\"SpaceReclaimed\":3145728}";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/_ping HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
        },
        .{
            .expected_prefix = "GET /v1.40/system/df HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ df_json.len, df_json }),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/prune HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ c_prune_json.len, c_prune_json }),
        },
        .{
            .expected_prefix = "POST /v1.40/images/prune HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ i_prune_json.len, i_prune_json }),
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

    try systemPing(&client, &logger, &out.writer);
    try std.testing.expectEqualStrings("OK\n", out.written());

    out.clearRetainingCapacity();
    try systemDf(&client, &logger, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Images") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "8.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "64.0 MB") != null);

    out.clearRetainingCapacity();
    try systemPrune(&client, &logger, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "deadbeef1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Total reclaimed space: 4.0 MB") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "portContainer, diffContainer, and fetchEvents endpoints + validation" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-observe-api-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const insp_json =
        "{\"Id\":\"web1234567890\",\"NetworkSettings\":{\"Ports\":{\"80/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"8080\"}],\"443/tcp\":[{\"HostIp\":\"0.0.0.0\",\"HostPort\":\"8443\"}]}}}";
    const diff_json = "[{\"Path\":\"/etc/hosts\",\"Kind\":0},{\"Path\":\"/tmp/new\",\"Kind\":1},{\"Path\":\"/tmp/old\",\"Kind\":2}]";
    const ev_json = "{\"Type\":\"container\",\"Action\":\"start\",\"time\":1700000000,\"Actor\":{\"ID\":\"web1234567890abcd\"}}\n";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/containers/web/json HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ insp_json.len, insp_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/changes HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ diff_json.len, diff_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/events?since=10&until=20 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ ev_json.len, ev_json }),
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

    try std.testing.expectError(ApiError.InvalidIdentifier, portContainer(&client, &logger, "../bad", null, &out.writer));
    try std.testing.expectError(ApiError.InvalidIdentifier, diffContainer(&client, &logger, "../bad", &out.writer));

    try portContainer(&client, &logger, "web", "80", &out.writer);
    try std.testing.expectEqualStrings("80/tcp -> 127.0.0.1:8080\n", out.written());

    out.clearRetainingCapacity();
    try diffContainer(&client, &logger, "web", &out.writer);
    try std.testing.expectEqualStrings("C /etc/hosts\nA /tmp/new\nD /tmp/old\n", out.written());

    out.clearRetainingCapacity();
    try fetchEvents(&client, &logger, "10", "20", false, &out.writer);
    try std.testing.expectEqualStrings("1700000000 container start web123456789\n", out.written());

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "portContainer, diffContainer, and fetchEvents edge, json, and error paths" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-observe-edge-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const insp_json =
        "{\"Id\":\"web1234567890\",\"NetworkSettings\":{\"Ports\":{\"80/tcp\":[{\"HostIp\":\"\",\"HostPort\":\"8080\"}]}}}";
    const ev_stream =
        "not-json-line\n" ++
        "{\"Type\":\"container\",\"Action\":\"die\",\"time\":1700000001,\"Actor\":{\"ID\":\"web1234567890abcd\"}}\n";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/containers/web/json HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ insp_json.len, insp_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/changes HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nnull",
        },
        .{
            .expected_prefix = "GET /v1.40/containers/missing/changes HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found",
        },
        .{
            .expected_prefix = "GET /v1.40/events HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ ev_stream.len, ev_stream }),
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

    // filter_port == null should list all ports and default empty HostIp to 0.0.0.0
    try portContainer(&client, &logger, "web", null, &out.writer);
    try std.testing.expectEqualStrings("80/tcp -> 0.0.0.0:8080\n", out.written());

    // null changes response should succeed with empty output
    out.clearRetainingCapacity();
    try diffContainer(&client, &logger, "web", &out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    // 404 from daemon should return PodmanApiError
    try std.testing.expectError(ApiError.PodmanApiError, diffContainer(&client, &logger, "missing", &out.writer));

    // json_mode skips malformed lines and emits valid JSON lines
    out.clearRetainingCapacity();
    try fetchEvents(&client, &logger, null, null, true, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"Action\":\"die\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "not-json-line") == null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "createNetwork and removeNetwork validate inputs and call API endpoints" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-net-crud-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const created_json = "{\"Id\":\"net1234567890\",\"Warning\":\"\"}";
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/networks/create HTTP/1.1\r\n",
            .expected_substring = "\"Internal\":true",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}", .{ created_json.len, created_json }),
        },
        .{
            .expected_prefix = "DELETE /v1.40/networks/iso-net?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "DELETE /v1.40/networks/iso-net HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found",
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

    try std.testing.expectError(ApiError.InvalidIdentifier, createNetwork(&client, &logger, "../bad", "bridge", false, &out.writer));
    try std.testing.expectError(ApiError.InvalidNetworkDriver, createNetwork(&client, &logger, "iso-net", "bogus", false, &out.writer));
    try std.testing.expectError(ApiError.InvalidIdentifier, removeNetwork(&client, &logger, "../bad", false));

    try createNetwork(&client, &logger, "iso-net", "bridge", true, &out.writer);
    try std.testing.expectEqualStrings("net1234567890\n", out.written());

    try removeNetwork(&client, &logger, "iso-net", true);
    try std.testing.expectError(ApiError.PodmanApiError, removeNetwork(&client, &logger, "iso-net", false));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}
