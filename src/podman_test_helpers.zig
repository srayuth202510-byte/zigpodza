//! Shared mock Unix-socket HTTP server helpers for Podman API tests.
const std = @import("std");

pub fn readHttpRequest(stream: std.net.Stream, buf: []u8) ![]const u8 {    var total: usize = 0;
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
