//! File logger.
//!   system.log  – every message (DEBUG/INFO/WARN/ERROR) with a UTC timestamp
//!   error.log   – ERROR messages only
//! Errors and warnings are also echoed to stderr; info/debug only with --verbose.
const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const Logger = struct {
    system_file: ?std.fs.File = null,
    error_file: ?std.fs.File = null,
    verbose: bool = false,
    echo_stderr: bool = true,

    /// Opens (creating if needed) `<log_dir>/system.log` and `<log_dir>/error.log`.
    /// Never fails: if the files cannot be opened, logging to them is skipped.
    pub fn init(log_dir: []const u8, verbose: bool) Logger {
        var self = Logger{ .verbose = verbose };
        var dir = std.fs.cwd().makeOpenPath(log_dir, .{}) catch |e| {
            std.debug.print("zigpod: warning: cannot open log dir '{s}': {s}\n", .{ log_dir, @errorName(e) });
            return self;
        };
        defer dir.close();
        self.system_file = openAppend(dir, "system.log");
        self.error_file = openAppend(dir, "error.log");
        return self;
    }

    pub fn deinit(self: *Logger) void {
        if (self.system_file) |f| f.close();
        if (self.error_file) |f| f.close();
        self.system_file = null;
        self.error_file = null;
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }
    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }
    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn log(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const line = formatLine(&buf, std.time.timestamp(), level, fmt, args);

        if (self.system_file) |f| f.writeAll(line.text) catch {};
        if (level == .err) {
            if (self.error_file) |f| f.writeAll(line.text) catch {};
        }

        const echo = level == .err or level == .warn or self.verbose;
        if (self.echo_stderr and echo) {
            std.io.getStdErr().writer().print("zigpod: {s}: {s}", .{
                level.label(),
                line.text[line.msg_start..],
            }) catch {};
        }
    }
};

/// Opens a file with O_APPEND so concurrent zigpod processes never overwrite each other.
fn openAppend(dir: std.fs.Dir, name: []const u8) ?std.fs.File {
    const fd = std.posix.openat(dir.fd, name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o644) catch |e| {
        std.debug.print("zigpod: warning: cannot open log file '{s}': {s}\n", .{ name, @errorName(e) });
        return null;
    };
    return std.fs.File{ .handle = fd };
}

pub const Line = struct {
    text: []const u8,
    /// Offset where the message (after "<timestamp> [LEVEL] ") begins.
    msg_start: usize,
};

/// Formats "<ISO-8601 UTC> [LEVEL] message\n" into `buf`, truncating if too long.
pub fn formatLine(buf: []u8, ts: i64, level: Level, comptime fmt: []const u8, args: anytype) Line {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    writeTimestamp(w, ts) catch {};
    w.print(" [{s}] ", .{level.label()}) catch {};
    const msg_start = fbs.pos;
    w.print(fmt, args) catch {};
    w.writeByte('\n') catch {
        // Buffer full: force the last byte to be a newline.
        buf[buf.len - 1] = '\n';
        return .{ .text = buf, .msg_start = @min(msg_start, buf.len) };
    };
    return .{ .text = fbs.getWritten(), .msg_start = msg_start };
}

pub fn writeTimestamp(w: anytype, ts: i64) !void {
    const secs: u64 = if (ts < 0) 0 else @intCast(ts);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

test "timestamp formatting" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeTimestamp(fbs.writer(), 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", fbs.getWritten());

    fbs.reset();
    try writeTimestamp(fbs.writer(), 1_700_000_000);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20Z", fbs.getWritten());
}

test "line formatting" {
    var buf: [128]u8 = undefined;
    const line = formatLine(&buf, 0, .err, "boom {d}", .{42});
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z [ERROR] boom 42\n", line.text);
    try std.testing.expectEqualStrings("boom 42\n", line.text[line.msg_start..]);
}

test "line truncation keeps trailing newline" {
    var buf: [40]u8 = undefined;
    const line = formatLine(&buf, 0, .info, "{s}", .{"a very long message that will not fit"});
    try std.testing.expectEqual(@as(usize, 40), line.text.len);
    try std.testing.expectEqual(@as(u8, '\n'), line.text[39]);
}

test "logger writes system.log and error.log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var logger = Logger.init(dir_path, false);
    logger.echo_stderr = false;
    logger.info("hello {s}", .{"world"});
    logger.err("bad {d}", .{1});
    logger.deinit();

    const sys = try tmp.dir.readFileAlloc(std.testing.allocator, "system.log", 4096);
    defer std.testing.allocator.free(sys);
    const errs = try tmp.dir.readFileAlloc(std.testing.allocator, "error.log", 4096);
    defer std.testing.allocator.free(errs);

    try std.testing.expect(std.mem.indexOf(u8, sys, "[INFO] hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "[ERROR] bad 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, errs, "[INFO]") == null);
    try std.testing.expect(std.mem.indexOf(u8, errs, "[ERROR] bad 1") != null);
}
