//! Shared mock Unix-socket HTTP server helpers for Podman API tests.
const std = @import("std");

pub fn readHttpRequest(stream: std.net.Stream, buf: []u8) ![]const u8 {
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

pub const ScriptedReply = struct {
    expected_prefix: []const u8,
    expected_substring: ?[]const u8 = null,
    raw_response: []const u8,
};

pub const MockApiCtx = struct {
    server: *std.net.Server,
    replies: []const ScriptedReply,
    matched: usize = 0,
};

pub fn runMockPodmanServer(ctx: *MockApiCtx) void {
    var buf: [4096]u8 = undefined;
    for (ctx.replies) |reply| {
        const conn = ctx.server.accept() catch return;
        defer conn.stream.close();
        const req = readHttpRequest(conn.stream, &buf) catch return;
        const sub_ok = if (reply.expected_substring) |sub| std.mem.indexOf(u8, req, sub) != null else true;
        if (std.mem.startsWith(u8, req, reply.expected_prefix) and sub_ok) {
            ctx.matched += 1;
        }
        conn.stream.writeAll(reply.raw_response) catch return;
    }
}

// ---------------------------------------------------------------- tests

const ServeMode = enum { eof, keep_open };

fn servePayloadOnce(server: *std.net.Server, payload: []const u8, mode: ServeMode) void {
    const conn = server.accept() catch return;
    defer conn.stream.close();
    conn.stream.writeAll(payload) catch return;
    if (mode == .eof) std.posix.shutdown(conn.stream.handle, .both) catch {};
}

test "readHttpRequest reads Content-Length framed body across socket" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-frame-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const payload = "POST /v1.40/libpod/pods/create HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, payload, ServeMode.eof });

    const stream = try std.net.connectUnixSocket(sock_path);
    defer stream.close();

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(stream, buf);
    thread.join();
    try std.testing.expectEqualStrings(payload, got);
}

test "readHttpRequest stops at header block without Content-Length" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-hdr-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const payload = "GET /v1.40/_ping HTTP/1.1\r\nHost: podman\r\n\r\n";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, payload, ServeMode.keep_open });

    const stream = try std.net.connectUnixSocket(sock_path);
    defer stream.close();

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(stream, buf);
    thread.join();
    try std.testing.expectEqualStrings(payload, got);
}

test "readHttpRequest treats malformed Content-Length as zero" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-badcl-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const payload = "GET /x HTTP/1.1\r\ncontent-length: abc\r\n\r\nbody-leftover";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, payload, ServeMode.keep_open });

    const stream = try std.net.connectUnixSocket(sock_path);
    defer stream.close();

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(stream, buf);
    thread.join();
    // Malformed Content-Length parses as 0, so the reader stops waiting for a
    // framed body (expected_total = header end) but still returns every byte
    // already delivered in the first read.
    try std.testing.expectEqualStrings(payload, got);
}

test "readHttpRequest caps output at buffer size" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-cap-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const payload = "GET / HTTP/1.1\r\n\r\n" ++ "A" ** 64;
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, payload, ServeMode.eof });

    const stream = try std.net.connectUnixSocket(sock_path);
    defer stream.close();

    const buf = try alloc.alloc(u8, 16);
    defer alloc.free(buf);

    const got = try readHttpRequest(stream, buf);
    thread.join();
    try std.testing.expectEqual(@as(usize, buf.len), got.len);
    try std.testing.expectEqualStrings(payload[0..buf.len], got);
}

test "readHttpRequest returns partial payload on EOF before header end" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-partial-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const payload = "HTTP/1.1 200 OK\r\nX-Partial: 1\r\n";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, payload, ServeMode.eof });

    const stream = try std.net.connectUnixSocket(sock_path);
    defer stream.close();

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(stream, buf);
    thread.join();
    try std.testing.expectEqualStrings(payload, got);
}

test "ScriptedReply defaults tolerate absent substring matcher" {
    const alloc = std.testing.allocator;
    const prefix = try alloc.dupe(u8, "POST /v1.40/libpod/pods/create HTTP/1.1\r\n");
    defer alloc.free(prefix);

    const reply = ScriptedReply{ .expected_prefix = prefix, .raw_response = prefix };
    try std.testing.expect(reply.expected_substring == null);
    try std.testing.expectEqualStrings(reply.expected_prefix, reply.raw_response);
}
