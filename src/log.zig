//! File logger.
//!   system.log  – every message (DEBUG/INFO/WARN/ERROR) with a UTC timestamp
//!   error.log   – ERROR messages only
//!   audit.log   – tamper-evident SHA-256 hash-chained log entries
//! Errors and warnings are also echoed to stderr; info/debug only with --verbose.
const std = @import("std");

pub const AuditError = error{
    AuditTampered,
    InvalidAuditFormat,
};

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
    audit_file: ?std.fs.File = null,
    last_hash: [64]u8 = [_]u8{'0'} ** 64,
    verbose: bool = false,
    echo_stderr: bool = true,

    /// Opens (creating if needed) `<log_dir>/system.log`, `error.log`, and `audit.log`.
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
        self.last_hash = readLastAuditHash(dir);
        self.audit_file = openAppend(dir, "audit.log");
        return self;
    }

    pub fn deinit(self: *Logger) void {
        if (self.system_file) |f| f.close();
        if (self.error_file) |f| f.close();
        if (self.audit_file) |f| f.close();
        self.system_file = null;
        self.error_file = null;
        self.audit_file = null;
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
        if (self.audit_file) |f| {
            var audit_msg_buf: [4096]u8 = undefined;
            const raw_msg = std.mem.trimRight(u8, line.text[line.msg_start..], "\r\n");
            const audit_msg = sanitizeAuditField(&audit_msg_buf, raw_msg);
            const ts_end = std.mem.indexOfScalar(u8, line.text, ' ') orelse 0;
            const ts_str = line.text[0..ts_end];
            const entry_hash = computeEntryHash(ts_str, level.label(), &self.last_hash, audit_msg);
            var audit_buf: [4400]u8 = undefined;
            if (std.fmt.bufPrint(&audit_buf, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                ts_str,
                level.label(),
                self.last_hash,
                entry_hash,
                audit_msg,
            })) |audit_line| {
                if (f.writeAll(audit_line)) |_| {
                    self.last_hash = entry_hash;
                } else |_| {}
            } else |_| {}
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

fn sanitizeAuditField(buf: []u8, input: []const u8) []const u8 {
    const n = @min(buf.len, input.len);
    for (input[0..n], 0..) |c, idx| {
        buf[idx] = switch (c) {
            '\t', '\r', '\n' => ' ',
            else => c,
        };
    }
    return buf[0..n];
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn computeEntryHash(ts_str: []const u8, level_str: []const u8, prev_hash: *const [64]u8, msg: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(ts_str);
    hasher.update("\t");
    hasher.update(level_str);
    hasher.update("\t");
    hasher.update(prev_hash);
    hasher.update("\t");
    hasher.update(msg);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    return out;
}

fn readLastAuditHash(dir: std.fs.Dir) [64]u8 {
    const genesis = [_]u8{'0'} ** 64;
    const file = dir.openFile("audit.log", .{}) catch return genesis;
    defer file.close();
    const stat = file.stat() catch return genesis;
    if (stat.size == 0) return genesis;

    var buf: [8192]u8 = undefined;
    const start: u64 = if (stat.size > buf.len) stat.size - buf.len else 0;
    file.seekTo(start) catch return genesis;
    const n = file.readAll(&buf) catch return genesis;
    const trimmed = std.mem.trimRight(u8, buf[0..n], "\r\n");
    if (trimmed.len == 0) return genesis;

    const last_nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
    const last_line = if (last_nl) |idx| trimmed[idx + 1 ..] else trimmed;

    var parts = std.mem.splitScalar(u8, last_line, '\t');
    _ = parts.next() orelse return genesis;
    _ = parts.next() orelse return genesis;
    _ = parts.next() orelse return genesis;
    const hash = parts.next() orelse return genesis;
    if (!isHex64(hash)) return genesis;
    var out: [64]u8 = undefined;
    @memcpy(&out, hash);
    return out;
}

/// Verifies the SHA-256 hash chain in `path`. Returns the verified entry count.
pub fn verifyAuditFile(allocator: std.mem.Allocator, path: []const u8) !usize {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(content);

    const trimmed = if (std.mem.endsWith(u8, content, "\n")) content[0 .. content.len - 1] else content;
    if (trimmed.len == 0) return 0;

    var expected_prev = [_]u8{'0'} ** 64;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        var parts = std.mem.splitScalar(u8, line, '\t');
        const ts_str = parts.next() orelse return AuditError.InvalidAuditFormat;
        const level_str = parts.next() orelse return AuditError.InvalidAuditFormat;
        const prev_hash = parts.next() orelse return AuditError.InvalidAuditFormat;
        const entry_hash = parts.next() orelse return AuditError.InvalidAuditFormat;
        const msg = parts.next() orelse return AuditError.InvalidAuditFormat;
        if (parts.next() != null) return AuditError.InvalidAuditFormat;
        if (!isHex64(prev_hash) or !isHex64(entry_hash)) return AuditError.InvalidAuditFormat;

        if (!std.mem.eql(u8, prev_hash, &expected_prev)) return AuditError.AuditTampered;
        const computed = computeEntryHash(ts_str, level_str, &expected_prev, msg);
        if (!std.mem.eql(u8, entry_hash, &computed)) return AuditError.AuditTampered;

        expected_prev = computed;
        count += 1;
    }
    return count;
}

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

    const audit_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "audit.log" });
    defer std.testing.allocator.free(audit_path);
    const verified_count = try verifyAuditFile(std.testing.allocator, audit_path);
    try std.testing.expectEqual(@as(usize, 2), verified_count);

    // Re-opening logger continues the existing SHA-256 chain seamlessly.
    var logger2 = Logger.init(dir_path, false);
    logger2.echo_stderr = false;
    logger2.warn("resumed", .{});
    logger2.deinit();
    try std.testing.expectEqual(@as(usize, 3), try verifyAuditFile(std.testing.allocator, audit_path));
}

test "verifyAuditFile detects single-byte tampering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var logger = Logger.init(dir_path, false);
    logger.echo_stderr = false;
    logger.info("entry one", .{});
    logger.err("entry two", .{});
    logger.deinit();

    const audit_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "audit.log" });
    defer std.testing.allocator.free(audit_path);

    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "audit.log", 8192);
    defer std.testing.allocator.free(content);
    const idx = std.mem.indexOf(u8, content, "entry one") orelse unreachable;
    content[idx] = 'X';
    try tmp.dir.writeFile(.{ .sub_path = "audit.log", .data = content });

    try std.testing.expectError(AuditError.AuditTampered, verifyAuditFile(std.testing.allocator, audit_path));
}
