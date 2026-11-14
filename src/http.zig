//! Minimal HTTP/1.1 client over a Unix domain socket.
//! One request per connection ("Connection: close"); supports Content-Length
//! and chunked transfer encoding. That's all the Podman API needs.
const std = @import("std");
pub const types = @import("http_types.zig");
pub const parser = @import("http_parser.zig");

pub const max_response_bytes = types.max_response_bytes;
pub const max_header_bytes = types.max_header_bytes;
pub const default_timeout_ms = types.default_timeout_ms;
pub const blocking_timeout_ms = types.blocking_timeout_ms;

pub const Error = types.Error;
pub const Response = types.Response;
pub const StreamResponse = types.StreamResponse;
pub const ResponseHead = types.ResponseHead;
pub const UpgradedConn = types.UpgradedConn;
pub const RawTermGuard = types.RawTermGuard;
pub const validateRequestTarget = types.validateRequestTarget;

pub const parseResponseHead = parser.parseResponseHead;
pub const parseResponse = parser.parseResponse;

fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) !void {
    if (timeout_ms < 0) return;
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, timeout_ms);
    if (ready == 0) return Error.Timeout;
}

/// Reads the full response until EOF, enforcing `timeout_ms` on *every* read
/// (not just the first byte) so a daemon that stalls mid-response cannot hang
/// the process forever (BUG-007).
fn readAllWithTimeout(
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    max_size: usize,
    timeout_ms: i32,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var chunk: [16384]u8 = undefined;
    while (true) {
        try waitReadable(stream.handle, timeout_ms);
        const n = try stream.read(&chunk);
        if (n == 0) break; // EOF: server honored "Connection: close"
        try out.appendSlice(chunk[0..n]);
        if (out.items.len > max_size) return error.StreamTooLong;
    }
    return out.toOwnedSlice();
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    timeout_ms: i32 = default_timeout_ms,

    pub fn request(self: Client, method: []const u8, path: []const u8, body: ?[]const u8) !Response {
        return self.requestWithTimeout(method, path, body, self.timeout_ms);
    }

    /// Same as `request` but with an explicit per-call read timeout. Endpoints
    /// that block until an external event (container exit, image pull) pass
    /// `blocking_timeout_ms` instead of the short default (BUG-007).
    pub fn requestWithTimeout(
        self: Client,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        timeout_ms: i32,
    ) !Response {
        return self.requestWithContentType(method, path, body, "application/json", timeout_ms);
    }

    /// Same as `requestWithTimeout` but lets the caller pick the `Content-Type`
    /// (e.g. `application/x-tar` for image build context uploads).
    pub fn requestWithContentType(
        self: Client,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        content_type: []const u8,
        timeout_ms: i32,
    ) !Response {
        const stream = try self.connectAndSend(method, path, body, false, content_type);
        defer stream.close();

        const raw = try readAllWithTimeout(stream, self.allocator, max_response_bytes, timeout_ms);
        defer self.allocator.free(raw);
        return parseResponse(self.allocator, raw);
    }

    /// Streams the HTTP response body directly to `on_chunk(ctx, slice)` without
    /// buffering the entire payload up to `max_response_bytes`. On non-2xx
    /// status, collects the error body into `StreamResponse.error_body`.
    pub fn streamRequest(
        self: Client,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        timeout_ms: i32,
        ctx: anytype,
        comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!void,
    ) !StreamResponse {
        const stream = try self.connectAndSend(method, path, body, false, "application/json");
        defer stream.close();

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const header_end = try readHeaderBlock(stream, &buf, timeout_ms);
        const head = try parseResponseHead(buf.items[0..header_end]);
        const rest_start = header_end + 4;

        // Compact `buf` so only initial body bytes remain at index 0.
        const leftover_len = buf.items.len - rest_start;
        if (leftover_len > 0) {
            std.mem.copyForwards(u8, buf.items[0..leftover_len], buf.items[rest_start..]);
        }
        buf.items.len = leftover_len;

        if (head.status < 200 or head.status >= 300) {
            var err_out = std.ArrayList(u8).init(self.allocator);
            errdefer err_out.deinit();
            try pumpBody(stream, &buf, head, timeout_ms, &err_out, appendBoundedError);
            return .{
                .status = head.status,
                .error_body = try err_out.toOwnedSlice(),
                .allocator = self.allocator,
            };
        }

        try pumpBody(stream, &buf, head, timeout_ms, ctx, on_chunk);
        return .{ .status = head.status, .error_body = &.{}, .allocator = self.allocator };
    }

    /// Opens a `Connection: Upgrade` / `Upgrade: tcp` connection on the Unix
    /// socket (used for HTTP `101 Switching Protocols` in `run -it` / `exec -it`).
    pub fn upgrade(
        self: Client,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        timeout_ms: i32,
    ) !UpgradedConn {
        const stream = try self.connectAndSend(method, path, body, true, "application/json");
        errdefer stream.close();

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const header_end = try readHeaderBlock(stream, &buf, timeout_ms);
        const head = try parseResponseHead(buf.items[0..header_end]);
        const rest_start = header_end + 4;
        const leftover = buf.items[rest_start..];

        if (head.status == 101 or (head.status >= 200 and head.status < 300)) {
            const initial: []u8 = if (leftover.len > 0) try self.allocator.dupe(u8, leftover) else &.{};
            return .{
                .stream = stream,
                .status = head.status,
                .initial_data = initial,
                .error_body = &.{},
                .allocator = self.allocator,
            };
        }

        const leftover_len = leftover.len;
        if (leftover_len > 0) std.mem.copyForwards(u8, buf.items[0..leftover_len], leftover);
        buf.items.len = leftover_len;

        var err_out = std.ArrayList(u8).init(self.allocator);
        errdefer err_out.deinit();
        try pumpBody(stream, &buf, head, timeout_ms, &err_out, appendBoundedError);
        return .{
            .stream = stream,
            .status = head.status,
            .initial_data = &.{},
            .error_body = try err_out.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    fn connectAndSend(
        self: Client,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        is_upgrade: bool,
        content_type: []const u8,
    ) !std.net.Stream {
        try validateRequestTarget(path);

        const stream = std.net.connectUnixSocket(self.socket_path) catch |e| return switch (e) {
            error.FileNotFound => Error.SocketNotFound,
            error.ConnectionRefused => Error.DaemonNotRunning,
            error.PermissionDenied => Error.PermissionDenied,
            else => e,
        };
        errdefer stream.close();

        var req = std.ArrayList(u8).init(self.allocator);
        defer req.deinit();
        const w = req.writer();
        try w.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
        if (is_upgrade) {
            try w.writeAll("Host: d\r\nUser-Agent: zigpod/0.1\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n");
        } else {
            try w.writeAll("Host: d\r\nUser-Agent: zigpod/0.1\r\nAccept: application/json\r\nConnection: close\r\n");
        }
        if (body) |b| {
            try w.print("Content-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ content_type, b.len });
            try w.writeAll(b);
        } else {
            try w.writeAll("Content-Length: 0\r\n\r\n");
        }
        try stream.writeAll(req.items);
        return stream;
    }
};

fn appendBoundedError(out: *std.ArrayList(u8), chunk: []const u8) !void {
    const projected = std.math.add(usize, out.items.len, chunk.len) catch return Error.InvalidResponse;
    if (projected > max_response_bytes) return error.StreamTooLong;
    try out.appendSlice(chunk);
}

fn readHeaderBlock(stream: std.net.Stream, buf: *std.ArrayList(u8), timeout_ms: i32) !usize {
    var tmp: [4096]u8 = undefined;
    while (true) {
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |idx| return idx;
        if (buf.items.len >= max_header_bytes) return Error.InvalidResponse;
        try waitReadable(stream.handle, timeout_ms);
        const n = try stream.read(&tmp);
        if (n == 0) return Error.InvalidResponse;
        const projected = std.math.add(usize, buf.items.len, n) catch return Error.InvalidResponse;
        if (projected > max_header_bytes and std.mem.indexOf(u8, tmp[0..n], "\r\n\r\n") == null) {
            // Still allow if \r\n\r\n landed inside this read, otherwise reject oversized headers.
            try buf.appendSlice(tmp[0..n]);
            return std.mem.indexOf(u8, buf.items, "\r\n\r\n") orelse Error.InvalidResponse;
        }
        try buf.appendSlice(tmp[0..n]);
    }
}

fn pumpBody(
    stream: std.net.Stream,
    buf: *std.ArrayList(u8),
    head: ResponseHead,
    timeout_ms: i32,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !void {
    if (head.chunked) {
        try streamChunked(stream, buf, timeout_ms, ctx, on_chunk);
        return;
    }
    if (head.content_length) |cl| {
        var remaining = cl;
        if (buf.items.len > 0) {
            const take = @min(remaining, buf.items.len);
            if (take > 0) try on_chunk(ctx, buf.items[0..take]);
            remaining -= take;
        }
        var tmp: [16384]u8 = undefined;
        while (remaining > 0) {
            try waitReadable(stream.handle, timeout_ms);
            const want = @min(remaining, tmp.len);
            const n = try stream.read(tmp[0..want]);
            if (n == 0) return Error.InvalidResponse;
            try on_chunk(ctx, tmp[0..n]);
            remaining -= n;
        }
        return;
    }

    if (buf.items.len > 0) {
        try on_chunk(ctx, buf.items);
    }
    var tmp: [16384]u8 = undefined;
    while (true) {
        try waitReadable(stream.handle, timeout_ms);
        const n = try stream.read(&tmp);
        if (n == 0) break;
        try on_chunk(ctx, tmp[0..n]);
    }
}

fn streamChunked(
    stream: std.net.Stream,
    buf: *std.ArrayList(u8),
    timeout_ms: i32,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !void {
    var tmp: [16384]u8 = undefined;
    var pos: usize = 0;

    while (true) {
        // Ensure a complete chunk-size line ending in `\r\n`.
        const line_end = while (true) {
            if (std.mem.indexOfPos(u8, buf.items, pos, "\r\n")) |idx| break idx;
            // Compact consumed prefix before reading more.
            if (pos > 0) {
                const rem = buf.items.len - pos;
                if (rem > 0) std.mem.copyForwards(u8, buf.items[0..rem], buf.items[pos..]);
                buf.items.len = rem;
                pos = 0;
            }
            if (buf.items.len >= 4096) return Error.InvalidResponse;
            try waitReadable(stream.handle, timeout_ms);
            const n = try stream.read(&tmp);
            if (n == 0) return Error.InvalidResponse;
            try buf.appendSlice(tmp[0..n]);
        };

        var size_str = buf.items[pos..line_end];
        if (std.mem.indexOfScalar(u8, size_str, ';')) |semi| size_str = size_str[0..semi];
        const trimmed_size = std.mem.trim(u8, size_str, " \t");
        if (trimmed_size.len == 0) return Error.InvalidResponse;
        const chunk_size = std.fmt.parseInt(usize, trimmed_size, 16) catch return Error.InvalidResponse;
        pos = line_end + 2;

        if (chunk_size == 0) {
            // Require trailing `\r\n` after `0\r\n`.
            while (buf.items.len - pos < 2) {
                try waitReadable(stream.handle, timeout_ms);
                const n = try stream.read(&tmp);
                if (n == 0) return Error.InvalidResponse;
                try buf.appendSlice(tmp[0..n]);
            }
            if (!std.mem.eql(u8, buf.items[pos .. pos + 2], "\r\n")) return Error.InvalidResponse;
            return;
        }

        // Stream chunk payload directly without buffering the entire chunk in memory.
        var remaining = chunk_size;
        const avail = buf.items.len - pos;
        if (avail > 0) {
            const take = @min(remaining, avail);
            try on_chunk(ctx, buf.items[pos .. pos + take]);
            pos = std.math.add(usize, pos, take) catch return Error.InvalidResponse;
            remaining -= take;
        }
        while (remaining > 0) {
            try waitReadable(stream.handle, timeout_ms);
            const want = @min(remaining, tmp.len);
            const n = try stream.read(tmp[0..want]);
            if (n == 0) return Error.InvalidResponse;
            try on_chunk(ctx, tmp[0..n]);
            remaining -= n;
        }

        // Consume and validate the `\r\n` chunk trailer.
        while (buf.items.len - pos < 2) {
            if (pos > 0 and pos == buf.items.len) {
                buf.items.len = 0;
                pos = 0;
            }
            try waitReadable(stream.handle, timeout_ms);
            const n = try stream.read(&tmp);
            if (n == 0) return Error.InvalidResponse;
            try buf.appendSlice(tmp[0..n]);
        }
        const trailer_end = std.math.add(usize, pos, 2) catch return Error.InvalidResponse;
        if (!std.mem.eql(u8, buf.items[pos..trailer_end], "\r\n")) return Error.InvalidResponse;
        pos = trailer_end;
    }
}

// ---------------------------------------------------------------- tests

test {
    _ = types;
    _ = parser;
}

const MockHttpCtx = struct {
    server: *std.net.Server,
    response: []const u8,
    captured_req: [1024]u8 = undefined,
    captured_len: usize = 0,
};

fn runMockHttpServer(ctx: *MockHttpCtx) void {
    const conn = ctx.server.accept() catch return;
    defer conn.stream.close();

    var total: usize = 0;
    while (total < ctx.captured_req.len) {
        const n = conn.stream.read(ctx.captured_req[total..]) catch return;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, ctx.captured_req[0..total], "\r\n\r\n") != null) break;
    }
    ctx.captured_len = total;
    conn.stream.writeAll(ctx.response) catch {};
}

test "Client.request round-trip over mock Unix socket with chunked response" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-http-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    var ctx = MockHttpCtx{
        .server = &server,
        .response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{\"Status\":\"ok\"}\n\r\n0\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, runMockHttpServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
    };
    const resp = try client.request("GET", "/v1.40/_ping", null);
    defer resp.deinit();

    thread.join();
    joined = true;

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"Status\":\"ok\"}\n", resp.body);
    try std.testing.expect(std.mem.startsWith(u8, ctx.captured_req[0..ctx.captured_len], "GET /v1.40/_ping HTTP/1.1\r\n"));
}

fn runSlowMockServer(server: *std.net.Server) void {
    const conn = server.accept() catch return;
    defer conn.stream.close();
    std.time.sleep(100 * std.time.ns_per_ms);
}

test "Client.request returns Error.Timeout when server does not respond" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-http-timeout-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, runSlowMockServer, .{&server});
    defer thread.join();

    const client = Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .timeout_ms = 20,
    };
    try std.testing.expectError(Error.Timeout, client.request("GET", "/v1.40/_ping", null));
}

const PartialStallCtx = struct {
    server: *std.net.Server,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// BUG-007 regression: sends a complete header plus a partial body, then
/// stalls without closing the connection. The old implementation blocked
/// forever inside `readAllAlloc` because the timeout only covered the first
/// byte; the new per-read poll must raise `Error.Timeout`.
fn runPartialStallServer(ctx: *PartialStallCtx) void {
    const conn = ctx.server.accept() catch return;
    defer conn.stream.close();
    conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nabcd") catch return;
    while (!ctx.done.load(.acquire)) {
        std.time.sleep(2 * std.time.ns_per_ms);
    }
}

test "Client.request times out when response stream stalls mid-body" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-http-stall-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    var ctx = PartialStallCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runPartialStallServer, .{&ctx});
    var joined = false;
    defer {
        ctx.done.store(true, .release);
        if (!joined) thread.join();
    }

    const client = Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .timeout_ms = 30,
    };
    try std.testing.expectError(Error.Timeout, client.request("GET", "/v1.40/_ping", null));

    ctx.done.store(true, .release);
    thread.join();
    joined = true;
}

fn runDelayedServer(server: *std.net.Server) void {
    const conn = server.accept() catch return;
    defer conn.stream.close();
    // Drain the request first: closing with unread data pending makes the
    // kernel send RST instead of a clean FIN.
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = conn.stream.read(buf[total..]) catch return;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    std.time.sleep(150 * std.time.ns_per_ms);
    conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch {};
}

test "requestWithTimeout overrides short client default for blocking endpoints" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-http-delayed-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, runDelayedServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .timeout_ms = 30,
    };
    // Default timeout would fail; the explicit long timeout must succeed.
    const resp = try client.requestWithTimeout("GET", "/v1.40/_ping", null, 10_000);
    defer resp.deinit();

    thread.join();
    joined = true;

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("ok", resp.body);
}

fn runStreamMockServer(server: *std.net.Server) void {
    // 1) Chunked response sent in multiple parts
    if (server.accept()) |conn| {
        defer conn.stream.close();
        var req_buf: [512]u8 = undefined;
        _ = conn.stream.read(&req_buf) catch {};
        conn.stream.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello") catch {};
        std.time.sleep(10 * std.time.ns_per_ms);
        conn.stream.writeAll("\r\n6\r\n world\r\n0\r\n\r\n") catch {};
    } else |_| {}

    // 2) 404 error body
    if (server.accept()) |conn| {
        defer conn.stream.close();
        var req_buf: [512]u8 = undefined;
        _ = conn.stream.read(&req_buf) catch {};
        conn.stream.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found") catch {};
    } else |_| {}

    // 3) HTTP 101 upgrade with initial payload and echo
    if (server.accept()) |conn| {
        defer conn.stream.close();
        var req_buf: [512]u8 = undefined;
        _ = conn.stream.read(&req_buf) catch {};
        conn.stream.writeAll("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nbanner:") catch {};
        var in_buf: [64]u8 = undefined;
        const n = conn.stream.read(&in_buf) catch 0;
        if (n > 0) conn.stream.writeAll(in_buf[0..n]) catch {};
    } else |_| {}
}

fn collectStreamChunk(out: *std.ArrayList(u8), slice: []const u8) !void {
    try out.appendSlice(slice);
}

test "streamRequest handles chunked streaming, error bodies, and 101 upgrade" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-http-stream-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer std.testing.allocator.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, runStreamMockServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .timeout_ms = 5_000,
    };

    // 1) Chunked stream
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    const sresp = try client.streamRequest("GET", "/v1.40/containers/c1/logs?follow=1", null, 5_000, &out, collectStreamChunk);
    defer sresp.deinit();
    try std.testing.expect(sresp.ok());
    try std.testing.expectEqualStrings("hello world", out.items);

    // 2) Error body
    var err_out = std.ArrayList(u8).init(std.testing.allocator);
    defer err_out.deinit();
    const eresp = try client.streamRequest("GET", "/v1.40/containers/missing/logs", null, 5_000, &err_out, collectStreamChunk);
    defer eresp.deinit();
    try std.testing.expectEqual(@as(u16, 404), eresp.status);
    try std.testing.expectEqualStrings("not found", eresp.error_body);
    try std.testing.expectEqual(@as(usize, 0), err_out.items.len);

    // 3) 101 Switching Protocols upgrade
    const up = try client.upgrade("POST", "/v1.40/exec/e1/start", "{\"Detach\":false,\"Tty\":true}", 5_000);
    defer up.deinit();
    try std.testing.expectEqual(@as(u16, 101), up.status);
    try std.testing.expectEqualStrings("banner:", up.initial_data);
    try up.stream.writeAll("ping");
    var echo_buf: [16]u8 = undefined;
    const n = try up.stream.read(&echo_buf);
    try std.testing.expectEqualStrings("ping", echo_buf[0..n]);

    // RawTermGuard on a non-TTY pipe must be a safe no-op.
    const pipe_fds = try std.posix.pipe();
    defer {
        std.posix.close(pipe_fds[0]);
        std.posix.close(pipe_fds[1]);
    }
    var guard = RawTermGuard.enter(pipe_fds[0]);
    try std.testing.expect(!guard.active);
    guard.restore();

    thread.join();
    joined = true;
}
