//! Image build endpoint (`POST /build`) with a minimal pure-Zig ustar writer
//! for uploading the build context, plus JSON-line stream handling.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const validate = @import("podman_validate.zig");
const th = @import("podman_test_helpers.zig");

const api_prefix = validate.api_prefix;
const validateResourceRef = validate.validateResourceRef;
const appendQueryEncoded = validate.appendQueryEncoded;
const logApiFailure = validate.logApiFailure;

const ApiError = types.ApiError;
const BuildStreamEvent = types.BuildStreamEvent;

const MockApiCtx = th.MockApiCtx;
const ScriptedReply = th.ScriptedReply;
const runMockPodmanServer = th.runMockPodmanServer;

pub const max_build_context_bytes: usize = 512 * 1024 * 1024;
pub const build_timeout_ms: i32 = 600_000;

const tar_block: usize = 512;

fn appendOctal(out: *[11]u8, value: u64) void {
    var v = value;
    var pos: usize = 11;
    while (pos > 0) {
        pos -= 1;
        out[pos] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
        if (v == 0) break;
    }
    while (pos > 0) {
        pos -= 1;
        out[pos] = '0';
    }
}

fn writeTarHeader(out: *std.ArrayList(u8), name: []const u8, size: u64, typeflag: u8, linkname: []const u8) !void {
    if (name.len > 100 or linkname.len > 100) return error.NameTooLong;

    var hdr = [_]u8{0} ** tar_block;
    @memcpy(hdr[0..name.len], name);
    // mode 0644 for files, 0755 for dirs/symlinks; uid/gid 0; mtime 0 for deterministic output.
    const mode: []const u8 = if (typeflag == '5') "0000755\x00" else "0000644\x00";
    @memcpy(hdr[100 .. 100 + mode.len], mode);
    @memcpy(hdr[108..116], "0000000\x00");
    @memcpy(hdr[116..124], "0000000\x00");
    appendOctal(hdr[124..135], size);
    hdr[135] = 0;
    appendOctal(hdr[136..147], 0);
    hdr[147] = 0;
    @memset(hdr[148..156], ' ');
    hdr[156] = typeflag;
    @memcpy(hdr[157 .. 157 + linkname.len], linkname);
    @memcpy(hdr[257..263], "ustar\x00");
    @memcpy(hdr[263..265], "00");
    @memcpy(hdr[329..337], "0000000\x00");
    @memcpy(hdr[337..345], "0000000\x00");

    var sum: u64 = 0;
    for (hdr) |c| sum += c;
    var cbuf: [16]u8 = undefined;
    const cs = std.fmt.bufPrint(&cbuf, "{o}", .{sum}) catch return error.TarHeader;
    const cs_len: usize = cs.len;
    for (0..cs_len) |i| hdr[148 + i] = cs[i];
    hdr[148 + cs_len] = 0;
    hdr[155] = ' ';

    try out.appendSlice(&hdr);
}

fn writePad(out: *std.ArrayList(u8), size: usize) !void {
    const rem = size % tar_block;
    if (rem != 0) {
        const pad = tar_block - rem;
        const zeros = [_]u8{0} ** tar_block;
        try out.appendSlice(zeros[0..pad]);
    }
}

const Entry = struct {
    name: []u8,
    kind: std.fs.File.Kind,
    size: u64,
    linkname: []u8,
};

fn collectEntries(alloc: std.mem.Allocator, dir: std.fs.Dir) ![]Entry {
    var list = std.ArrayList(Entry).init(alloc);
    errdefer {
        for (list.items) |e| {
            alloc.free(e.name);
            alloc.free(e.linkname);
        }
        list.deinit();
    }

    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |w| {
        const kind: std.fs.File.Kind = switch (w.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .sym_link,
            else => continue,
        };
        var linkname: []u8 = &.{};
        if (kind == .sym_link) {
            var lbuf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            linkname = try alloc.dupe(u8, try dir.readLink(w.basename, &lbuf));
        }
        try list.append(.{
            .name = try alloc.dupe(u8, w.path),
            .kind = kind,
            .size = 0,
            .linkname = linkname,
        });
    }

    std.mem.sort(Entry, list.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return list.toOwnedSlice();
}

/// Serializes a directory into a ustar archive (deterministic: sorted names,
/// mtime 0). `out` must be owned by the caller and starts empty.
pub fn tarBuildContext(alloc: std.mem.Allocator, ctx_dir: []const u8, out: *std.ArrayList(u8)) !void {
    var dir = std.fs.cwd().openDir(ctx_dir, .{ .iterate = true }) catch return ApiError.NotFound;
    defer dir.close();

    const entries = try collectEntries(alloc, dir);
    defer {
        for (entries) |e| {
            alloc.free(e.name);
            alloc.free(e.linkname);
        }
        alloc.free(entries);
    }

    const size_check = std.math.mul(usize, entries.len + 1, tar_block) catch return ApiError.BuildContextTooLarge;
    try out.ensureTotalCapacity(out.items.len + size_check);

    for (entries) |e| {
        const tname = if (e.kind == .directory)
            try std.fmt.allocPrint(alloc, "{s}/", .{e.name})
        else
            e.name;
        defer if (e.kind == .directory) alloc.free(tname);

        switch (e.kind) {
            .file => {
                const content = dir.readFileAlloc(alloc, e.name, max_build_context_bytes) catch |err| switch (err) {
                    error.FileTooBig => return ApiError.BuildContextTooLarge,
                    else => return err,
                };
                defer alloc.free(content);
                try writeTarHeader(out, tname, content.len, '0', "");
                try out.appendSlice(content);
                try writePad(out, content.len);
            },
            .directory => {
                try writeTarHeader(out, tname, 0, '5', "");
            },
            .sym_link => {
                try writeTarHeader(out, tname, 0, '2', e.linkname);
            },
            else => unreachable,
        }
    }

    // Two zero blocks terminate the archive.
    const zeros = [_]u8{0} ** tar_block;
    try out.appendSlice(&zeros);
    try out.appendSlice(&zeros);

    if (out.items.len > max_build_context_bytes) return ApiError.BuildContextTooLarge;
}

/// Builds an image from a build-context directory (`POST /build` with a tar
/// stream). Streams build output lines to `writer` and prints the final image ID.
pub fn buildImage(
    client: *const http.Client,
    logger: *log.Logger,
    tag: []const u8,
    ctx_dir: []const u8,
    writer: anytype,
) !void {
    try validateResourceRef(tag);

    // Fail-closed: refuse to build without a Dockerfile/Containerfile in the context.
    var dir = std.fs.cwd().openDir(ctx_dir, .{}) catch return ApiError.NotFound;
    defer dir.close();
    const has_dockerfile = dir.access("Dockerfile", .{}) catch null;
    const has_containerfile = dir.access("Containerfile", .{}) catch null;
    if (has_dockerfile == null and has_containerfile == null) return ApiError.MissingDockerfile;

    var tar_buf = std.ArrayList(u8).init(client.allocator);
    defer tar_buf.deinit();
    try tarBuildContext(client.allocator, ctx_dir, &tar_buf);

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/build?t=");
    try appendQueryEncoded(&path_buf, tag);
    try path_buf.appendSlice("&q=1");

    logger.debug("POST {s} (context {d} bytes)", .{ path_buf.items, tar_buf.items.len });
    const resp = try client.requestWithContentType("POST", path_buf.items, tar_buf.items, "application/x-tar", build_timeout_ms);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path_buf.items, resp);

    var image_id: []const u8 = "";
    var lines = std.mem.splitScalar(u8, resp.body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const ev = std.json.parseFromSlice(BuildStreamEvent, client.allocator, trimmed, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer ev.deinit();

        if (ev.value.@"error") |emsg| {
            if (ev.value.errorDetail) |d| {
                if (d.message.len > 0) {
                    logger.err("build error: {s}", .{d.message});
                }
            }
            logger.err("build error: {s}", .{emsg});
            return ApiError.BuildFailed;
        }
        if (ev.value.aux) |aux| {
            if (aux.ID.len > 0) image_id = aux.ID;
        }
        if (ev.value.stream) |s| {
            try writer.writeAll(s);
        }
    }

    if (image_id.len > 0) {
        try writer.print("=> image {s}\n", .{image_id});
        logger.info("built image {s} ({s})", .{ tag, image_id });
    } else {
        logger.info("built image {s}", .{tag});
    }
}

// ---------------------------------------------------------------- tests

test "tarBuildContext emits deterministic ustar and round-trips via std.tar" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "Dockerfile", .data = "FROM alpine:3.20\n" });
    try tmp.dir.makePath("assets");
    try tmp.dir.writeFile(.{ .sub_path = "assets/hello.txt", .data = "hi" });

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    var tar_buf = std.ArrayList(u8).init(alloc);
    defer tar_buf.deinit();
    try tarBuildContext(alloc, dir_path, &tar_buf);

    try std.testing.expect(tar_buf.items.len % tar_block == 0);
    try std.testing.expectEqualSlices(u8, "ustar\x00", tar_buf.items[257..263]);

    var fbs = std.io.fixedBufferStream(tar_buf.items);
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var iter = std.tar.iterator(fbs.reader(), .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    var names = std.ArrayList([]const u8).init(alloc);
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit();
    }
    var seen_hello_data = false;
    while (try iter.next()) |f| {
        try names.append(try alloc.dupe(u8, f.name));
        if (std.mem.eql(u8, f.name, "assets/hello.txt")) {
            var data: [2]u8 = undefined;
            const nread = try fbs.reader().readAll(&data);
            seen_hello_data = nread == 2 and std.mem.eql(u8, &data, "hi");
        }
    }
    var has_dockerfile = false;
    var has_assets_dir = false;
    var has_hello = false;
    for (names.items) |n| {
        if (std.mem.eql(u8, n, "Dockerfile")) has_dockerfile = true;
        if (std.mem.eql(u8, n, "assets/")) has_assets_dir = true;
        if (std.mem.eql(u8, n, "assets/hello.txt")) has_hello = true;
    }
    try std.testing.expect(has_dockerfile);
    try std.testing.expect(has_assets_dir);
    try std.testing.expect(has_hello);
    try std.testing.expect(seen_hello_data);

    var tar_buf2 = std.ArrayList(u8).init(alloc);
    defer tar_buf2.deinit();
    try tarBuildContext(alloc, dir_path, &tar_buf2);
    try std.testing.expectEqualSlices(u8, tar_buf.items, tar_buf2.items);
}

test "tarBuildContext rejects empty context (deterministic ustar terminator only)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    var tar_buf = std.ArrayList(u8).init(alloc);
    defer tar_buf.deinit();
    try tarBuildContext(alloc, dir_path, &tar_buf);
    try std.testing.expectEqual(@as(usize, 2 * tar_block), tar_buf.items.len);
}

test "buildImage over mock Unix socket streams output and reports image id" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-build-api-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const build_out =
        "{\"stream\":\"STEP 1/2: FROM alpine:3.20\\n\"}\n" ++
        "{\"stream\":\"STEP 2/2: RUN echo hi\\n\"}\n" ++
        "{\"aux\":{\"ID\":\"sha256:beefcafe1234\"}}\n";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/build?t=local%2Fdemo%3A1.0&q=1 HTTP/1.1\r\n",
            .expected_substring = "Content-Type: application/x-tar",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ build_out.len, build_out }),
        },
    };

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "Dockerfile", .data = "FROM alpine:3.20\n" });
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try buildImage(&client, &logger, "local/demo:1.0", dir_path, out.writer());
    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "STEP 1/2: FROM alpine:3.20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "=> image sha256:beefcafe1234") != null);
}

test "buildImage fail-closed: bad tag, missing context, and missing Dockerfile" {
    const alloc = std.testing.allocator;
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "no dockerfile here" });
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const client = http.Client{ .allocator = alloc, .socket_path = "/tmp/zp-build-invalid.sock" };
    var sink = std.ArrayList(u8).init(alloc);
    defer sink.deinit();

    var e_bad = false;
    buildImage(&client, &logger, "bad tag;", dir_path, sink.writer()) catch |e| { e_bad = e == ApiError.InvalidIdentifier; };
    try std.testing.expect(e_bad);
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", "/tmp/zp-build-no-such-dir-xyz", sink.writer()) catch |e| { e_bad = e == ApiError.NotFound; };
    try std.testing.expect(e_bad);
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", dir_path, sink.writer()) catch |e| { e_bad = e == ApiError.MissingDockerfile; };
    try std.testing.expect(e_bad);
}

test "buildImage returns BuildFailed on error stream event" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-build-api-err-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const build_out = "{\"stream\":\"STEP 1/1: RUN false\\n\"}\n{\"error\":\"build failed at RUN false\",\"errorDetail\":{\"message\":\"exit code 1\"}}\n";
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/build?t=local%2Ffail%3A1.0&q=1 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ build_out.len, build_out }),
        },
    };

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "Containerfile", .data = "FROM alpine:3.20\nRUN false\n" });
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var sink = std.ArrayList(u8).init(alloc);
    defer sink.deinit();
    var b_failed = false;
    buildImage(&client, &logger, "local/fail:1.0", dir_path, sink.writer()) catch |e| { b_failed = e == ApiError.BuildFailed; };
    try std.testing.expect(b_failed);
    thread.join();
    joined = true;
}
