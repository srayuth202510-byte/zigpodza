//! Image/container transfer endpoints: search, save, load, export, import.
//!
//! All local file paths coming from the CLI pass through the same fail-closed
//! host-path policy as bind mounts (BUG-014), and long-running tar transfers
//! use the blocking timeout instead of the short default (BUG-007).
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const validate = @import("podman_validate.zig");
const types = @import("podman_types.zig");
const th = @import("podman_test_helpers.zig");

const api_prefix = validate.api_prefix;

const ApiError = types.ApiError;
const ImageSearchItem = types.ImageSearchItem;

const validateIdentifier = validate.validateIdentifier;
const validateResourceRef = validate.validateResourceRef;
const validateHostPath = validate.validateHostPath;
const appendQueryEncoded = validate.appendQueryEncoded;
const logApiFailure = validate.logApiFailure;

/// Upper bound for `load`/`import` request bodies held in memory.
pub const max_load_bytes: usize = 1 << 30; // 1 GiB

/// Searches a registry (`GET /images/search?term=...`).
pub fn searchImages(client: *const http.Client, logger: *log.Logger, term: []const u8, writer: anytype) !void {
    if (term.len == 0 or term.len > 256) return ApiError.InvalidIdentifier;
    for (term) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidIdentifier;
    }

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/images/search?term=");
    try appendQueryEncoded(&path_buf, term);

    logger.debug("GET {s}", .{path_buf.items});
    const resp = try client.request("GET", path_buf.items, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path_buf.items, resp);

    const parsed = try std.json.parseFromSlice([]ImageSearchItem, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try writer.print("{s:<36} {s:<8} {s:<10} {s}\n", .{ "NAME", "OFFICIAL", "STARS", "DESCRIPTION" });
    for (parsed.value) |item| {
        try writer.print("{s:<36} {s:<8} {d:<10} {s}\n", .{
            item.Name,
            if (item.IsOfficial) "[OK]" else "",
            item.StarCount,
            item.Description,
        });
    }
    logger.info("searched {d} result(s) for '{s}'", .{ parsed.value.len, term });
}

fn writeFileCtx(comptime OutType: type) type {
    return struct {
        file: OutType,
        written: u64 = 0,

        fn onChunk(self: *@This(), chunk: []const u8) anyerror!void {
            try self.file.writeAll(chunk);
            self.written += chunk.len;
        }
    };
}

fn createOutput(path: []const u8) !std.fs.File {
    try validateHostPath(path, false);
    return std.fs.createFileAbsolute(path, .{ .truncate = true });
}

/// Streams an image tarball from the daemon into a host file
/// (`GET /images/{ref}/get`).
pub fn saveImage(client: *const http.Client, logger: *log.Logger, image: []const u8, out_path: []const u8, stdout: anytype) !void {
    try validateResourceRef(image);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/images/{s}/get", .{ api_prefix, image });
    defer client.allocator.free(path);

    const file = try createOutput(out_path);
    defer file.close();

    var ctx = writeFileCtx(std.fs.File){ .file = file };
    logger.debug("GET {s}", .{path});
    const resp = try client.streamRequest(
        "GET",
        path,
        null,
        http.blocking_timeout_ms,
        &ctx,
        writeFileCtx(std.fs.File).onChunk,
    );
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "GET", path, err_resp);
    }

    try stdout.print("Saved {s} to {s}\n", .{ image, out_path });
    logger.info("saved image {s} to {s} ({d} bytes)", .{ image, out_path, ctx.written });
}

/// Streams a container rootfs tarball into a host file
/// (`GET /containers/{id}/export`).
pub fn exportContainer(client: *const http.Client, logger: *log.Logger, container: []const u8, out_path: []const u8, stdout: anytype) !void {
    try validateIdentifier(container);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/export", .{ api_prefix, container });
    defer client.allocator.free(path);

    const file = try createOutput(out_path);
    defer file.close();

    var ctx = writeFileCtx(std.fs.File){ .file = file };
    logger.debug("GET {s}", .{path});
    const resp = try client.streamRequest(
        "GET",
        path,
        null,
        http.blocking_timeout_ms,
        &ctx,
        writeFileCtx(std.fs.File).onChunk,
    );
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "GET", path, err_resp);
    }

    try stdout.print("Exported {s} to {s}\n", .{ container, out_path });
    logger.info("exported container {s} to {s} ({d} bytes)", .{ container, out_path, ctx.written });
}

fn openInput(path: []const u8) !std.fs.File {
    try validateHostPath(path, false);
    return std.fs.openFileAbsolute(path, .{});
}

/// Reads a local tar file (bounded by `max_load_bytes`) for upload.
fn readInputFile(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try openInput(path);
    defer file.close();
    const size = (try file.stat()).size;
    if (size > max_load_bytes) return ApiError.BuildContextTooLarge;
    return try file.readToEndAlloc(alloc, max_load_bytes);
}

/// Uploads a local image tarball to the daemon (`POST /images/load?quiet=0`).
pub fn loadImage(client: *const http.Client, logger: *log.Logger, in_path: []const u8, stdout: anytype) !void {
    const body = try readInputFile(client.allocator, in_path);
    defer client.allocator.free(body);

    const path = api_prefix ++ "/images/load?quiet=0";
    logger.debug("POST {s}", .{path});
    // Loading a large tar can take minutes before the daemon responds.
    const resp = try client.requestWithTimeout("POST", path, body, http.blocking_timeout_ms);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    const trimmed = std.mem.trim(u8, resp.body, " \r\n\t");
    if (trimmed.len > 0) try stdout.print("{s}\n", .{trimmed});
    logger.info("loaded image tarball from {s}", .{in_path});
}

/// Uploads a local rootfs tarball as a new image
/// (`POST /images/load?fromSrc=-&repo=...`).
pub fn importImage(client: *const http.Client, logger: *log.Logger, in_path: []const u8, ref: []const u8, stdout: anytype) !void {
    try validateResourceRef(ref);
    const body = try readInputFile(client.allocator, in_path);
    defer client.allocator.free(body);

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/images/load?fromSrc=-&repo=");
    try appendQueryEncoded(&path_buf, ref);

    logger.debug("POST {s}", .{path_buf.items});
    const resp = try client.requestWithTimeout("POST", path_buf.items, body, http.blocking_timeout_ms);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path_buf.items, resp);

    const trimmed = std.mem.trim(u8, resp.body, " \r\n\t");
    if (trimmed.len > 0) try stdout.print("{s}\n", .{trimmed});
    logger.info("imported image {s} from {s}", .{ ref, in_path });
}

// ---------------------------------------------------------------- tests

const MockApiCtx = th.MockApiCtx;
const ScriptedReply = th.ScriptedReply;
const runMockPodmanServer = th.runMockPodmanServer;

test "searchImages renders table and rejects malformed terms" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-search-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const search_json =
        \\[{"Description":"A minimal container","IsOfficial":true,"Name":"alpine","StarCount":9000},{"Description":"","IsOfficial":false,"Name":"user/alpine","StarCount":3}]
    ;
    const replies = [_]ScriptedReply{.{
        .expected_prefix = "GET /v1.40/images/search?term=alpine HTTP/1.1\r\n",
        .raw_response = std.fmt.comptimePrint(
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ search_json.len, search_json },
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

    try searchImages(&client, &logger, "alpine", out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "alpine") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[OK]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "A minimal container") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "user/alpine") != null);

    var sink = std.ArrayList(u8).init(alloc);
    defer sink.deinit();
    var e1 = false;
    searchImages(&client, &logger, "", sink.writer()) catch |e| {
        e1 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e1);
    var e2 = false;
    searchImages(&client, &logger, "a\x01b", sink.writer()) catch |e| {
        e2 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e2);
    var e3 = false;
    searchImages(&client, &logger, "a" ** 257, sink.writer()) catch |e| {
        e3 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e3);

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 1), ctx.matched);
}

test "saveImage and exportContainer stream tarball into host files" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-save-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(out_dir);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out.tar", .{out_dir});
    defer alloc.free(out_path);
    defer std.fs.deleteFileAbsolute(out_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const tar_data = "TARBALL-PAYLOAD-0123456789ABCDEF";
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/images/alpine:3.20/get HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ tar_data.len, tar_data },
            ),
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/export HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ tar_data.len, tar_data },
            ),
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

    try saveImage(&client, &logger, "alpine:3.20", out_path, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Saved alpine:3.20") != null);

    try exportContainer(&client, &logger, "web", out_path, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Exported web") != null);

    const written = try std.fs.cwd().readFileAlloc(alloc, out_path, tar_data.len);
    defer alloc.free(written);
    try std.testing.expectEqualStrings(tar_data, written);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "loadImage and importImage upload tarballs and fail closed" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-load-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const in_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(in_dir);
    const in_path = try std.fmt.allocPrint(alloc, "{s}/in.tar", .{in_dir});
    defer alloc.free(in_path);
    try tmp.dir.writeFile(.{ .sub_path = "in.tar", .data = "UPLOAD-PAYLOAD" });

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const loaded_status = "{\"status\":\"Loaded image: alpine:3.20\"}";
    const imported_status = "{\"status\":\"Imported\"}";
    const denied_json = "{\"message\":\"denied\"}";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/images/load?quiet=0 HTTP/1.1\r\n",
            .expected_substring = "UPLOAD-PAYLOAD",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ loaded_status.len, loaded_status },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/images/load?fromSrc=-&repo=myrepo%2Fapp%3Av2 HTTP/1.1\r\n",
            .expected_substring = "UPLOAD-PAYLOAD",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ imported_status.len, imported_status },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/images/load?quiet=0 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 403 Forbidden\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ denied_json.len, denied_json },
            ),
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

    try loadImage(&client, &logger, in_path, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Loaded image: alpine:3.20") != null);

    try importImage(&client, &logger, in_path, "myrepo/app:v2", out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Imported") != null);

    var got_api_err = false;
    loadImage(&client, &logger, in_path, out.writer()) catch |e| {
        got_api_err = e == ApiError.PodmanApiError;
    };
    try std.testing.expect(got_api_err);

    // Validation paths: dangerous output/input locations and bad refs.
    var e1 = false;
    saveImage(&client, &logger, "img", "/etc/passwd", out.writer()) catch |e| {
        e1 = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e1);
    var e2 = false;
    loadImage(&client, &logger, "/root/../etc/shadow", out.writer()) catch |e| {
        e2 = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e2);
    var e3 = false;
    importImage(&client, &logger, in_path, "bad?x=1", out.writer()) catch |e| {
        e3 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e3);
    var e4 = false;
    exportContainer(&client, &logger, "a/../b", "/tmp/zp-tr-export.tar", out.writer()) catch |e| {
        e4 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e4);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}
