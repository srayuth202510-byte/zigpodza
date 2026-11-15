//! Shared HTTP client constants, response/stream/upgrade types, terminal raw-mode guard, and target validator.
const std = @import("std");

/// Upper bound on a buffered response body.
pub const max_response_bytes = 64 * 1024 * 1024;
/// Upper bound on HTTP response headers before `\r\n\r\n`.
pub const max_header_bytes = 64 * 1024;
pub const default_timeout_ms: i32 = 30_000;
/// Idle poll deadline for upgraded interactive attach/exec sessions (5 min),
/// bounded well below `blocking_timeout_ms` so silent/dead peer streams
/// return `Error.Timeout` instead of hanging indefinitely (BUG-032).
pub const interactive_timeout_ms: i32 = 5 * 60 * 1000;
/// Long ceiling for endpoints that legitimately stay silent for a long time:
/// `POST /containers/{id}/wait` answers only when the container exits and
/// `POST /images/create` streams a pull that can pause for minutes on big
/// layers (BUG-007). Each socket read still gets poll-enforced separately.
pub const blocking_timeout_ms: i32 = 12 * 60 * 60 * 1000;

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

pub const StreamResponse = struct {
    status: u16,
    error_body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: StreamResponse) void {
        if (self.error_body.len > 0) self.allocator.free(self.error_body);
    }

    pub fn ok(self: StreamResponse) bool {
        return self.status >= 200 and self.status < 300;
    }
};

pub const ResponseHead = struct {
    status: u16,
    chunked: bool = false,
    content_length: ?usize = null,
};

/// Active Unix socket after an HTTP `101 Switching Protocols` upgrade.
/// `initial_data` holds any payload bytes already read past `\r\n\r\n`.
pub const UpgradedConn = struct {
    stream: std.net.Stream,
    status: u16,
    initial_data: []u8,
    error_body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: UpgradedConn) void {
        if (self.initial_data.len > 0) self.allocator.free(self.initial_data);
        if (self.error_body.len > 0) self.allocator.free(self.error_body);
        self.stream.close();
    }
};

/// Enters raw terminal mode on `fd` when `fd` is a TTY and restores the
/// original termios settings on `restore()`. Safe no-op when `fd` is not a TTY.
pub const RawTermGuard = struct {
    fd: std.posix.fd_t,
    orig: std.posix.termios,
    active: bool,

    pub fn enter(fd: std.posix.fd_t) RawTermGuard {
        if (!std.posix.isatty(fd)) return .{ .fd = fd, .orig = undefined, .active = false };
        const orig = std.posix.tcgetattr(fd) catch return .{ .fd = fd, .orig = undefined, .active = false };
        var raw = orig;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(fd, .NOW, raw) catch return .{ .fd = fd, .orig = undefined, .active = false };
        return .{ .fd = fd, .orig = orig, .active = true };
    }

    pub fn restore(self: *RawTermGuard) void {
        if (self.active) {
            std.posix.tcsetattr(self.fd, .NOW, self.orig) catch {};
            self.active = false;
        }
    }
};

/// Rejects malformed or CRLF/whitespace-containing HTTP request targets.
pub fn validateRequestTarget(path: []const u8) Error!void {
    if (path.len == 0 or path[0] != '/') return Error.InvalidRequestPath;
    for (path) |c| {
        if (c <= 0x20 or c == 0x7f) return Error.InvalidRequestPath;
    }
}

// ---------------------------------------------------------------- tests

test "HTTP constants have expected values" {
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), max_response_bytes);
    try std.testing.expectEqual(@as(usize, 64 * 1024), max_header_bytes);
    try std.testing.expectEqual(@as(i32, 30_000), default_timeout_ms);
    try std.testing.expectEqual(@as(i32, 5 * 60 * 1000), interactive_timeout_ms);
    try std.testing.expectEqual(@as(i32, 12 * 60 * 60 * 1000), blocking_timeout_ms);
}

test "Error error set variants" {
    // Verify each error variant is distinct by comparing their error names.
    try std.testing.expect(!std.mem.eql(u8, @errorName(Error.SocketNotFound), @errorName(Error.DaemonNotRunning)));
    try std.testing.expect(!std.mem.eql(u8, @errorName(Error.DaemonNotRunning), @errorName(Error.PermissionDenied)));
    try std.testing.expect(!std.mem.eql(u8, @errorName(Error.PermissionDenied), @errorName(Error.InvalidResponse)));
    try std.testing.expect(!std.mem.eql(u8, @errorName(Error.InvalidResponse), @errorName(Error.InvalidRequestPath)));
    try std.testing.expect(!std.mem.eql(u8, @errorName(Error.InvalidRequestPath), @errorName(Error.Timeout)));
}

test "Response.ok returns true for 2xx and false otherwise" {
    const alloc = std.testing.allocator;
    var r = Response{ .status = 200, .body = try alloc.dupe(u8, "\x01\x02\x03"), .allocator = alloc };
    try std.testing.expect(r.ok());
    r.status = 299;
    try std.testing.expect(r.ok());
    r.status = 199;
    try std.testing.expect(!r.ok());
    r.status = 300;
    try std.testing.expect(!r.ok());
    r.status = 500;
    try std.testing.expect(!r.ok());
    r.deinit();
}

test "Response.deinit frees body buffer" {
    const alloc = std.testing.allocator;
    var r = Response{ .status = 200, .body = try alloc.dupe(u8, "hello"), .allocator = alloc };
    try std.testing.expectEqualStrings("hello", r.body);
    r.deinit();
}

test "StreamResponse.ok and deinit" {
    const alloc = std.testing.allocator;
    var sr = StreamResponse{ .status = 201, .error_body = try alloc.dupe(u8, "err"), .allocator = alloc };
    try std.testing.expect(sr.ok());
    sr.status = 404;
    try std.testing.expect(!sr.ok());
    sr.deinit();
}

test "StreamResponse.deinit is no-op when error_body is empty" {
    const alloc = std.testing.allocator;
    var sr = StreamResponse{ .status = 200, .error_body = &[_]u8{}, .allocator = alloc };
    sr.deinit(); // should not crash
}

test "ResponseHead field values" {
    var rh = ResponseHead{ .status = 200, .chunked = false, .content_length = null };
    try std.testing.expectEqual(@as(u16, 200), rh.status);
    try std.testing.expect(rh.chunked == false);
    try std.testing.expect(rh.content_length == null);

    rh = ResponseHead{ .status = 206, .chunked = true, .content_length = 1024 };
    try std.testing.expectEqual(@as(u16, 206), rh.status);
    try std.testing.expect(rh.chunked == true);
    try std.testing.expectEqual(@as(?usize, 1024), rh.content_length);
}

test "UpgradedConn holds initial_data and error_body before deinit" {
    const alloc = std.testing.allocator;
    const up = UpgradedConn{
        .stream = undefined,
        .status = 101,
        .initial_data = try alloc.dupe(u8, "banner:"),
        .error_body = try alloc.dupe(u8, "err"),
        .allocator = alloc,
    };
    try std.testing.expectEqualStrings("banner:", up.initial_data);
    try std.testing.expectEqualStrings("err", up.error_body);
    try std.testing.expectEqual(@as(u16, 101), up.status);
    // Manually free buffers (deinit would also close undefined stream, which is unsafe here).
    alloc.free(up.initial_data);
    alloc.free(up.error_body);
}

test "UpgradedConn fields are empty when no initial data or error body" {
    const alloc = std.testing.allocator;
    const up = UpgradedConn{
        .stream = undefined,
        .status = 200,
        .initial_data = &[_]u8{},
        .error_body = &[_]u8{},
        .allocator = alloc,
    };
    try std.testing.expectEqual(@as(u16, 200), up.status);
    try std.testing.expectEqual(@as(usize, 0), up.initial_data.len);
    try std.testing.expectEqual(@as(usize, 0), up.error_body.len);
    // Do not call deinit: stream is undefined and deinit would close it.
}

test "RawTermGuard.enter returns inactive guard for non-TTY fd" {
    // Use a pipe fd which is not a TTY.
    const pipe_fds = try std.posix.pipe();
    defer {
        std.posix.close(pipe_fds[0]);
        std.posix.close(pipe_fds[1]);
    }
    var guard = RawTermGuard.enter(pipe_fds[0]);
    try std.testing.expect(!guard.active);
    guard.restore(); // should be safe no-op
}

test "validateRequestTarget accepts valid paths and rejects invalid" {
    // Valid paths
    try validateRequestTarget("/v1.40/containers/json?all=true");
    try validateRequestTarget("/");
    try validateRequestTarget("/v1.40/_ping");
    try validateRequestTarget("/v1.40/containers/abc123/json");

    // Empty path
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget(""));

    // Missing leading slash
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("v1.40/containers/json"));

    // CRLF injection
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/\r\nX-Injected: 1"));

    // Space in path
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/a b"));

    // Null byte
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/\x00"));

    // Control characters
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/\x1f"));
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/\x7f"));

    // Tab character
    try std.testing.expectError(Error.InvalidRequestPath, validateRequestTarget("/v1.40/\t"));
}

