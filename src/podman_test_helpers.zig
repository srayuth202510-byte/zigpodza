//! Shared mock Unix-socket HTTP server helpers for Podman API tests.
const std = @import("std");
const Io = std.Io;

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    outer: for (0..haystack.len - needle.len + 1) |i| {
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) continue :outer;
        }
        return i;
    }
    return null;
}

pub fn readHttpRequest(io: Io, stream: Io.net.Stream, buf: []u8) ![]const u8 {
    var total: usize = 0;
    var header_end: ?usize = null;
    var expected_total: ?usize = null;
    while (total < buf.len) {
        var data = [_][]u8{buf[total..]};
        const n = (try (try io.operate(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        } })).net_read).data_len;
        if (n == 0) break;
        total += n;
        if (header_end == null) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                header_end = idx;
                var cl: usize = 0;
                if (containsIgnoreCase(buf[0..idx], "content-length:")) |cl_pos| {
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
    io: Io,
    server: *Io.net.Server,
    replies: []const ScriptedReply,
    matched: usize = 0,
    timeout_ms: i32 = 5_000,
    timed_out: bool = false,
    mismatch_count: usize = 0,
    silent_mismatch: bool = false,
};

fn pollReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    if (timeout_ms < 0) return true;
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return false;
    return ready > 0;
}

pub fn runMockPodmanServer(ctx: *MockApiCtx) void {
    var buf: [4096]u8 = undefined;
    for (ctx.replies, 0..) |reply, idx| {
        if (!pollReadable(ctx.server.socket.handle, ctx.timeout_ms)) {
            ctx.timed_out = true;
            return;
        }
        const conn = ctx.server.accept(ctx.io) catch return;
        defer conn.close(ctx.io);
        if (!pollReadable(conn.socket.handle, ctx.timeout_ms)) {
            ctx.timed_out = true;
            return;
        }
        const req = readHttpRequest(ctx.io, conn, &buf) catch return;
        const prefix_ok = std.mem.startsWith(u8, req, reply.expected_prefix);
        const sub_ok = if (reply.expected_substring) |sub| std.mem.indexOf(u8, req, sub) != null else true;
        if (prefix_ok and sub_ok) {
            ctx.matched += 1;
        } else {
            ctx.mismatch_count += 1;
            if (!ctx.silent_mismatch) {
                const req_end = std.mem.indexOf(u8, req, "\r\n") orelse @min(req.len, 120);
                const exp_end = std.mem.indexOf(u8, reply.expected_prefix, "\r\n") orelse reply.expected_prefix.len;
                std.debug.print(
                    "[mock-podman mismatch step={d}] expected_prefix=\"{s}\" expected_sub=\"{s}\" got_line=\"{s}\" (bytes={d})\n",
                    .{ idx, reply.expected_prefix[0..exp_end], reply.expected_substring orelse "", req[0..req_end], req.len },
                );
            }
        }
        http_socket_write(conn.socket.handle, reply.raw_response);
    }
}

fn http_socket_write(handle: Io.net.Socket.Handle, data: []const u8) void {
    var remaining = data;
    const linux = std.os.linux;
    while (remaining.len > 0) {
        const rc = linux.sendto(@intCast(handle), remaining.ptr, remaining.len, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return;
                remaining = remaining[n..];
            },
            .AGAIN, .INTR => std.Thread.yield() catch {},
            else => return,
        }
    }
}

// ---------------------------------------------------------------- tests

const ServeMode = enum { eof, keep_open };

fn servePayloadOnce(server: *Io.net.Server, io: Io, payload: []const u8, mode: ServeMode) void {
    const conn = server.accept(io) catch return;
    defer conn.close(io);
    http_socket_write(conn.socket.handle, payload);
    if (mode == .eof) {
        const rc = std.os.linux.shutdown(conn.socket.handle, std.os.linux.SHUT.RDWR);
        if (std.os.linux.errno(rc) != .SUCCESS) {}
    }
}

fn rep(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

test "readHttpRequest reads Content-Length framed body across socket" {
    const alloc = std.testing.allocator;
    const test_io = std.testing.io;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-frame-{d}.sock",
        .{Io.Clock.awake.now(test_io).nanoseconds},
    );
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const payload = "POST /v1.40/libpod/pods/create HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, test_io, payload, ServeMode.eof });

    const stream = try (try Io.net.UnixAddress.init(sock_path)).connect(test_io);
    defer stream.close(test_io);

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(test_io, stream, buf);
    thread.join();
    try std.testing.expectEqualStrings(payload, got);
}

test "readHttpRequest stops at header block without Content-Length" {
    const alloc = std.testing.allocator;
    const test_io = std.testing.io;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-hdr-{d}.sock",
        .{Io.Clock.awake.now(test_io).nanoseconds},
    );
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const payload = "GET /v1.40/_ping HTTP/1.1\r\nHost: podman\r\n\r\n";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, test_io, payload, ServeMode.keep_open });

    const stream = try (try Io.net.UnixAddress.init(sock_path)).connect(test_io);
    defer stream.close(test_io);

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(test_io, stream, buf);
    thread.join();
    try std.testing.expectEqualStrings(payload, got);
}

test "readHttpRequest treats malformed Content-Length as zero" {
    const alloc = std.testing.allocator;
    const test_io = std.testing.io;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-badcl-{d}.sock",
        .{Io.Clock.awake.now(test_io).nanoseconds},
    );
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const payload = "GET /x HTTP/1.1\r\ncontent-length: abc\r\n\r\nbody-leftover";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, test_io, payload, ServeMode.keep_open });

    const stream = try (try Io.net.UnixAddress.init(sock_path)).connect(test_io);
    defer stream.close(test_io);

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(test_io, stream, buf);
    thread.join();
    // Malformed Content-Length parses as 0, so the reader stops waiting for a
    // framed body (expected_total = header end) but still returns every byte
    // already delivered in the first read.
    try std.testing.expectEqualStrings(payload, got);
}

test "readHttpRequest caps output at buffer size" {
    const alloc = std.testing.allocator;
    const test_io = std.testing.io;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-cap-{d}.sock",
        .{Io.Clock.awake.now(test_io).nanoseconds},
    );
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const payload = "GET / HTTP/1.1\r\n\r\n" ++ rep("A", 64);
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, test_io, payload, ServeMode.eof });

    const stream = try (try Io.net.UnixAddress.init(sock_path)).connect(test_io);
    defer stream.close(test_io);

    const buf = try alloc.alloc(u8, 16);
    defer alloc.free(buf);

    const got = try readHttpRequest(test_io, stream, buf);
    thread.join();
    try std.testing.expectEqual(@as(usize, buf.len), got.len);
    try std.testing.expectEqualStrings(payload[0..buf.len], got);
}

test "readHttpRequest returns partial payload on EOF before header end" {
    const alloc = std.testing.allocator;
    const test_io = std.testing.io;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-partial-{d}.sock",
        .{Io.Clock.awake.now(test_io).nanoseconds},
    );
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const payload = "HTTP/1.1 200 OK\r\nX-Partial: 1\r\n";
    const thread = try std.Thread.spawn(.{}, servePayloadOnce, .{ &server, test_io, payload, ServeMode.eof });

    const stream = try (try Io.net.UnixAddress.init(sock_path)).connect(test_io);
    defer stream.close(test_io);

    const buf = try alloc.alloc(u8, 256);
    defer alloc.free(buf);

    const got = try readHttpRequest(test_io, stream, buf);
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

test "runMockPodmanServer enforces poll timeout and tracks request mismatches" {
    const alloc = std.testing.allocator;
    const test_io = std.testing.io;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-th-timeout-{d}.sock",
        .{Io.Clock.awake.now(test_io).nanoseconds},
    );
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const replies = [_]ScriptedReply{.{
        .expected_prefix = "GET /v1.40/expected HTTP/1.1\r\n",
        .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
    }};

    // 1) Timed out cleanly when no client connects within timeout_ms.
    var timeout_ctx = MockApiCtx{
        .io = test_io,
        .server = &server,
        .replies = &replies,
        .timeout_ms = 20,
    };
    const t1 = try std.Thread.spawn(.{}, runMockPodmanServer, .{&timeout_ctx});
    t1.join();
    try std.testing.expect(timeout_ctx.timed_out);
    try std.testing.expectEqual(@as(usize, 0), timeout_ctx.matched);

    // 2) Records mismatch_count without blocking when client sends an unexpected request.
    var mismatch_ctx = MockApiCtx{
        .io = test_io,
        .server = &server,
        .replies = &replies,
        .timeout_ms = 500,
        .silent_mismatch = true,
    };
    const t2 = try std.Thread.spawn(.{}, runMockPodmanServer, .{&mismatch_ctx});
    var joined = false;
    defer if (!joined) t2.join();

    const stream = try (try Io.net.UnixAddress.init(sock_path)).connect(test_io);
    defer stream.close(test_io);
    http_socket_write(stream.socket.handle, "GET /v1.40/wrong HTTP/1.1\r\nHost: podman\r\n\r\n");
    var rbuf: [64]u8 = undefined;
    var rdata = [_][]u8{&rbuf};
    _ = (try (try test_io.operate(.{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = &rdata,
    } })).net_read).data_len;

    t2.join();
    joined = true;
    try std.testing.expect(!mismatch_ctx.timed_out);
    try std.testing.expectEqual(@as(usize, 0), mismatch_ctx.matched);
    try std.testing.expectEqual(@as(usize, 1), mismatch_ctx.mismatch_count);
}
