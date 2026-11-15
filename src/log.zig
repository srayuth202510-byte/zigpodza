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
        self.system_file = openAppend(dir, "system.log", false);
        self.error_file = openAppend(dir, "error.log", false);
        self.audit_file = openAppend(dir, "audit.log", true);
        if (self.audit_file) |f| {
            // BUG-008/BUG-009: repair an interrupted tail and resume the chain
            // under an exclusive lock so concurrent processes stay consistent.
            lockAudit(f);
            defer unlockAudit(f);
            repairAuditTail(f);
            self.last_hash = lastHashFromFd(f.handle);
        }
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

    /// Emits a structured `DENY` security telemetry event into `system.log`,
    /// `error.log`, and the SHA-256 hash-chained `audit.log` for `balorsh`
    /// (`loganalyst` / `blueteam`) automated auditing.
    pub fn deny(self: *Logger, rule: []const u8, detail: []const u8) void {
        self.log(.err, "DENY rule={s} detail={s}", .{ rule, detail });
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
            // BUG-009: hold an exclusive lock and re-read the current chain
            // head from the file so interleaved zigpod processes never fork
            // the hash chain.
            lockAudit(f);
            defer unlockAudit(f);
            const prev_hash = lastHashFromFd(f.handle);
            const entry_hash = computeEntryHash(ts_str, level.label(), &prev_hash, audit_msg);
            var audit_buf: [4400]u8 = undefined;
            if (std.fmt.bufPrint(&audit_buf, "{s}\t{s}\t{s}\t{s}\t{s}\n", .{
                ts_str,
                level.label(),
                prev_hash,
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

fn lockAudit(f: std.fs.File) void {
    std.posix.flock(f.handle, std.posix.LOCK.EX) catch {};
}

fn unlockAudit(f: std.fs.File) void {
    std.posix.flock(f.handle, std.posix.LOCK.UN) catch {};
}

/// `pread` in a loop; short reads are normal for regular files.
fn preadAll(fd: std.posix.fd_t, buf: []u8, offset: u64) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.pread(fd, buf[total..], offset + total) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// BUG-008: truncate an incomplete trailing line left behind when a previous
/// process crashed mid-append. The partial line was never committed to the
/// chain (no successor ever referenced its hash), so removing it restores a
/// verifiable chain instead of poisoning every future verification.
fn repairAuditTail(f: std.fs.File) void {
    const stat = f.stat() catch return;
    if (stat.size == 0) return;
    var buf: [8192]u8 = undefined;
    const start: u64 = if (stat.size > buf.len) stat.size - buf.len else 0;
    const n = preadAll(f.handle, &buf, start);
    if (n == 0) return;
    const last_nl = std.mem.lastIndexOfScalar(u8, buf[0..n], '\n') orelse {
        // No newline in the window: either the whole file is one partial
        // line (start == 0) or the partial tail exceeds the writer's max
        // line size; only the former is safe to repair here.
        if (start == 0) std.posix.ftruncate(f.handle, 0) catch {};
        return;
    };
    const complete_end: u64 = start + @as(u64, last_nl) + 1;
    if (complete_end < stat.size) {
        std.posix.ftruncate(f.handle, complete_end) catch {};
    }
}

/// Reads the hash of the last complete audit line directly from the file
/// descriptor (usable both at init and for per-write re-reads under flock).
fn lastHashFromFd(fd: std.posix.fd_t) [64]u8 {
    const genesis = [_]u8{'0'} ** 64;
    const f = std.fs.File{ .handle = fd };
    const stat = f.stat() catch return genesis;
    if (stat.size == 0) return genesis;

    var buf: [8192]u8 = undefined;
    const start: u64 = if (stat.size > buf.len) stat.size - buf.len else 0;
    const n = preadAll(fd, &buf, start);
    if (n == 0) return genesis;
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
/// A trailing line without a terminating newline is an uncommitted partial
/// write (crash mid-append, BUG-008): it is skipped, not counted, and is not
/// treated as tampering.
pub fn verifyAuditFile(allocator: std.mem.Allocator, path: []const u8) !usize {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(content);
    if (content.len == 0) return 0;

    var expected_prev = [_]u8{'0'} ** 64;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        if (lines.peek() == null) break; // trailing "" or uncommitted partial line
        if (raw_line.len == 0) continue;
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

pub const AuditDenyRecord = struct {
    timestamp: []const u8,
    rule: []const u8,
    detail: []const u8,
    hash: []const u8,
};

pub const AuditReport = struct {
    path: []const u8,
    valid: bool,
    entries: usize,
    deny_events: usize,
    error_events: usize,
    head_hash: []const u8,
    failure_reason: ?[]const u8 = null,
    deny_records: []const AuditDenyRecord,
};

fn parseDenyMessage(msg: []const u8) ?struct { rule: []const u8, detail: []const u8 } {
    const prefix = "DENY rule=";
    if (!std.mem.startsWith(u8, msg, prefix)) return null;
    const after_rule = msg[prefix.len..];
    const detail_marker = " detail=";
    const idx = std.mem.indexOf(u8, after_rule, detail_marker) orelse return .{
        .rule = after_rule,
        .detail = "",
    };
    return .{
        .rule = after_rule[0..idx],
        .detail = after_rule[idx + detail_marker.len ..],
    };
}

/// Verifies `path` and writes a structured JSON audit report to `writer`.
/// Returns `true` if the hash chain is intact, or `false` if tampering or
/// format corruption was detected.
pub fn writeAuditJson(allocator: std.mem.Allocator, path: []const u8, writer: anytype) !bool {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(content);

    var deny_list = std.ArrayList(AuditDenyRecord).init(allocator);
    defer deny_list.deinit();

    var expected_prev = [_]u8{'0'} ** 64;
    var count: usize = 0;
    var error_count: usize = 0;
    var valid = true;
    var failure_reason: ?[]const u8 = null;

    if (content.len > 0) {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            if (lines.peek() == null) break;
            if (raw_line.len == 0) continue;
            const line = std.mem.trimRight(u8, raw_line, "\r");
            var parts = std.mem.splitScalar(u8, line, '\t');
            const ts_str = parts.next() orelse {
                valid = false;
                failure_reason = "InvalidAuditFormat";
                break;
            };
            const level_str = parts.next() orelse {
                valid = false;
                failure_reason = "InvalidAuditFormat";
                break;
            };
            const prev_hash = parts.next() orelse {
                valid = false;
                failure_reason = "InvalidAuditFormat";
                break;
            };
            const entry_hash = parts.next() orelse {
                valid = false;
                failure_reason = "InvalidAuditFormat";
                break;
            };
            const msg = parts.next() orelse {
                valid = false;
                failure_reason = "InvalidAuditFormat";
                break;
            };
            if (parts.next() != null or !isHex64(prev_hash) or !isHex64(entry_hash)) {
                valid = false;
                failure_reason = "InvalidAuditFormat";
                break;
            }
            if (!std.mem.eql(u8, prev_hash, &expected_prev)) {
                valid = false;
                failure_reason = "AuditTampered";
                break;
            }
            const computed = computeEntryHash(ts_str, level_str, &expected_prev, msg);
            if (!std.mem.eql(u8, entry_hash, &computed)) {
                valid = false;
                failure_reason = "AuditTampered";
                break;
            }

            expected_prev = computed;
            count += 1;
            if (std.mem.eql(u8, level_str, "ERROR")) error_count += 1;
            if (parseDenyMessage(msg)) |d| {
                try deny_list.append(.{
                    .timestamp = ts_str,
                    .rule = d.rule,
                    .detail = d.detail,
                    .hash = entry_hash,
                });
            }
        }
    }

    const report = AuditReport{
        .path = path,
        .valid = valid,
        .entries = count,
        .deny_events = deny_list.items.len,
        .error_events = error_count,
        .head_hash = &expected_prev,
        .failure_reason = failure_reason,
        .deny_records = deny_list.items,
    };
    try std.json.stringify(report, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    return valid;
}

/// Opens a file with O_APPEND so concurrent zigpod processes never overwrite each other.
/// `readable` requests RDWR (needed by the audit file for tail repair/re-reads).
/// Refuses symlinks (O_NOFOLLOW), non-regular files, and wrong ownership, and
/// enforces mode 0640 on pre-existing files (BUG-013, BUG-031).
fn openAppend(dir: std.fs.Dir, name: []const u8, readable: bool) ?std.fs.File {
    const fd = std.posix.openat(dir.fd, name, .{
        .ACCMODE = if (readable) .RDWR else .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0o640) catch |e| {
        std.debug.print("zigpod: warning: cannot open log file '{s}': {s}\n", .{ name, @errorName(e) });
        return null;
    };
    const st = std.posix.fstat(fd) catch |e| {
        std.posix.close(fd);
        std.debug.print("zigpod: warning: cannot stat log file '{s}': {s}\n", .{ name, @errorName(e) });
        return null;
    };
    if (!std.posix.S.ISREG(st.mode) or st.uid != std.os.linux.getuid()) {
        std.posix.close(fd);
        std.debug.print("zigpod: warning: refusing insecure log file '{s}' (type/owner mismatch)\n", .{name});
        return null;
    }
    std.posix.fchmod(fd, 0o640) catch |e| {
        std.posix.close(fd);
        std.debug.print("zigpod: warning: cannot enforce 0640 mode on log file '{s}': {s}\n", .{ name, @errorName(e) });
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

test "incomplete audit tail is skipped by verify and repaired on next init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    {
        var logger = Logger.init(dir_path, false);
        logger.echo_stderr = false;
        logger.info("entry one", .{});
        logger.deinit();
    }

    const audit_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "audit.log" });
    defer std.testing.allocator.free(audit_path);

    // Simulate a crash mid-append: a partial line with no trailing newline.
    {
        const f = try tmp.dir.openFile("audit.log", .{ .mode = .read_write });
        defer f.close();
        try f.seekTo(try f.getEndPos());
        try f.writeAll("crash-partial-line");
    }

    // BUG-008: the uncommitted tail must not be reported as tampering.
    try std.testing.expectEqual(@as(usize, 1), try verifyAuditFile(std.testing.allocator, audit_path));

    // Re-opening repairs (truncates) the partial tail and continues the chain.
    var logger2 = Logger.init(dir_path, false);
    logger2.echo_stderr = false;
    logger2.info("after repair", .{});
    logger2.deinit();
    try std.testing.expectEqual(@as(usize, 2), try verifyAuditFile(std.testing.allocator, audit_path));
}

test "interleaved loggers keep the audit chain consistent (flock + re-read)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var logger_a = Logger.init(dir_path, false);
    defer logger_a.deinit();
    var logger_b = Logger.init(dir_path, false);
    defer logger_b.deinit();
    logger_a.echo_stderr = false;
    logger_b.echo_stderr = false;

    // BUG-009: both loggers initialized before either writes — without
    // re-reading the chain head under the lock, the second writer would fork
    // the hash chain and make verification fail.
    logger_a.info("a one", .{});
    logger_b.info("b two", .{});
    logger_a.info("a three", .{});
    logger_b.info("b four", .{});

    const audit_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "audit.log" });
    defer std.testing.allocator.free(audit_path);
    try std.testing.expectEqual(@as(usize, 4), try verifyAuditFile(std.testing.allocator, audit_path));
}

test "logger.deny and writeAuditJson emit structured DENY telemetry and detect tampering" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    {
        var logger = Logger.init(dir_path, false);
        defer logger.deinit();
        logger.echo_stderr = false;
        logger.info("zigpod start", .{});
        logger.deny("policy.max_memory_bytes", "requested 512m exceeds sandbox ceiling 256m");
    }

    const audit_path = try std.fs.path.join(alloc, &.{ dir_path, "audit.log" });
    defer alloc.free(audit_path);

    var json_out = std.ArrayList(u8).init(alloc);
    defer json_out.deinit();
    const ok = try writeAuditJson(alloc, audit_path, json_out.writer());
    try std.testing.expect(ok);
    try std.testing.expect(std.mem.indexOf(u8, json_out.items, "\"valid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out.items, "\"entries\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out.items, "\"deny_events\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out.items, "\"rule\":\"policy.max_memory_bytes\"") != null);

    // Tamper with the audit file and verify writeAuditJson reports valid=false.
    try tmp.dir.writeFile(.{
        .sub_path = "audit.log",
        .data = "2026-01-01T00:00:00Z\tINFO\t0000000000000000000000000000000000000000000000000000000000000000\tffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\ttampered\n",
    });
    json_out.clearRetainingCapacity();
    const ok_tampered = try writeAuditJson(alloc, audit_path, json_out.writer());
    try std.testing.expect(!ok_tampered);
    try std.testing.expect(std.mem.indexOf(u8, json_out.items, "\"valid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out.items, "\"failure_reason\":\"AuditTampered\"") != null);
}

test "fuzz verifyAuditFile and writeAuditJson over corrupted and random audit logs" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xa0d17f02);
    const rng = prng.random();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    {
        var logger = Logger.init(dir_path, false);
        defer logger.deinit();
        logger.echo_stderr = false;
        logger.info("entry one", .{});
        logger.warn("entry two", .{});
        logger.err("entry three", .{});
        logger.deny("policy.network_none", "network mode must be none");
    }

    const audit_path = try std.fs.path.join(alloc, &.{ dir_path, "audit.log" });
    defer alloc.free(audit_path);

    const baseline = try tmp.dir.readFileAlloc(alloc, "audit.log", 16384);
    defer alloc.free(baseline);
    try std.testing.expectEqual(@as(usize, 4), try verifyAuditFile(alloc, audit_path));

    // Part A: Any single-byte bitflip inside the committed log (excluding the final '\n')
    // must be caught by both verifyAuditFile and writeAuditJson without panicking or leaking.
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const mutated = try alloc.dupe(u8, baseline);
        defer alloc.free(mutated);

        const pos = rng.intRangeLessThan(usize, 0, mutated.len - 1);
        // Avoid mutating a newline into a non-newline on the very last byte; flip a bit at `pos`.
        mutated[pos] ^= @as(u8, 1) << rng.int(u3);
        try tmp.dir.writeFile(.{ .sub_path = "audit.log", .data = mutated });

        const verify_res = verifyAuditFile(alloc, audit_path);
        var json_out = std.ArrayList(u8).init(alloc);
        defer json_out.deinit();
        const json_ok = try writeAuditJson(alloc, audit_path, json_out.writer());

        // Unless we turned the last newline of the file into a non-newline (which only happens at mutated.len - 1,
        // excluded above), tampering with a committed byte must fail verification.
        if (verify_res) |_| {
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expect(err == AuditError.AuditTampered or err == AuditError.InvalidAuditFormat);
        }
        try std.testing.expect(!json_ok);
        try std.testing.expect(std.mem.indexOf(u8, json_out.items, "\"valid\":false") != null);
    }

    // Part B: Arbitrary random byte buffers with embedded '\n' and '\t' must never panic or leak.
    var fuzz_i: usize = 0;
    while (fuzz_i < 48) : (fuzz_i += 1) {
        const len = rng.intRangeAtMost(usize, 1, 256);
        const buf = try alloc.alloc(u8, len);
        defer alloc.free(buf);
        rng.bytes(buf);
        buf[len - 1] = '\n';

        try tmp.dir.writeFile(.{ .sub_path = "audit.log", .data = buf });
        _ = verifyAuditFile(alloc, audit_path) catch {};

        var json_out = std.ArrayList(u8).init(alloc);
        defer json_out.deinit();
        _ = try writeAuditJson(alloc, audit_path, json_out.writer());
    }
}

test "BUG-031: Logger.init blocks symlinks and enforces mode 0640 on existing log files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const victim = try tmp.dir.createFile("victim.txt", .{});
    victim.close();
    try tmp.dir.symLink("victim.txt", "audit.log", .{});

    const sys_f = try tmp.dir.createFile("system.log", .{});
    try sys_f.chmod(0o644);
    sys_f.close();

    const err_f = try tmp.dir.createFile("error.log", .{});
    try err_f.chmod(0o666);
    err_f.close();

    var logger = Logger.init(dir_path, false);
    logger.echo_stderr = false;
    logger.err("probe event", .{});
    logger.deinit();

    // Audit symlink must never be followed or appended to.
    try std.testing.expect(logger.audit_file == null);
    const victim_contents = try tmp.dir.readFileAlloc(alloc, "victim.txt", 4096);
    defer alloc.free(victim_contents);
    try std.testing.expectEqualStrings("", victim_contents);

    // Pre-existing permissive log files must be tightened to 0640.
    const sys_stat = try tmp.dir.statFile("system.log");
    const err_stat = try tmp.dir.statFile("error.log");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o640), sys_stat.mode & 0o777);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o640), err_stat.mode & 0o777);
}
