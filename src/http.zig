//! Minimal HTTP/1.1 client over a Unix domain socket.
//! One request per connection ("Connection: close"); supports Content-Length
//! and chunked transfer encoding. That's all the Podman API needs.
const std = @import("std");

/// Upper bound on a response body (image pulls stream a lot of progress JSON).
pub const max_response_bytes = 64 * 1024 * 1024;
pub const default_timeout_ms: i32 = 30_000;

pub const Error = error{
    SocketNotFound,
    DaemonNotRunning,
    PermissionDenied,
    InvalidResponse,
    InvalidRequestPath,
    Timeout,
};

pub const Response = struct {
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.body);
    }

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

/// Rejects malformed or CRLF/whitespace-containing HTTP request targets.
pub fn validateRequestTarget(path: []const u8) Error!void {
    if (path.len == 0 or path[0] != '/') return Error.InvalidRequestPath;
    for (path) |c| {
        if (c <= 0x20 or c == 0x7f) return Error.InvalidRequestPath;
    }
}

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

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    timeout_ms: i32 = default_timeout_ms,

    pub fn request(self: Client, method: []const u8, path: []const u8, body: ?[]const u8) !Response {
        try validateRequestTarget(path);

        const stream = std.net.connectUnixSocket(self.socket_path) catch |e| return switch (e) {
            error.FileNotFound => Error.SocketNotFound,
            error.ConnectionRefused => Error.DaemonNotRunning,
            error.PermissionDenied => Error.PermissionDenied,
            else => e,
        };
        defer stream.close();

        // Build the whole request in memory, then send it in one write.
        var req = std.ArrayList(u8).init(self.allocator);
        defer req.deinit();
        const w = req.writer();
        try w.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
        try w.writeAll("Host: d\r\nUser-Agent: zigpod/0.1\r\nAccept: application/json\r\nConnection: close\r\n");
        if (body) |b| {
            try w.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{b.len});
            try w.writeAll(b);
        } else {
            try w.writeAll("Content-Length: 0\r\n\r\n");
        }
        try stream.writeAll(req.items);

        try waitReadable(stream.handle, self.timeout_ms);
        const raw = try stream.reader().readAllAlloc(self.allocator, max_response_bytes);
        defer self.allocator.free(raw);
        return parseResponse(self.allocator, raw);
    }
};

/// Parses a complete raw HTTP/1.1 response. The returned body is owned by the caller.
pub fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) !Response {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return Error.InvalidResponse;
    const head = raw[0..header_end];
    const rest = raw[header_end + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return Error.InvalidResponse;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    const proto = parts.next() orelse return Error.InvalidResponse;
    if (!std.mem.startsWith(u8, proto, "HTTP/")) return Error.InvalidResponse;
    const code = parts.next() orelse return Error.InvalidResponse;
    const status = std.fmt.parseInt(u16, code, 10) catch return Error.InvalidResponse;

    var chunked = false;
    var content_length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidResponse;
        }
    }

    const body = if (chunked)
        try decodeChunked(allocator, rest)
    else if (content_length) |cl| blk: {
        if (cl > max_response_bytes or cl > rest.len) return Error.InvalidResponse;
        break :blk try allocator.dupe(u8, rest[0..cl]);
    } else try allocator.dupe(u8, rest);

    return .{ .status = status, .body = body, .allocator = allocator };
}

fn decodeChunked(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var pos: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, data, pos, "\r\n") orelse return Error.InvalidResponse;
        var size_str = data[pos..line_end];
        if (std.mem.indexOfScalar(u8, size_str, ';')) |semi| size_str = size_str[0..semi]; // chunk extensions
        const trimmed_size = std.mem.trim(u8, size_str, " \t");
        if (trimmed_size.len == 0) return Error.InvalidResponse;
        const size = std.fmt.parseInt(usize, trimmed_size, 16) catch return Error.InvalidResponse;
        pos = line_end + 2;
        if (size == 0) {
            const term_end = std.math.add(usize, pos, 2) catch return Error.InvalidResponse;
            if (term_end > data.len) return Error.InvalidResponse;
            break;
        }
        if (size > max_response_bytes or out.items.len + size > max_response_bytes) {
            return Error.InvalidResponse;
        }
        const data_end = std.math.add(usize, pos, size) catch return Error.InvalidResponse;
        const after_data = std.math.add(usize, data_end, 2) catch return Error.InvalidResponse;
        if (after_data > data.len) return Error.InvalidResponse;
        if (!std.mem.eql(u8, data[data_end..after_data], "\r\n")) return Error.InvalidResponse;
        try out.appendSlice(data[pos..data_end]);
        pos = after_data;
    }
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------- tests

test "parse content-length response" {
    const raw = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"Id\":\"ab\"}";
    const resp = try parseResponse(std.testing.allocator, raw);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expectEqualStrings("{\"Id\":\"ab\"}", resp.body);
    try std.testing.expect(resp.ok());
}

test "parse chunked response" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n";
    const resp = try parseResponse(std.testing.allocator, raw);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello world", resp.body);
}

test "parse no-content response" {
    const raw = "HTTP/1.1 204 No Content\r\n\r\n";
    const resp = try parseResponse(std.testing.allocator, raw);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 204), resp.status);
    try std.testing.expectEqual(@as(usize, 0), resp.body.len);
}

test "case-insensitive headers and malformed content-length" {
    const ok_raw = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nokextra";
    const resp = try parseResponse(std.testing.allocator, ok_raw);
    defer resp.deinit();
    try std.testing.expectEqualStrings("ok", resp.body);

    try std.testing.expectError(Error.InvalidResponse, parseResponse(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\nhi"));
    try std.testing.expectError(Error.InvalidResponse, parseResponse(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nhi"));
}

test "reject malformed chunked responses without panic or leaks" {
    // Huge chunk size (potential integer overflow)
    try std.testing.expectError(Error.InvalidResponse, parseResponse(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\nhi\r\n0\r\n\r\n",
    ));
    // Truncated chunk payload missing trailing CRLF
    try std.testing.expectError(Error.InvalidResponse, parseResponse(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello",
    ));
    // Wrong chunk trailer (XX instead of CRLF)
    try std.testing.expectError(Error.InvalidResponse, parseResponse(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n",
    ));
    // Invalid / negative hex size
    try std.testing.expectError(Error.InvalidResponse, parseResponse(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n",
    ));
    // Empty chunk size line
    try std.testing.expectError(Error.InvalidResponse, parseResponse(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\nhello\r\n0\r\n\r\n",
    ));
    // Missing terminal zero chunk
    try std.testing.expectError(Error.InvalidResponse, parseResponse(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n",
    ));
    // Truncated after terminal zero chunk
    try std.testing.expectError(Error.InvalidResponse, parseResponse(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
    ));
}

test "reject garbage responses" {
    try std.testing.expectError(Error.InvalidResponse, parseResponse(std.testing.allocator, "nope"));
    try std.testing.expectError(Error.InvalidResponse, parseResponse(std.testing.allocator, "FOO 200\r\n\r\n"));
    try std.testing.expectError(Error.InvalidResponse, parseResponse(std.testing.allocator, "HTTP/1.1 bad\r\n\r\n"));
}

test "validateRequestTarget prevents CRLF and path injection" {
    try validateRequestTarget("/v1.40/containers/json?all=true");
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget(""));
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("v1.40/containers/json"));
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/\r\nX-Injected: 1"));
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/a b"));
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/\x00"));
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
