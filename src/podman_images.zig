//! Podman / Docker-compatible image listing, pulling, and removal endpoints.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const v = @import("podman_validate.zig");

const api_prefix = v.api_prefix;
const validateResourceRef = v.validateResourceRef;
const appendQueryEncoded = v.appendQueryEncoded;
const logApiFailure = v.logApiFailure;

const ApiError = types.ApiError;
const ImageSummary = types.ImageSummary;
const PullStatusLine = types.PullStatusLine;

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
