//! Minimal HTTP/1.1 client over a Unix domain socket.
//! One request per connection ("Connection: close"); supports Content-Length
//! and chunked transfer encoding. That's all the Podman API needs.
//! Zig 0.17: all socket I/O goes through an explicit `std.Io` instance with
//! deadline-based `operateTimeout` so every read/write respects the caller's
//! timeout (BUG-007/BUG-037 semantics preserved).
const std = @import("std");
const Io = std.Io;
const Clock = Io.Clock;
pub const types = @import("http_types.zig");
pub const parser = @import("http_parser.zig");

pub const max_response_bytes = types.max_response_bytes;
pub const max_header_bytes = types.max_header_bytes;
pub const default_timeout_ms = types.default_timeout_ms;
pub const interactive_timeout_ms = types.interactive_timeout_ms;
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

pub const socket = @import("http_socket.zig");
pub const Socket = Io.net.Stream;
pub const Deadline = socket.Deadline;

/// Reads the full response until EOF, enforcing `timeout_ms` on *every* read
/// (not just the first byte) so a daemon that stalls mid-response cannot hang
/// the process forever (BUG-007).
fn readAllWithTimeout(
    io: Io,
    handle: Io.net.Socket.Handle,
    allocator: std.mem.Allocator,
    max_size: usize,
    deadline: Deadline,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = try socket.socketRead(io, handle, &chunk, deadline);
        if (n == 0) break; // EOF: server honored "Connection: close"
        try out.appendSlice(allocator, chunk[0..n]);
        if (out.items.len > max_size) return error.StreamTooLong;
    }
    return out.toOwnedSlice(allocator);
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    timeout_ms: i32 = default_timeout_ms,
    io: Io,

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
        const stream = try self.connectAndSend(method, path, body, false, content_type, timeout_ms);
        defer stream.close(self.io);

        const raw = try readAllWithTimeout(self.io, stream.socket.handle, self.allocator, max_response_bytes, Deadline.fromMs(self.io, timeout_ms));
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
        const stream = try self.connectAndSend(method, path, body, false, "application/json", timeout_ms);
        defer stream.close(self.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        const header_end = try readHeaderBlock(self.io, stream.socket.handle, self.allocator, &buf, Deadline.fromMs(self.io, timeout_ms));
        const head = try parseResponseHead(buf.items[0..header_end]);
        const rest_start = header_end + 4;

        // Compact `buf` so only initial body bytes remain at index 0.
        const leftover_len = buf.items.len - rest_start;
        if (leftover_len > 0) {
            std.mem.copyForwards(u8, buf.items[0..leftover_len], buf.items[rest_start..]);
        }
        buf.items.len = leftover_len;

        if (head.status < 200 or head.status >= 300) {
            var err_out: std.ArrayList(u8) = .empty;
            errdefer err_out.deinit(self.allocator);
            try pumpBody(self.io, stream.socket.handle, self.allocator, &buf, head, Deadline.fromMs(self.io, timeout_ms), BoundedErrorSink{ .allocator = self.allocator, .out = &err_out }, BoundedErrorSink.append);
            return .{
                .status = head.status,
                .error_body = try err_out.toOwnedSlice(self.allocator),
                .allocator = self.allocator,
            };
        }

        try pumpBody(self.io, stream.socket.handle, self.allocator, &buf, head, Deadline.fromMs(self.io, timeout_ms), ctx, on_chunk);
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
        const stream = try self.connectAndSend(method, path, body, true, "application/json", timeout_ms);
        errdefer stream.close(self.io);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        const header_end = try readHeaderBlock(self.io, stream.socket.handle, self.allocator, &buf, Deadline.fromMs(self.io, timeout_ms));
        const head = try parseResponseHead(buf.items[0..header_end]);
        const rest_start = header_end + 4;
        const leftover = buf.items[rest_start..];

        if (head.status == 101 or (head.status >= 200 and head.status < 300)) {
            const initial: []u8 = if (leftover.len > 0) try self.allocator.dupe(u8, leftover) else &.{};
            return .{
                .stream = stream,
                .io = self.io,
                .status = head.status,
                .initial_data = initial,
                .error_body = &.{},
                .allocator = self.allocator,
            };
        }

        const leftover_len = leftover.len;
        if (leftover_len > 0) std.mem.copyForwards(u8, buf.items[0..leftover_len], leftover);
        buf.items.len = leftover_len;

        var err_out: std.ArrayList(u8) = .empty;
        errdefer err_out.deinit(self.allocator);
        try pumpBody(self.io, stream.socket.handle, self.allocator, &buf, head, Deadline.fromMs(self.io, timeout_ms), BoundedErrorSink{ .allocator = self.allocator, .out = &err_out }, BoundedErrorSink.append);
        return .{
            .stream = stream,
            .io = self.io,
            .status = head.status,
            .initial_data = &.{},
            .error_body = try err_out.toOwnedSlice(self.allocator),
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
        timeout_ms: i32,
    ) !Socket {
        try validateRequestTarget(path);

        const addr = std.Io.net.UnixAddress.init(self.socket_path) catch |e| switch (e) {
            error.NameTooLong => return Error.SocketNotFound,
        };
        const stream = addr.connect(self.io) catch |e| return switch (e) {
            error.FileNotFound => Error.SocketNotFound,
            error.ConnectionRefused => Error.DaemonNotRunning,
            error.PermissionDenied, error.AccessDenied => Error.PermissionDenied,
            else => e,
        };
        errdefer stream.close(self.io);
        socket.setNonBlocking(stream.socket.handle);

        var req: Io.Writer.Allocating = .init(self.allocator);
        defer req.deinit();
        const w = &req.writer;
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
        try socket.socketWriteAll(self.io, stream.socket.handle, req.written(), Deadline.fromMs(self.io, timeout_ms));
        return stream;
    }
};

const BoundedErrorSink = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),

    fn append(sink: BoundedErrorSink, chunk: []const u8) !void {
        const projected = std.math.add(usize, sink.out.items.len, chunk.len) catch return Error.InvalidResponse;
        if (projected > max_response_bytes) return error.StreamTooLong;
        try sink.out.appendSlice(sink.allocator, chunk);
    }
};

fn readHeaderBlock(io: Io, handle: Io.net.Socket.Handle, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), deadline: Deadline) !usize {
    var tmp: [4096]u8 = undefined;
    while (true) {
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |idx| return idx;
        if (buf.items.len >= max_header_bytes) return Error.InvalidResponse;
        const n = try socket.socketRead(io, handle, &tmp, deadline);
        if (n == 0) return Error.InvalidResponse;
        const projected = std.math.add(usize, buf.items.len, n) catch return Error.InvalidResponse;
        if (projected > max_header_bytes and std.mem.indexOf(u8, tmp[0..n], "\r\n\r\n") == null) {
            // Still allow if \r\n\r\n landed inside this read, otherwise reject oversized headers.
            try buf.appendSlice(allocator, tmp[0..n]);
            return std.mem.indexOf(u8, buf.items, "\r\n\r\n") orelse Error.InvalidResponse;
        }
        try buf.appendSlice(allocator, tmp[0..n]);
    }
}

fn pumpBody(
    io: Io,
    handle: Io.net.Socket.Handle,
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    head: ResponseHead,
    deadline: Deadline,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) anyerror!void,
) !void {
    if (head.chunked) {
        try streamChunked(io, handle, allocator, buf, deadline, ctx, on_chunk);
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
            const want = @min(remaining, tmp.len);
            const n = try socket.socketRead(io, handle, tmp[0..want], deadline);
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
        const n = try socket.socketRead(io, handle, &tmp, deadline);
        if (n == 0) break;
        try on_chunk(ctx, tmp[0..n]);
    }
}

fn streamChunked(
    io: Io,
    handle: Io.net.Socket.Handle,
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    deadline: Deadline,
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
            const n = try socket.socketRead(io, handle, &tmp, deadline);
            if (n == 0) return Error.InvalidResponse;
            try buf.appendSlice(allocator, tmp[0..n]);
        };

        var size_str = buf.items[pos..line_end];
        if (std.mem.indexOfScalar(u8, size_str, ';')) |semi| size_str = size_str[0..semi];
        const trimmed_size = std.mem.trim(u8, size_str, " \t");
        if (trimmed_size.len == 0) return Error.InvalidResponse;
        const chunk_size = std.fmt.parseInt(usize, trimmed_size, 16) catch return Error.InvalidResponse;
        pos = line_end + 2;

        if (chunk_size == 0) {
            // Require trailing `\r\n` (empty trailer) or valid trailer section ending in `\r\n\r\n`.
            while (true) {
                if (buf.items.len - pos >= 2 and std.mem.eql(u8, buf.items[pos .. pos + 2], "\r\n")) {
                    return;
                }
                if (std.mem.indexOfPos(u8, buf.items, pos, "\r\n\r\n")) |_| {
                    return;
                }
                if (buf.items.len - pos >= max_header_bytes) return Error.InvalidResponse;
                const n = try socket.socketRead(io, handle, &tmp, deadline);
                if (n == 0) return Error.InvalidResponse;
                try buf.appendSlice(allocator, tmp[0..n]);
            }
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
            const want = @min(remaining, tmp.len);
            const n = try socket.socketRead(io, handle, tmp[0..want], deadline);
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
            const n = try socket.socketRead(io, handle, &tmp, deadline);
            if (n == 0) return Error.InvalidResponse;
            try buf.appendSlice(allocator, tmp[0..n]);
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

const test_io = std.testing.io;

const MockHttpCtx = struct {
    server: *Io.net.Server,
    response: []const u8,
    captured_req: [1024]u8 = undefined,
    captured_len: usize = 0,
};

fn runMockHttpServer(ctx: *MockHttpCtx) void {
    const conn = ctx.server.accept(test_io) catch return;
    defer conn.close(test_io);

    var total: usize = 0;
    while (total < ctx.captured_req.len) {
        var data = [_][]u8{ctx.captured_req[total..]};
        const n = conn.read(test_io, &data) catch return;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, ctx.captured_req[0..total], "\r\n\r\n") != null) break;
    }
    ctx.captured_len = total;
    socket.socketWriteAll(test_io, conn.socket.handle, ctx.response, .{ .ts = null }) catch {};
}

test "Client.request round-trip over mock Unix socket with chunked response" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-http-{d}.sock", .{Io.Clock.awake.now(test_io).nanoseconds});
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    var ctx = MockHttpCtx{
        .server = &server,
        .response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{\"Status\":\"ok\"}\n\r\n0\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, runMockHttpServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = test_io,
    };
    const resp = try client.request("GET", "/v1.40/_ping", null);
    defer resp.deinit();

    thread.join();
    joined = true;

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"Status\":\"ok\"}\n", resp.body);
    try std.testing.expect(std.mem.startsWith(u8, ctx.captured_req[0..ctx.captured_len], "GET /v1.40/_ping HTTP/1.1\r\n"));
}

fn runSlowMockServer(server: *Io.net.Server) void {
    const conn = server.accept(test_io) catch return;
    defer conn.close(test_io);
    test_io.sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
}

test "Client.request returns Error.Timeout when server does not respond" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-http-timeout-{d}.sock", .{Io.Clock.awake.now(test_io).nanoseconds});
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const thread = try std.Thread.spawn(.{}, runSlowMockServer, .{&server});
    defer thread.join();

    const client = Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .timeout_ms = 20,
        .io = test_io,
    };
    try std.testing.expectError(Error.Timeout, client.request("GET", "/v1.40/_ping", null));
}

const PartialStallCtx = struct {
    server: *Io.net.Server,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// BUG-007 regression: sends a complete header plus a partial body, then
/// stalls without closing the connection. The old implementation blocked
/// forever inside `readAllAlloc` because the timeout only covered the first
/// byte; the new per-read deadline must raise `Error.Timeout`.
fn runPartialStallServer(ctx: *PartialStallCtx) void {
    const conn = ctx.server.accept(test_io) catch return;
    defer conn.close(test_io);
    socket.socketWriteAll(test_io, conn.socket.handle, "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nabcd", .{ .ts = null }) catch return;
    while (!ctx.done.load(.acquire)) {
        test_io.sleep(.fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
    }
}

test "Client.request times out when response stream stalls mid-body" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-http-stall-{d}.sock", .{Io.Clock.awake.now(test_io).nanoseconds});
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    var ctx = PartialStallCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runPartialStallServer, .{&ctx});
    var joined = false;
    defer {
        ctx.done.store(true, .release);
        if (!joined) thread.join();
    }

    const client = Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .timeout_ms = 30,
        .io = test_io,
    };
    try std.testing.expectError(Error.Timeout, client.request("GET", "/v1.40/_ping", null));

    ctx.done.store(true, .release);
    thread.join();
    joined = true;
}

fn runDelayedServer(server: *Io.net.Server) void {
    const conn = server.accept(test_io) catch return;
    defer conn.close(test_io);
    // Drain the request first: closing with unread data pending makes the
    // kernel send RST instead of a clean FIN.
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        var data = [_][]u8{buf[total..]};
        const n = conn.read(test_io, &data) catch return;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    test_io.sleep(.fromNanoseconds(150 * std.time.ns_per_ms), .awake) catch {};
    socket.socketWriteAll(test_io, conn.socket.handle, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .{ .ts = null }) catch {};
}

test "requestWithTimeout overrides short client default for blocking endpoints" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-http-delayed-{d}.sock", .{Io.Clock.awake.now(test_io).nanoseconds});
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const thread = try std.Thread.spawn(.{}, runDelayedServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .timeout_ms = 30,
        .io = test_io,
    };
    // Default timeout would fail; the explicit long timeout must succeed.
    const resp = try client.requestWithTimeout("GET", "/v1.40/_ping", null, 10_000);
    defer resp.deinit();

    thread.join();
    joined = true;

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("ok", resp.body);
}

fn runStreamMockServer(server: *Io.net.Server) void {
    // 1) Chunked response sent in multiple parts
    if (server.accept(test_io)) |conn| {
        defer conn.close(test_io);
        var req_buf: [512]u8 = undefined;
        var data = [_][]u8{&req_buf};
        _ = conn.read(test_io, &data) catch {};
        socket.socketWriteAll(test_io, conn.socket.handle, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello", .{ .ts = null }) catch {};
        test_io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
        socket.socketWriteAll(test_io, conn.socket.handle, "\r\n6\r\n world\r\n0\r\n\r\n", .{ .ts = null }) catch {};
    } else |_| {}

    // 2) 404 error body
    if (server.accept(test_io)) |conn| {
        defer conn.close(test_io);
        var req_buf: [512]u8 = undefined;
        var data = [_][]u8{&req_buf};
        _ = conn.read(test_io, &data) catch {};
        socket.socketWriteAll(test_io, conn.socket.handle, "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found", .{ .ts = null }) catch {};
    } else |_| {}

    // 3) HTTP 101 upgrade with initial payload and echo
    if (server.accept(test_io)) |conn| {
        defer conn.close(test_io);
        var req_buf: [512]u8 = undefined;
        var data = [_][]u8{&req_buf};
        _ = conn.read(test_io, &data) catch {};
        socket.socketWriteAll(test_io, conn.socket.handle, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nbanner:", .{ .ts = null }) catch {};
        var in_buf: [64]u8 = undefined;
        var echo_data = [_][]u8{&in_buf};
        const n = conn.read(test_io, &echo_data) catch 0;
        if (n > 0) socket.socketWriteAll(test_io, conn.socket.handle, in_buf[0..n], .{ .ts = null }) catch {};
    } else |_| {}
}

fn collectStreamChunk(out: *std.ArrayList(u8), slice: []const u8) !void {
    try out.appendSlice(std.testing.allocator, slice);
}

test "streamRequest handles chunked streaming, error bodies, and 101 upgrade" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-http-stream-{d}.sock", .{Io.Clock.awake.now(test_io).nanoseconds});
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    const thread = try std.Thread.spawn(.{}, runStreamMockServer, .{&server});
    var joined = false;
    defer if (!joined) thread.join();

    const client = Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .timeout_ms = 5_000,
        .io = test_io,
    };

    // 1) Chunked stream
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const sresp = try client.streamRequest("GET", "/v1.40/containers/c1/logs?follow=1", null, 5_000, &out, collectStreamChunk);
    defer sresp.deinit();
    try std.testing.expect(sresp.ok());
    try std.testing.expectEqualStrings("hello world", out.items);

    // 2) Error body
    var err_out: std.ArrayList(u8) = .empty;
    defer err_out.deinit(alloc);
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
    try up.writeAll("ping");
    var echo_buf: [16]u8 = undefined;
    const n = try up.read(&echo_buf);
    try std.testing.expectEqualStrings("ping", echo_buf[0..n]);

    // RawTermGuard on a non-TTY pipe must be a safe no-op.
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.os.linux.pipe(&pipe_fds) == 0) {
        defer {
            _ = std.os.linux.close(pipe_fds[0]);
            _ = std.os.linux.close(pipe_fds[1]);
        }
        var guard = RawTermGuard.enter(pipe_fds[0]);
        try std.testing.expect(!guard.active);
        guard.restore();
    }

    thread.join();
    joined = true;
}

const WriteStallCtx = struct {
    server: *Io.net.Server,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bytes_per_tick: usize = 0,
    tick_ms: u64 = 2,
    received: usize = 0,
    expected_body_len: usize = 0,
    reply_on_done: bool = false,
};

fn runWriteStallServer(ctx: *WriteStallCtx) void {
    const conn = blk: {
        var fds = [_]std.posix.pollfd{.{
            .fd = ctx.server.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        while (!ctx.done.load(.acquire)) {
            const ready = std.posix.poll(&fds, 5) catch return;
            if (ready > 0) break;
        }
        if (ctx.done.load(.acquire)) return;
        break :blk ctx.server.accept(test_io) catch return;
    };
    defer conn.close(test_io);

    if (ctx.bytes_per_tick == 0) {
        // Accept without ever draining socket buffer so writer hits the write deadline.
        while (!ctx.done.load(.acquire)) {
            test_io.sleep(.fromNanoseconds(2 * std.time.ns_per_ms), .awake) catch {};
        }
        return;
    }

    var discard: [65536]u8 = undefined;
    var read_fds = [_]std.posix.pollfd{.{
        .fd = conn.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var expected_total: ?usize = null;
    var hdr_buf: [512]u8 = undefined;
    var hdr_len: usize = 0;

    while (!ctx.done.load(.acquire)) {
        const ready = std.posix.poll(&read_fds, 5) catch break;
        if (ready == 0) continue;
        if ((read_fds[0].revents & std.posix.POLL.IN) != 0) {
            const want = @min(ctx.bytes_per_tick, discard.len);
            var data = [_][]u8{discard[0..want]};
            const n = conn.read(test_io, &data) catch break;
            if (n == 0) break;
            if (expected_total == null) {
                const take = @min(n, hdr_buf.len - hdr_len);
                @memcpy(hdr_buf[hdr_len .. hdr_len + take], discard[0..take]);
                hdr_len += take;
                if (std.mem.indexOf(u8, hdr_buf[0..hdr_len], "\r\n\r\n")) |idx| {
                    expected_total = (idx + 4) + ctx.expected_body_len;
                }
            }
            ctx.received += n;
            if (ctx.reply_on_done) {
                if (expected_total) |exp| {
                    if (ctx.received >= exp) break;
                }
            }
            if (ctx.tick_ms > 0) test_io.sleep(.fromNanoseconds(@as(i96, @intCast(ctx.tick_ms)) * std.time.ns_per_ms), .awake) catch {};
        } else if ((read_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
            break;
        }
    }
    if (ctx.reply_on_done and !ctx.done.load(.acquire)) {
        const ok_body = "{\"ok\":true}";
        const resp = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ ok_body.len, ok_body });
        socket.socketWriteAll(test_io, conn.socket.handle, resp, .{ .ts = null }) catch {};
    }
}

fn runWriteStallCase(
    alloc: std.mem.Allocator,
    sock_tag: []const u8,
    payload: []const u8,
    timeout_ms: i32,
    bytes_per_tick: usize,
    tick_ms: u64,
    expect_timeout: bool,
) !void {
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-http-{s}-{d}.sock", .{ sock_tag, Io.Clock.awake.now(test_io).nanoseconds });
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(test_io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(test_io, .{});
    defer server.deinit(test_io);

    var ctx = WriteStallCtx{
        .server = &server,
        .bytes_per_tick = bytes_per_tick,
        .tick_ms = tick_ms,
        .expected_body_len = payload.len,
        .reply_on_done = !expect_timeout,
    };
    const thread = try std.Thread.spawn(.{}, runWriteStallServer, .{&ctx});
    var joined = false;
    defer {
        ctx.done.store(true, .release);
        if (!joined) thread.join();
    }

    const client = Client{ .allocator = alloc, .socket_path = sock_path, .timeout_ms = timeout_ms, .io = test_io };
    if (expect_timeout) {
        try std.testing.expectError(Error.Timeout, client.request("POST", "/v1.40/build", payload));
        ctx.done.store(true, .release);
        thread.join();
        joined = true;
    } else {
        const resp = try client.request("POST", "/v1.40/build", payload);
        defer resp.deinit();
        thread.join();
        joined = true;
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);
        try std.testing.expect(ctx.received > payload.len);
    }
}

test "BUG-037 regression: write deadlines bound stalled and slow-draining request writes" {
    const alloc = std.testing.allocator;
    const payload = try alloc.alloc(u8, 4 * 1024 * 1024);
    defer alloc.free(payload);
    @memset(payload, 'A');

    // 1) Peer accepts and never reads -> connectAndSend returns Error.Timeout.
    try runWriteStallCase(alloc, "wstall", payload, 25, 0, 2, true);
    // 2) Slow-draining peer (1 byte / 15ms) still hits the write deadline.
    try runWriteStallCase(alloc, "wslow", payload, 35, 1, 15, true);
    // 3) Normal draining peer completes multi-chunk write without timeout.
    try runWriteStallCase(alloc, "wok", payload, 5_000, 65536, 0, false);
}
