//! Podman / Docker-compatible REST API (v1.40) client functions.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");

pub const api_prefix = "/v1.40";

pub const ApiError = error{
    PodmanApiError,
    InvalidIdentifier,
};

pub const HostConfig = struct {
    AutoRemove: bool = false,
    ReadonlyRootfs: bool = false,
    Memory: ?i64 = null,
    PidsLimit: ?i64 = null,
    SecurityOpt: ?[]const []const u8 = null,
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

test "demuxLogs handles multiplexed docker stream frames and zero-length frame" {
    const frame = [_]u8{
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

fn readHttpRequest(stream: std.net.Stream, buf: []u8) ![]const u8 {
    var total: usize = 0;
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
