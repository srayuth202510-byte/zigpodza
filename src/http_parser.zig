//! HTTP/1.1 response header and chunked transfer-encoding parser.
const std = @import("std");
const t = @import("http_types.zig");

const max_response_bytes = t.max_response_bytes;
const Error = t.Error;
const Response = t.Response;
const ResponseHead = t.ResponseHead;
const validateRequestTarget = t.validateRequestTarget;

/// Parses an HTTP/1.1 response header block (excluding `\r\n\r\n`).
pub fn parseResponseHead(head: []const u8) !ResponseHead {
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

    return .{ .status = status, .chunked = chunked, .content_length = content_length };
}

/// Parses a complete raw HTTP/1.1 response. The returned body is owned by the caller.
pub fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) !Response {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return Error.InvalidResponse;
    const head = try parseResponseHead(raw[0..header_end]);
    const rest = raw[header_end + 4 ..];

    const body = if (head.chunked)
        try decodeChunked(allocator, rest)
    else if (head.content_length) |cl| blk: {
        if (cl > max_response_bytes or cl > rest.len) return Error.InvalidResponse;
        break :blk try allocator.dupe(u8, rest[0..cl]);
    } else try allocator.dupe(u8, rest);

    return .{ .status = head.status, .body = body, .allocator = allocator };
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
            if (std.mem.eql(u8, data[pos..term_end], "\r\n")) break;
            if (std.mem.indexOfPos(u8, data, pos, "\r\n\r\n") != null) break;
            return Error.InvalidResponse;
        }
        // BUG-010: the projected total must use checked arithmetic too — a
        // huge `size` combined with already-buffered bytes would overflow a
        // plain `+` in Debug/ReleaseSafe builds.
        const projected = std.math.add(usize, out.items.len, size) catch return Error.InvalidResponse;
        if (size > max_response_bytes or projected > max_response_bytes) {
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

test "fuzz parseResponse and decodeChunked with deterministic PRNG" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x51690d01);
    const rng = prng.random();

    // Part A: Round-trip property — random payloads encoded as arbitrarily split HTTP/1.1 chunks.
    var iter: usize = 0;
    while (iter < 48) : (iter += 1) {
        const payload_len = rng.intRangeAtMost(usize, 0, 256);
        const payload = try alloc.alloc(u8, payload_len);
        defer alloc.free(payload);
        rng.bytes(payload);

        var wire = std.ArrayList(u8).init(alloc);
        defer wire.deinit();
        try wire.appendSlice("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");

        var pos: usize = 0;
        while (pos < payload.len) {
            const chunk_len = rng.intRangeAtMost(usize, 1, 37);
            const end = @min(payload.len, pos + chunk_len);
            const slice = payload[pos..end];
            if (rng.boolean()) {
                try wire.writer().print("{x};ext=val\r\n", .{slice.len});
            } else {
                try wire.writer().print("{X}\r\n", .{slice.len});
            }
            try wire.appendSlice(slice);
            try wire.appendSlice("\r\n");
            pos = end;
        }
        try wire.appendSlice("0\r\n\r\n");

        const resp = try parseResponse(alloc, wire.items);
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expectEqualSlices(u8, payload, resp.body);
    }

    // Part B: Mutated and random raw inputs must never panic, overflow, or leak.
    var fuzz_i: usize = 0;
    while (fuzz_i < 200) : (fuzz_i += 1) {
        var raw = std.ArrayList(u8).init(alloc);
        defer raw.deinit();

        switch (fuzz_i % 4) {
            0 => {
                // Completely random bytes
                const n = rng.intRangeAtMost(usize, 0, 96);
                try raw.resize(n);
                rng.bytes(raw.items);
            },
            1 => {
                // Chunked header with random/corrupted body
                try raw.appendSlice("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
                const n = rng.intRangeAtMost(usize, 0, 64);
                const start = raw.items.len;
                try raw.resize(start + n);
                rng.bytes(raw.items[start..]);
            },
            2 => {
                // Content-Length header with random length & body
                const fake_len = rng.int(u32);
                try raw.writer().print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{fake_len});
                const n = rng.intRangeAtMost(usize, 0, 48);
                const start = raw.items.len;
                try raw.resize(start + n);
                rng.bytes(raw.items[start..]);
            },
            else => {
                // Valid chunked frame with a single random byte mutation in the body
                try raw.appendSlice("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
                const mutate_idx = rng.intRangeLessThan(usize, 0, raw.items.len);
                raw.items[mutate_idx] ^= @as(u8, 1) << rng.int(u3);
            },
        }

        if (parseResponse(alloc, raw.items)) |resp| {
            resp.deinit();
        } else |_| {}
    }
}

test "parseResponse rejects adversarial truncated chunks, size overflows, and smuggling" {
    const alloc = std.testing.allocator;
    const malformed_inputs = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Length: 5", // missing \r\n\r\n
        "NOTHTTP/1.1 200 OK\r\n\r\n",
        "HTTP/1.1 abc OK\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort",
        "HTTP/1.1 200 OK\r\nContent-Length: 999999999999\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\nhi\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10000000\r\nhi\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n;ext=only\r\n0\r\n\r\n",
    };
    for (malformed_inputs) |bad| {
        try std.testing.expectError(Error.InvalidResponse, parseResponse(alloc, bad));
    }
}

test "parseResponse supports chunked responses with HTTP trailers" {
    const alloc = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nExpires: Wed, 21 Oct 2025 07:28:00 GMT\r\n\r\n";
    const resp = try parseResponse(alloc, raw);
    defer resp.deinit();
    try std.testing.expectEqualStrings("hello", resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}
