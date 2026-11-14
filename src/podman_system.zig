//! Volume, network, system (ping/df/prune), version, and inspect endpoints.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const v = @import("podman_validate.zig");
const th = @import("podman_test_helpers.zig");

const api_prefix = v.api_prefix;
const validateVolumeName = v.validateVolumeName;
const validateIdentifier = v.validateIdentifier;
const validateResourceRef = v.validateResourceRef;
const logApiFailure = v.logApiFailure;
const formatSizeU64 = v.formatSizeU64;

const ApiError = types.ApiError;
const VolumeCreateRequest = types.VolumeCreateRequest;
const VolumeInfo = types.VolumeInfo;
const VolumeListResponse = types.VolumeListResponse;
const NetworkInfo = types.NetworkInfo;
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

    const trimmed = std.mem.trimLeft(u8, resp.body, " \t\r\n");
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
    const req_body = try std.json.stringifyAlloc(client.allocator, VolumeCreateRequest{ .Name = name }, .{});
    defer client.allocator.free(req_body);

    logger.debug("POST {s} body={s}", .{ path, req_body });
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


test "systemPing, systemDf, and systemPrune endpoints" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-system-api-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
    };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try systemPing(&client, &logger, out.writer());
    try std.testing.expectEqualStrings("OK\n", out.items);

    out.clearRetainingCapacity();
    try systemDf(&client, &logger, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Images") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "8.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "64.0 MB") != null);

    out.clearRetainingCapacity();
    try systemPrune(&client, &logger, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "deadbeef1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Total reclaimed space: 4.0 MB") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

