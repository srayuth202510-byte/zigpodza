//! Podman / Docker-compatible REST API (v1.40) client functions.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");

pub const api_prefix = "/v1.40";

pub const ApiError = error{
    PodmanApiError,
};

pub const HostConfig = struct {
    AutoRemove: bool = false,
};

pub const ContainerCreateRequest = struct {
    Image: []const u8,
    Cmd: ?[]const []const u8 = null,
    Env: ?[]const []const u8 = null,
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
    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/wait", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, null);
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
    const resp = try client.request("POST", path_buf.items, null);
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
    while (pos + 8 <= raw.len) {
        const stream_type = raw[pos];
        if (stream_type > 2 or raw[pos + 1] != 0 or raw[pos + 2] != 0 or raw[pos + 3] != 0) {
            valid_frames = false;
            break;
        }
        const size = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big);
        const next_pos = pos + 8 + @as(usize, size);
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
    while (pos + 8 <= raw.len) {
        const size = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big);
        const start = pos + 8;
        const end = start + @as(usize, size);
        try writer.writeAll(raw[start..end]);
        pos = end;
    }
}

// ---------------------------------------------------------------- tests

test "demuxLogs handles multiplexed docker stream frames" {
    const frame = [_]u8{
        1, 0, 0, 0, 0, 0, 0, 6, 'h', 'e', 'l', 'l', 'o', '\n',
        2, 0, 0, 0, 0, 0, 0, 4, 'e', 'r', 'r', '\n',
    };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs(&frame, out.writer());
    try std.testing.expectEqualStrings("hello\nerr\n", out.items);
}

test "demuxLogs falls back to plain text" {
    const raw = "plain log output\nline 2\n";
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs(raw, out.writer());
    try std.testing.expectEqualStrings(raw, out.items);
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
