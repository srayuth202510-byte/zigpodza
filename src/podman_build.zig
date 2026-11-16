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
const validateHostPath = validate.validateHostPath;
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

pub fn writeTarHeader(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, size: u64, typeflag: u8, linkname: []const u8) !void {
    if (name.len > 100 or linkname.len > 100) return error.NameTooLong;

    var hdr: [tar_block]u8 = @splat(0);
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
    _ = std.fmt.bufPrint(hdr[148..155], "{o:0>6}\x00", .{sum}) catch return error.TarHeader;
    hdr[155] = ' ';

    try out.appendSlice(alloc, &hdr);
}

pub fn writePad(alloc: std.mem.Allocator, out: *std.ArrayList(u8), size: usize) !void {
    const rem = size % tar_block;
    if (rem != 0) {
        const pad = tar_block - rem;
        const zeros: [tar_block]u8 = @splat(0);
        try out.appendSlice(alloc, zeros[0..pad]);
    }
}

pub fn writeTarTrailer(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const zeros: [tar_block]u8 = @splat(0);
    try out.appendSlice(alloc, &zeros);
    try out.appendSlice(alloc, &zeros);
}

const Entry = struct {
    name: []u8,
    kind: std.Io.File.Kind,
    size: u64,
    linkname: []u8,
};

fn validateBuildSymlinkTarget(target: []const u8) ApiError!void {
    if (target.len == 0 or target.len > 100) return ApiError.InvalidHostPath;
    if (target[0] == '/') return ApiError.InvalidHostPath;
    for (target) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidHostPath;
    }
    var segs = std.mem.splitScalar(u8, target, '/');
    while (segs.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return ApiError.InvalidHostPath;
    }
}

fn collectEntries(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |e| {
            alloc.free(e.name);
            alloc.free(e.linkname);
        }
        list.deinit(alloc);
    }

    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |w| {
        const kind: std.Io.File.Kind = switch (w.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .sym_link,
            else => continue,
        };
        var linkname: []u8 = &.{};
        if (kind == .sym_link) {
            var lbuf: [utils.max_path_bytes]u8 = undefined;
            const raw_link = lbuf[0..try dir.readLink(io, w.path, &lbuf)];
            try validateBuildSymlinkTarget(raw_link);
            linkname = try alloc.dupe(u8, raw_link);
        }
        errdefer if (linkname.len > 0) alloc.free(linkname);

        // Bind `name` before append so OOM inside `list.append` never leaks it (BUG-035).
        const name = try alloc.dupe(u8, w.path);
        errdefer alloc.free(name);
        try list.append(alloc, .{
            .name = name,
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
    return list.toOwnedSlice(alloc);
}

/// Serializes a directory into a ustar archive (deterministic: sorted names,
/// mtime 0). `out` must be owned by the caller and starts empty.
pub fn tarBuildContext(io: std.Io, alloc: std.mem.Allocator, ctx_dir: []const u8, out: *std.ArrayList(u8)) !void {
    return tarDirectoryWithPrefix(io, alloc, ctx_dir, null, out);
}

fn realpathOrInvalidHostPath(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    return utils.realpathAlloc(io, dir, ".", alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ApiError.InvalidHostPath,
    };
}

/// Serializes `ctx_dir` into a ustar archive, optionally nesting all entries
/// under `prefix/` (used by `zigpod cp` for directory uploads).
pub fn tarDirectoryWithPrefix(
    io: std.Io,
    alloc: std.mem.Allocator,
    ctx_dir: []const u8,
    prefix: ?[]const u8,
    out: *std.ArrayList(u8),
) !void {
    if (ctx_dir.len == 0) return ApiError.InvalidHostPath;
    if (std.mem.startsWith(u8, ctx_dir, "/")) {
        try validateHostPath(io, ctx_dir, false);
    }

    var dir = std.Io.Dir.cwd().openDir(io, ctx_dir, .{ .iterate = true }) catch return ApiError.NotFound;
    defer dir.close(io);

    const real_ctx = try realpathOrInvalidHostPath(io, alloc, dir);
    defer alloc.free(real_ctx);
    try validateHostPath(io, real_ctx, false);

    const entries = try collectEntries(io, alloc, dir);
    defer {
        for (entries) |e| {
            alloc.free(e.name);
            alloc.free(e.linkname);
        }
        alloc.free(entries);
    }

    const size_check = std.math.mul(usize, entries.len + 2, tar_block) catch return ApiError.BuildContextTooLarge;
    const total_cap = std.math.add(usize, out.items.len, size_check) catch return ApiError.BuildContextTooLarge;
    try out.ensureTotalCapacity(alloc, total_cap);

    if (prefix) |pfx| {
        const root_dir = try std.fmt.allocPrint(alloc, "{s}/", .{pfx});
        defer alloc.free(root_dir);
        try writeTarHeader(alloc, out, root_dir, 0, '5', "");
    }

    for (entries) |e| {
        const rel = if (prefix) |pfx|
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ pfx, e.name })
        else
            e.name;
        defer if (prefix != null) alloc.free(rel);

        const tname = if (e.kind == .directory)
            try std.fmt.allocPrint(alloc, "{s}/", .{rel})
        else
            rel;
        defer if (e.kind == .directory) alloc.free(tname);

        switch (e.kind) {
            .file => {
                const content = dir.readFileAlloc(io, e.name, alloc, .limited(max_build_context_bytes + 1)) catch |err| switch (err) {
                    error.StreamTooLong => return ApiError.BuildContextTooLarge,
                    else => return err,
                };
                defer alloc.free(content);
                const projected = std.math.add(usize, out.items.len, tar_block + content.len) catch return ApiError.BuildContextTooLarge;
                if (projected > max_build_context_bytes) return ApiError.BuildContextTooLarge;
                try writeTarHeader(alloc, out, tname, content.len, '0', "");
                try out.appendSlice(alloc, content);
                try writePad(alloc, out, content.len);
            },
            .directory => {
                try writeTarHeader(alloc, out, tname, 0, '5', "");
            },
            .sym_link => {
                try writeTarHeader(alloc, out, tname, 0, '2', e.linkname);
            },
            else => unreachable,
        }
    }

    try writeTarTrailer(alloc, out);

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
    const io = client.io;
    try validateResourceRef(tag);
    if (ctx_dir.len == 0) return ApiError.InvalidHostPath;
    if (std.mem.startsWith(u8, ctx_dir, "/")) {
        try validateHostPath(io, ctx_dir, false);
    }

    // Fail-closed: refuse to build without a Dockerfile/Containerfile in the context.
    var dir = std.Io.Dir.cwd().openDir(io, ctx_dir, .{}) catch {
        logger.err("build context directory not found: {s}", .{ctx_dir});
        return ApiError.NotFound;
    };
    defer dir.close(io);
    const real_ctx = try realpathOrInvalidHostPath(io, client.allocator, dir);
    defer client.allocator.free(real_ctx);
    try validateHostPath(io, real_ctx, false);
    const has_dockerfile = dir.access(io, "Dockerfile", .{}) catch null;
    const has_containerfile = dir.access(io, "Containerfile", .{}) catch null;
    if (has_dockerfile == null and has_containerfile == null) return ApiError.MissingDockerfile;

    var tar_buf: std.ArrayList(u8) = .empty;
    defer tar_buf.deinit(client.allocator);
    try tarBuildContext(io, client.allocator, ctx_dir, &tar_buf);

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(client.allocator);
    try path_buf.appendSlice(client.allocator, api_prefix ++ "/build?t=");
    try appendQueryEncoded(client.allocator, &path_buf, tag);
    try path_buf.appendSlice(client.allocator, "&q=1");

    logger.debug("POST {s} (context {d} bytes)", .{ path_buf.items, tar_buf.items.len });
    const resp = try client.requestWithContentType("POST", path_buf.items, tar_buf.items, "application/x-tar", build_timeout_ms);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path_buf.items, resp);

    var image_id: ?[]u8 = null;
    defer if (image_id) |id| client.allocator.free(id);
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
            if (aux.ID.len > 0) {
                const duped = try client.allocator.dupe(u8, aux.ID);
                if (image_id) |old| client.allocator.free(old);
                image_id = duped;
            }
        }
        if (ev.value.stream) |s| {
            try writer.writeAll(s);
        }
    }

    if (image_id) |id| {
        try writer.print("=> image {s}\n", .{id});
        logger.info("built image {s} ({s})", .{ tag, id });
    } else {
        logger.info("built image {s}", .{tag});
    }
}

// ---------------------------------------------------------------- tests

test "tarBuildContext emits deterministic ustar and round-trips via std.tar" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Dockerfile", .data = "FROM alpine:3.20\n" });
    try tmp.dir.createDirPath(std.testing.io, "assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "assets/hello.txt", .data = "hi" });
    try tmp.dir.symLink(std.testing.io, "hello.txt", "assets/link", .{});

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    var tar_buf: std.ArrayList(u8) = .empty;
    defer tar_buf.deinit(alloc);
    try tarBuildContext(std.testing.io, alloc, dir_path, &tar_buf);

    try std.testing.expect(tar_buf.items.len % tar_block == 0);
    try std.testing.expectEqualSlices(u8, "ustar\x00", tar_buf.items[257..263]);

    var tar_reader: std.Io.Reader = .fixed(tar_buf.items);
    var name_buf: [utils.max_path_bytes]u8 = undefined;
    var link_buf: [utils.max_path_bytes]u8 = undefined;
    var iter: std.tar.Iterator = .init(&tar_reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var seen_hello_data = false;
    var seen_link = false;
    while (try iter.next()) |f| {
        try names.append(alloc, try alloc.dupe(u8, f.name));
        if (std.mem.eql(u8, f.name, "assets/hello.txt")) {
            var data: [2]u8 = undefined;
            var data_writer: std.Io.Writer = .fixed(&data);
            try iter.streamRemaining(f, &data_writer);
            seen_hello_data = data_writer.end == 2 and std.mem.eql(u8, &data, "hi");
        }
        if (std.mem.eql(u8, f.name, "assets/link") and f.kind == .sym_link) {
            seen_link = std.mem.eql(u8, f.link_name, "hello.txt");
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
    try std.testing.expect(seen_link);

    var tar_buf2: std.ArrayList(u8) = .empty;
    defer tar_buf2.deinit(alloc);
    try tarBuildContext(std.testing.io, alloc, dir_path, &tar_buf2);
    try std.testing.expectEqualSlices(u8, tar_buf.items, tar_buf2.items);
}

test "tarBuildContext rejects empty context (deterministic ustar terminator only)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    var tar_buf: std.ArrayList(u8) = .empty;
    defer tar_buf.deinit(alloc);
    try tarBuildContext(std.testing.io, alloc, dir_path, &tar_buf);
    try std.testing.expectEqual(@as(usize, 2 * tar_block), tar_buf.items.len);
}

test "buildImage over mock Unix socket streams output and reports image id" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-build-api-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

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

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Dockerfile", .data = "FROM alpine:3.20\n" });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try buildImage(&client, &logger, "local/demo:1.0", dir_path, &out.writer);
    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "STEP 1/2: FROM alpine:3.20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "=> image sha256:beefcafe1234") != null);
}

test "buildImage fail-closed: bad tag, missing context, and missing Dockerfile" {
    const alloc = std.testing.allocator;
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "no dockerfile here" });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    const client = http.Client{ .allocator = alloc, .socket_path = "/tmp/zp-build-invalid.sock", .io = std.testing.io };
    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    var e_bad = false;
    buildImage(&client, &logger, "bad tag;", dir_path, &sink.writer) catch |e| {
        e_bad = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e_bad);
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", "/tmp/zp-build-no-such-dir-xyz", &sink.writer) catch |e| {
        e_bad = e == ApiError.NotFound;
    };
    try std.testing.expect(e_bad);
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", dir_path, &sink.writer) catch |e| {
        e_bad = e == ApiError.MissingDockerfile;
    };
    try std.testing.expect(e_bad);
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", "/etc", &sink.writer) catch |e| {
        e_bad = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e_bad);
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", "/root", &sink.writer) catch |e| {
        e_bad = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e_bad);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Dockerfile", .data = "FROM alpine:3.20\n" });
    try tmp.dir.symLink(std.testing.io, "/etc/shadow", "escape_abs", .{});
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", dir_path, &sink.writer) catch |e| {
        e_bad = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e_bad);
    try tmp.dir.deleteFile(std.testing.io, "escape_abs");

    try tmp.dir.symLink(std.testing.io, "../outside", "escape_rel", .{});
    e_bad = false;
    buildImage(&client, &logger, "ok:1.0", dir_path, &sink.writer) catch |e| {
        e_bad = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e_bad);
}

test "buildImage returns BuildFailed on error stream event" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-build-api-err-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const build_out = "{\"stream\":\"STEP 1/1: RUN false\\n\"}\n{\"error\":\"build failed at RUN false\",\"errorDetail\":{\"message\":\"exit code 1\"}}\n";
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/build?t=local%2Ffail%3A1.0&q=1 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ build_out.len, build_out }),
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Containerfile", .data = "FROM alpine:3.20\nRUN false\n" });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    var b_failed = false;
    buildImage(&client, &logger, "local/fail:1.0", dir_path, &sink.writer) catch |e| {
        b_failed = e == ApiError.BuildFailed;
    };
    try std.testing.expect(b_failed);
    thread.join();
    joined = true;
}

test "BUG-035 regression: collectEntries and tarBuildContext do not leak on OOM" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Dockerfile", .data = "FROM alpine:3.20\n" });
    try tmp.dir.createDirPath(std.testing.io, "sub");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/a.txt", .data = "a" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/b.txt", .data = "b" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/c.txt", .data = "c" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/d.txt", .data = "d" });
    try tmp.dir.symLink(std.testing.io, "a.txt", "sub/link", .{});

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    const Helper = struct {
        fn collect(a: std.mem.Allocator, path: []const u8) !void {
            const io = std.testing.io;
            var d = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            defer d.close(io);
            const entries = try collectEntries(io, a, d);
            for (entries) |e| {
                a.free(e.name);
                a.free(e.linkname);
            }
            a.free(entries);
        }

        fn build(a: std.mem.Allocator, path: []const u8) !void {
            var tar_buf: std.ArrayList(u8) = .empty;
            defer tar_buf.deinit(a);
            try tarBuildContext(std.testing.io, a, path, &tar_buf);
        }
    };
    try std.testing.checkAllAllocationFailures(alloc, Helper.collect, .{dir_path});
    try std.testing.checkAllAllocationFailures(alloc, Helper.build, .{dir_path});
}
