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
    createPod(&client, &logger, "../evil", sink.writer()) catch |e| { e1 = e == ApiError.InvalidIdentifier; };
    try std.testing.expect(e1);
    var e2 = false;
    createPod(&client, &logger, "pod?name", sink.writer()) catch |e| { e2 = e == ApiError.InvalidIdentifier; };
    try std.testing.expect(e2);
    var e3 = false;
    stopPod(&client, &logger, "a/../b", sink.writer()) catch |e| { e3 = e == ApiError.InvalidIdentifier; };
    try std.testing.expect(e3);
    var e4 = false;
    rmPod(&client, &logger, "", false, sink.writer()) catch |e| { e4 = e == ApiError.InvalidIdentifier; };
    try std.testing.expect(e4);
}
