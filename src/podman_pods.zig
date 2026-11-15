//! Pod management endpoints (Podman libpod pods API).
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const validate = @import("podman_validate.zig");
const th = @import("podman_test_helpers.zig");

const api_prefix = validate.api_prefix;
const api_libpod_prefix = "/v1.40/libpod";
const validateIdentifier = validate.validateIdentifier;
const logApiFailure = validate.logApiFailure;

const ApiError = types.ApiError;
const PodCreateRequest = types.PodCreateRequest;
const PodSummary = types.PodSummary;

const MockApiCtx = th.MockApiCtx;
const ScriptedReply = th.ScriptedReply;
const runMockPodmanServer = th.runMockPodmanServer;

/// Creates a pod (`POST /libpod/pods/create`) and prints the new pod ID.
pub fn createPod(client: *const http.Client, logger: *log.Logger, name: []const u8, writer: anytype) !void {
    try validateIdentifier(name);

    const path = api_libpod_prefix ++ "/pods/create";
    const req_body = try std.json.stringifyAlloc(client.allocator, PodCreateRequest{ .name = name }, .{});
    defer client.allocator.free(req_body);

    logger.debug("POST {s}", .{path});
    const resp = try client.request("POST", path, req_body);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    const parsed = std.json.parseFromSlice(types.CreateResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    }) catch return ApiError.PodmanApiError;
    defer parsed.deinit();

    try writer.print("{s}\n", .{utils.shortId(parsed.value.Id)});
    logger.info("created pod {s}", .{name});
}

/// Lists pods (`GET /libpod/pods/json`).
pub fn listPods(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const path = api_libpod_prefix ++ "/pods/json";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    try writer.print("{s:<16} {s:<24} {s:<12} {s}\n", .{ "POD ID", "NAME", "STATUS", "CREATED" });

    const parsed = try std.json.parseFromSlice([]PodSummary, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    for (parsed.value) |p| {
        try writer.print("{s:<16} {s:<24} {s:<12} {s}\n", .{ utils.shortId(p.Id), p.Name, p.Status, p.Created });
    }
    logger.info("listed {d} pod(s)", .{parsed.value.len});
}

/// Stops a pod (`POST /libpod/pods/{id}/stop`).
pub fn stopPod(client: *const http.Client, logger: *log.Logger, id: []const u8, writer: anytype) !void {
    try validateIdentifier(id);

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_libpod_prefix ++ "/pods/");
    try path_buf.appendSlice(id);
    try path_buf.appendSlice("/stop");

    logger.debug("POST {s}", .{path_buf.items});
    const resp = try client.request("POST", path_buf.items, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path_buf.items, resp);
    try writer.print("{s}\n", .{utils.shortId(id)});
    logger.info("stopped pod {s}", .{id});
}

/// Removes a pod (`DELETE /libpod/pods/{id}?force=...`).
pub fn rmPod(client: *const http.Client, logger: *log.Logger, id: []const u8, force: bool, writer: anytype) !void {
    try validateIdentifier(id);

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_libpod_prefix ++ "/pods/");
    try path_buf.appendSlice(id);
    if (force) try path_buf.appendSlice("?force=true");

    logger.debug("DELETE {s}", .{path_buf.items});
    const resp = try client.request("DELETE", path_buf.items, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "DELETE", path_buf.items, resp);
    try writer.print("{s}\n", .{utils.shortId(id)});
    logger.info("removed pod {s}", .{id});
}

// ---------------------------------------------------------------- tests

test "pod endpoints reject traversal and invalid identifiers fail-closed" {
    const alloc = std.testing.allocator;
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    const client = http.Client{ .allocator = alloc, .socket_path = "/tmp/zp-pods-invalid.sock" };
    var sink = std.ArrayList(u8).init(alloc);
    defer sink.deinit();

    var e1 = false;
    createPod(&client, &logger, "../evil", sink.writer()) catch |e| {
        e1 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e1);
    var e2 = false;
    createPod(&client, &logger, "pod?name", sink.writer()) catch |e| {
        e2 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e2);
    var e3 = false;
    stopPod(&client, &logger, "a/../b", sink.writer()) catch |e| {
        e3 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e3);
    var e4 = false;
    rmPod(&client, &logger, "", false, sink.writer()) catch |e| {
        e4 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e4);
}

test "pod lifecycle over mock Unix socket prints ids and rows" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-pods-life-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const create_json = "{\"Id\":\"abcdef1234567890ff\",\"Warnings\":[]}";
    const create_resp = std.fmt.comptimePrint(
        "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ create_json.len, create_json },
    );
    const list_json =
        \\[{"Id":"abcdef1234567890","Name":"webpod","Status":"Running","Created":"1 minute ago"}]
    ;
    const list_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ list_json.len, list_json },
    );
    const ok_resp = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/libpod/pods/create HTTP/1.1\r\n",
            .expected_substring = "\"name\":\"webpod\"",
            .raw_response = create_resp,
        },
        .{
            .expected_prefix = "GET /v1.40/libpod/pods/json HTTP/1.1\r\n",
            .raw_response = list_resp,
        },
        .{
            .expected_prefix = "POST /v1.40/libpod/pods/webpod/stop HTTP/1.1\r\n",
            .raw_response = ok_resp,
        },
        .{
            .expected_prefix = "DELETE /v1.40/libpod/pods/webpod?force=true HTTP/1.1\r\n",
            .raw_response = ok_resp,
        },
        .{
            .expected_prefix = "DELETE /v1.40/libpod/pods/webpod HTTP/1.1\r\n",
            .raw_response = ok_resp,
        },
    };

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try createPod(&client, &logger, "webpod", out.writer());
    try listPods(&client, &logger, out.writer());
    try stopPod(&client, &logger, "webpod", out.writer());
    try rmPod(&client, &logger, "webpod", true, out.writer());
    try rmPod(&client, &logger, "webpod", false, out.writer());

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "abcdef123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "webpod") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Running") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "1 minute ago") != null);
}

test "pod endpoints surface daemon errors and malformed payloads fail-closed" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-pods-err-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const boom_json = "{\"message\":\"boom\"}";
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/libpod/pods/create HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ boom_json.len, boom_json },
            ),
        },
        .{
            .expected_prefix = "GET /v1.40/libpod/pods/json HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nnotjson",
        },
    };

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var sink = std.ArrayList(u8).init(alloc);
    defer sink.deinit();

    var got_api_err = false;
    createPod(&client, &logger, "webpod", sink.writer()) catch |e| {
        got_api_err = e == ApiError.PodmanApiError;
    };
    try std.testing.expect(got_api_err);

    var got_parse_err = false;
    listPods(&client, &logger, sink.writer()) catch {
        got_parse_err = true;
    };
    try std.testing.expect(got_parse_err);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
    // listPods prints the table header before parsing; malformed JSON must
    // never emit a data row.
    try std.testing.expect(std.mem.startsWith(u8, sink.items, "POD ID"));
    try std.testing.expect(std.mem.indexOf(u8, sink.items, "abcdef123456") == null);
}

test "createPod accepts 128-char identifier and rejects over-limit name" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-pods-bnd-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const create_json = "{\"Id\":\"beef0000dead1111\"}";
    const replies = [_]ScriptedReply{.{
        .expected_prefix = "POST /v1.40/libpod/pods/create HTTP/1.1\r\n",
        .raw_response = std.fmt.comptimePrint(
            "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ create_json.len, create_json },
        ),
    }};

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    const max_name = "p" ** 128;
    try createPod(&client, &logger, max_name, out.writer());

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 1), ctx.matched);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "beef0000dead") != null);

    const over_name = "p" ** 129;
    var rejected = false;
    createPod(&client, &logger, over_name, out.writer()) catch |e| {
        rejected = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(rejected);
    try std.testing.expectEqual(@as(usize, 1), ctx.matched);
}
