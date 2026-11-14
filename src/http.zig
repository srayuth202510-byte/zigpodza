//! Minimal HTTP/1.1 client over a Unix domain socket.
//! One request per connection ("Connection: close"); supports Content-Length
//! and chunked transfer encoding. That's all the Podman API needs.
const std = @import("std");

/// Upper bound on a response body (image pulls stream a lot of progress JSON).
pub const max_response_bytes = 64 * 1024 * 1024;

pub const Error = error{
    SocketNotFound,
    DaemonNotRunning,
    PermissionDenied,
    InvalidResponse,
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

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    pub fn request(self: Client, method: []const u8, path: []const u8, body: ?[]const u8) !Response {
        const stream = std.net.connectUnixSocket(self.socket_path) catch |e| return switch (e) {
            error.FileNotFound => Error.SocketNotFound,
            error.ConnectionRefused => Error.DaemonNotRunning,
            error.AccessDenied, error.PermissionDenied => Error.PermissionDenied,
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
    else blk: {
        const n = if (content_length) |cl| @min(cl, rest.len) else rest.len;
        break :blk try allocator.dupe(u8, rest[0..n]);
    };
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
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_str, " \t"), 16) catch return Error.InvalidResponse;
        pos = line_end + 2;
        if (size == 0) break;
        if (pos + size > data.len) return Error.InvalidResponse;
        try out.appendSlice(data[pos .. pos + size]);
        pos += size + 2; // skip chunk data + CRLF
    }
    return out.toOwnedSlice();
}

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

test "reject garbage" {
    try std.testing.expectError(Error.InvalidResponse, parseResponse(std.testing.allocator, "nope"));
    try std.testing.expectError(Error.InvalidResponse, parseResponse(std.testing.allocator, "FOO 200\r\n\r\n"));
}
