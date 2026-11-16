//! Formatting and logging convenience utilities.
const std = @import("std");
pub const log = @import("log.zig");

/// Linux PATH_MAX; `std.fs.MAX_PATH_BYTES` was removed in Zig 0.17.
pub const max_path_bytes: usize = 4096;

/// Zig 0.17 replacement for `File.readToEndAlloc`: reads the rest of `file`
/// into a caller-owned slice, failing with `error.FileTooBig` past `max_bytes`.
pub fn readFileToEndAlloc(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    // `.limited(n)` errors once `n` is *reached* for streaming readers, so ask
    // for one extra byte and enforce the old "at most `max_bytes`" bound here.
    const data = r.interface.allocRemaining(allocator, .limited(max_bytes +| 1)) catch |e| return switch (e) {
        error.StreamTooLong => error.FileTooBig,
        error.ReadFailed => r.err orelse error.ReadFailed,
        else => |x| x,
    };
    if (data.len > max_bytes) {
        allocator.free(data);
        return error.FileTooBig;
    }
    return data;
}

/// Zig 0.17 replacement for `Dir.realpath(path, buf)`: resolves `path`
/// (relative to cwd) into `buf` and returns the resolved slice.
pub fn realpath(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    const n = try std.Io.Dir.cwd().realPathFile(io, path, buf);
    return buf[0..n];
}

/// Zig 0.17 replacement for `Dir.realpathAlloc`. Unlike `realPathFileAlloc`
/// (which returns a sentinel slice), the result is an exact-length `[]u8` that
/// can be freed with `allocator.free` after coercion to `[]const u8`.
pub fn realpathAlloc(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buf: [max_path_bytes]u8 = undefined;
    const n = try dir.realPathFile(io, path, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

/// Milliseconds since the Unix epoch (replacement for `std.time.milliTimestamp`).
pub fn milliTimestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Seconds since the Unix epoch (replacement for `std.time.timestamp`).
pub fn timestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

/// Monotonic nanoseconds; handy as a unique suffix for test socket paths.
pub fn uniqueNanos(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// Returns up to the first 12 characters of an image/container ID,
/// stripping a leading "sha256:" prefix if present.
pub fn shortId(id: []const u8) []const u8 {
    const prefix = "sha256:";
    const clean = if (std.mem.startsWith(u8, id, prefix)) id[prefix.len..] else id;
    return if (clean.len > 12) clean[0..12] else clean;
}

/// Formats a byte count into a human-readable string (B, KB, MB, GB) in `buf`.
pub fn formatSize(buf: []u8, bytes: i64) []const u8 {
    if (bytes <= 0) return std.fmt.bufPrint(buf, "0 B", .{}) catch "0 B";
    const val: f64 = @floatFromInt(bytes);
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    } else if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{val / 1024.0}) catch "?";
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{val / (1024.0 * 1024.0)}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{val / (1024.0 * 1024.0 * 1024.0)}) catch "?";
    }
}

test "shortId strips sha256 prefix and truncates to 12 chars" {
    try std.testing.expectEqualStrings("abcdef123456", shortId("abcdef1234567890"));
    try std.testing.expectEqualStrings("1234567890ab", shortId("sha256:1234567890abcdef"));
    try std.testing.expectEqualStrings("short", shortId("short"));
    try std.testing.expectEqualStrings("", shortId(""));
}

test "formatSize human readable units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatSize(&buf, 0));
    try std.testing.expectEqualStrings("512 B", formatSize(&buf, 512));
    try std.testing.expectEqualStrings("1.5 KB", formatSize(&buf, 1536));
    try std.testing.expectEqualStrings("2.0 MB", formatSize(&buf, 2 * 1024 * 1024));
    try std.testing.expectEqualStrings("1.50 GB", formatSize(&buf, 1610612736));
}

/// Zig 0.17 removed `std.posix.pipe`; thin wrapper over the Linux syscall.
pub fn pipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    return switch (std.os.linux.errno(std.os.linux.pipe2(&fds, .{}))) {
        .SUCCESS => fds,
        .MFILE, .NFILE => error.ProcessFdQuotaExceeded,
        else => error.Unexpected,
    };
}

/// Zig 0.17 removed `std.posix.write`; single raw write to `fd`.
pub fn writeFd(fd: std.posix.fd_t, data: []const u8) !usize {
    const rc = std.os.linux.write(fd, data.ptr, data.len);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => rc,
        .PIPE => error.BrokenPipe,
        else => error.Unexpected,
    };
}

/// Zig 0.17 removed `std.posix.close`; best-effort close of a raw fd.
pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.os.linux.close(fd);
}
