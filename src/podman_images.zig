//! Podman / Docker-compatible image listing, pulling, and removal endpoints.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const validate = @import("podman_validate.zig");
const th = @import("podman_test_helpers.zig");

const api_prefix = validate.api_prefix;
const validateIdentifier = validate.validateIdentifier;
const validateResourceRef = validate.validateResourceRef;
const appendQueryEncoded = validate.appendQueryEncoded;
const logApiFailure = validate.logApiFailure;

const ApiError = types.ApiError;
const ImageSummary = types.ImageSummary;
const ImageHistoryItem = types.ImageHistoryItem;
const CommitResponse = types.CommitResponse;
const PullStatusLine = types.PullStatusLine;

const MockApiCtx = th.MockApiCtx;
const ScriptedReply = th.ScriptedReply;
const runMockPodmanServer = th.runMockPodmanServer;

pub fn removeImage(client: *const http.Client, logger: *log.Logger, image: []const u8, force: bool, writer: anytype) !void {
    try validateResourceRef(image);

    const path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/images/{s}?force={s}",
        .{ api_prefix, image, if (force) "true" else "false" },
    );
    defer client.allocator.free(path);

    logger.debug("DELETE {s}", .{path});
    const resp = try client.request("DELETE", path, null);
    defer resp.deinit();

    if (resp.status != 204 and !resp.ok()) {
        return logApiFailure(logger, "DELETE", path, resp);
    }
    try writer.print("Removed {s}\n", .{image});
    logger.info("removed image {s} (force={})", .{ image, force });
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

/// Emits validated JSON array for `zigpod images --json` (`GET /images/json`).
pub fn listImagesJson(client: *const http.Client, logger: *log.Logger, writer: anytype) !void {
    const path = api_prefix ++ "/images/json";

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice([]ImageSummary, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const json_out = try std.json.stringifyAlloc(client.allocator, parsed.value, .{});
    defer client.allocator.free(json_out);
    try writer.print("{s}\n", .{json_out});
    logger.info("listed {d} image(s) as JSON", .{parsed.value.len});
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

// ---------------------------------------------------------------- tests

fn splitRepoTag(target: []const u8) struct { repo: []const u8, tag: []const u8 } {
    const last_slash = std.mem.lastIndexOfScalar(u8, target, '/');
    const last_colon = std.mem.lastIndexOfScalar(u8, target, ':');
    if (last_colon) |c| {
        if (last_slash == null or c > last_slash.?) {
            const tag_part = target[c + 1 ..];
            if (tag_part.len > 0) return .{ .repo = target[0..c], .tag = tag_part };
        }
    }
    return .{ .repo = target, .tag = "latest" };
}

/// Tags an existing local image (`POST /images/{src}/tag?repo=...&tag=...`).
pub fn tagImage(
    client: *const http.Client,
    logger: *log.Logger,
    src_image: []const u8,
    target_image: []const u8,
) !void {
    try validateResourceRef(src_image);
    try validateResourceRef(target_image);
    const rt = splitRepoTag(target_image);

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/images/");
    try path_buf.appendSlice(src_image);
    try path_buf.appendSlice("/tag?repo=");
    try appendQueryEncoded(&path_buf, rt.repo);
    try path_buf.appendSlice("&tag=");
    try appendQueryEncoded(&path_buf, rt.tag);

    logger.debug("POST {s}", .{path_buf.items});
    const resp = try client.request("POST", path_buf.items, null);
    defer resp.deinit();
    if (resp.status != 201 and !resp.ok()) {
        return logApiFailure(logger, "POST", path_buf.items, resp);
    }
    logger.info("tagged image {s} -> {s}", .{ src_image, target_image });
}

/// Shows layer history of an image (`GET /images/{image}/history`).
pub fn imageHistory(
    client: *const http.Client,
    logger: *log.Logger,
    image: []const u8,
    json_mode: bool,
    writer: anytype,
) !void {
    try validateResourceRef(image);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/images/{s}/history", .{ api_prefix, image });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice([]ImageHistoryItem, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (json_mode) {
        const json_out = try std.json.stringifyAlloc(client.allocator, parsed.value, .{});
        defer client.allocator.free(json_out);
        try writer.print("{s}\n", .{json_out});
        logger.info("fetched JSON history for {s} ({d} layer(s))", .{ image, parsed.value.len });
        return;
    }

    try writer.print("{s:<14} {s:<12} {s}\n", .{ "IMAGE", "SIZE", "CREATED BY" });
    var size_buf: [32]u8 = undefined;
    for (parsed.value) |item| {
        const id_str = if (item.Id.len > 0) utils.shortId(item.Id) else "<missing>";
        try writer.print("{s:<14} {s:<12} {s}\n", .{
            id_str,
            utils.formatSize(&size_buf, item.Size),
            item.CreatedBy,
        });
    }
    logger.info("fetched history for {s} ({d} layer(s))", .{ image, parsed.value.len });
}

/// Creates a new image from a container's changes (`POST /commit`).
pub fn commitContainer(
    client: *const http.Client,
    logger: *log.Logger,
    container: []const u8,
    target_image: []const u8,
    message: ?[]const u8,
    author: ?[]const u8,
    writer: anytype,
) !void {
    try validateIdentifier(container);
    try validateResourceRef(target_image);
    const rt = splitRepoTag(target_image);

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/commit?container=");
    try appendQueryEncoded(&path_buf, container);
    try path_buf.appendSlice("&repo=");
    try appendQueryEncoded(&path_buf, rt.repo);
    try path_buf.appendSlice("&tag=");
    try appendQueryEncoded(&path_buf, rt.tag);
    if (message) |m| {
        try path_buf.appendSlice("&comment=");
        try appendQueryEncoded(&path_buf, m);
    }
    if (author) |a| {
        try path_buf.appendSlice("&author=");
        try appendQueryEncoded(&path_buf, a);
    }

    logger.debug("POST {s}", .{path_buf.items});
    const resp = try client.request("POST", path_buf.items, null);
    defer resp.deinit();
    if (resp.status != 201 and !resp.ok()) {
        return logApiFailure(logger, "POST", path_buf.items, resp);
    }

    const parsed = try std.json.parseFromSlice(CommitResponse, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.Id.len > 0) {
        try writer.print("{s}\n", .{parsed.value.Id});
    }
    logger.info("committed container {s} -> {s}", .{ utils.shortId(container), target_image });
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

test "tagImage, imageHistory, and commitContainer endpoints + validation" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-img-ops-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const hist_json = "[{\"Id\":\"sha256:1234567890abcdef\",\"CreatedBy\":\"/bin/sh -c echo hi\",\"Size\":4096}]";
    const commit_json = "{\"Id\":\"sha256:fedcba9876543210\"}";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/images/alpine:3.20/tag?repo=myrepo%2Fapp&tag=v1 HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n",
        },
        .{
            .expected_prefix = "GET /v1.40/images/alpine:3.20/history HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ hist_json.len, hist_json }),
        },
        .{
            .expected_prefix = "GET /v1.40/images/alpine:3.20/history HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ hist_json.len, hist_json }),
        },
        .{
            .expected_prefix = "POST /v1.40/commit?container=web&repo=snap&tag=v2&comment=save&author=alice HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}", .{ commit_json.len, commit_json }),
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

    try std.testing.expectError(ApiError.InvalidIdentifier, tagImage(&client, &logger, "bad?x=1", "snap:v1"));
    try std.testing.expectError(ApiError.InvalidIdentifier, commitContainer(&client, &logger, "../bad", "snap:v1", null, null, out.writer()));

    try tagImage(&client, &logger, "alpine:3.20", "myrepo/app:v1");

    try imageHistory(&client, &logger, "alpine:3.20", false, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "/bin/sh -c echo hi") != null);

    out.clearRetainingCapacity();
    try imageHistory(&client, &logger, "alpine:3.20", true, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"CreatedBy\":\"/bin/sh -c echo hi\"") != null);

    out.clearRetainingCapacity();
    try commitContainer(&client, &logger, "web", "snap:v2", "save", "alice", out.writer());
    try std.testing.expectEqualStrings("sha256:fedcba9876543210\n", out.items);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}
