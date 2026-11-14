//! Shared HTTP client constants, response/stream/upgrade types, terminal raw-mode guard, and target validator.
const std = @import("std");

/// Upper bound on a buffered response body.
pub const max_response_bytes = 64 * 1024 * 1024;
/// Upper bound on HTTP response headers before `\r\n\r\n`.
pub const max_header_bytes = 64 * 1024;
pub const default_timeout_ms: i32 = 30_000;
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

