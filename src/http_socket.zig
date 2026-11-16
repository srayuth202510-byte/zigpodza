//! Non-blocking Unix-socket primitives shared by the HTTP client and the
//! upgraded interactive connection. All reads and writes are bounded by an
//! absolute deadline on the monotonic (`.awake`) clock so a stalled or silent
//! peer can never block the process forever (BUG-007, BUG-032, BUG-037).
const std = @import("std");
const Io = std.Io;
const Clock = Io.Clock;

pub const Error = @import("http_types.zig").Error;

/// An absolute wakeup deadline, or `null` to wait forever.
pub const Deadline = struct {
    ts: ?Clock.Timestamp,

    pub fn fromMs(io: Io, timeout_ms: i32) Deadline {
        if (timeout_ms < 0) return .{ .ts = null };
        const d: Clock.Duration = .{
            .raw = .fromNanoseconds(@as(i96, timeout_ms) * std.time.ns_per_ms),
            .clock = .awake,
        };
        return .{ .ts = Clock.Timestamp.fromNow(io, d) };
    }

    /// Milliseconds to pass to `poll`, or `-1` for no bound.
    /// Returns `error.Timeout` when the deadline has already passed.
    pub fn remainingMs(self: Deadline, io: Io) !i32 {
        const ts = self.ts orelse return -1;
        const now = Clock.awake.now(io);
        const rem_ns = ts.raw.nanoseconds - now.nanoseconds;
        if (rem_ns <= 0) return Error.Timeout;
        return @intCast(@min(@divTrunc(rem_ns, std.time.ns_per_ms) + 1, @as(i96, std.math.maxInt(i32))));
    }
};

fn waitPollEvent(handle: Io.net.Socket.Handle, events: i16, timeout_ms: i32) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = handle,
        .events = events,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, timeout_ms);
    if (ready == 0) return Error.Timeout;
}

pub fn waitReadable(io: Io, handle: Io.net.Socket.Handle, deadline: Deadline) !void {
    const ms = try deadline.remainingMs(io);
    if (ms < 0) return;
    try waitPollEvent(handle, std.posix.POLL.IN, ms);
}

pub fn waitWritable(io: Io, handle: Io.net.Socket.Handle, deadline: Deadline) !void {
    const ms = try deadline.remainingMs(io);
    try waitPollEvent(handle, std.posix.POLL.OUT, ms);
}

/// Puts the socket into non-blocking mode so writes can be bounded with
/// `POLL.OUT` instead of blocking forever on a stalled peer (BUG-037).
pub fn setNonBlocking(handle: Io.net.Socket.Handle) void {
    const linux = std.os.linux;
    const rc = linux.fcntl(handle, linux.F.GETFL, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const nb: linux.O = .{ .NONBLOCK = true };
    _ = linux.fcntl(handle, linux.F.SETFL, rc | @as(usize, @as(u32, @bitCast(nb))));
}

/// Reads up to `buf.len` bytes; returns 0 at EOF.
pub fn socketRead(io: Io, handle: Io.net.Socket.Handle, buf: []u8, deadline: Deadline) !usize {
    while (true) {
        try waitReadable(io, handle, deadline);
        const n = std.posix.read(handle, buf) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return e,
        };
        return n;
    }
}

/// Writes every byte of `data`; each partial write is bounded by `deadline`
/// using non-blocking `sendto` + `POLL.OUT` (BUG-037).
pub fn socketWriteAll(io: Io, handle: Io.net.Socket.Handle, data: []const u8, deadline: Deadline) !void {
    const linux = std.os.linux;
    var remaining = data;
    while (remaining.len > 0) {
        const rc = linux.sendto(
            @intCast(handle),
            remaining.ptr,
            remaining.len,
            linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL,
            null,
            0,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                remaining = remaining[n..];
            },
            .AGAIN, .INTR => try waitWritable(io, handle, deadline),
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.Unexpected,
        }
    }
}

/// Convenience wrapper: one read bounded by a millisecond timeout.
pub fn readOnce(io: Io, handle: Io.net.Socket.Handle, buf: []u8, timeout_ms: i32) !usize {
    return socketRead(io, handle, buf, Deadline.fromMs(io, timeout_ms));
}

/// Convenience wrapper: write everything within a millisecond budget (BUG-037).
pub fn writeAllWithTimeout(io: Io, handle: Io.net.Socket.Handle, data: []const u8, timeout_ms: i32) !void {
    return socketWriteAll(io, handle, data, Deadline.fromMs(io, timeout_ms));
}

pub fn http_socket_write(handle: Io.net.Socket.Handle, data: []const u8) void {
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

/// Blocking single read from `stream` (mock servers / tests); returns 0 at EOF.
pub fn streamRead(io: Io, stream: Io.net.Stream, buf: []u8) !usize {
    var data = [_][]u8{buf};
    return stream.read(io, &data);
}

/// Blocking write of all of `data` to `stream` (mock servers / tests).
pub fn streamWriteAll(stream: Io.net.Stream, data: []const u8) !void {
    const linux = std.os.linux;
    var remaining = data;
    while (remaining.len > 0) {
        const rc = linux.sendto(@intCast(stream.socket.handle), remaining.ptr, remaining.len, linux.MSG.NOSIGNAL, null, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                remaining = remaining[n..];
            },
            .AGAIN, .INTR => std.Thread.yield() catch {},
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.Unexpected,
        }
    }
}
