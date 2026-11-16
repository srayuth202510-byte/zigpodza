//! Container log demultiplexing and resource stats (CPU, memory, PIDs).
const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const http_socket = @import("http_socket.zig");
const http_socket_write = http_socket.http_socket_write;
const log = @import("log.zig");
const utils = @import("utils.zig");
const types = @import("podman_types.zig");
const validate = @import("podman_validate.zig");
const th = @import("podman_test_helpers.zig");

const api_prefix = validate.api_prefix;
const validateIdentifier = validate.validateIdentifier;
const logApiFailure = validate.logApiFailure;
const formatSizeU64 = validate.formatSizeU64;

const ApiError = types.ApiError;
const ContainerStats = types.ContainerStats;
const ContainerSummary = types.ContainerSummary;
const StatsJsonEntry = types.StatsJsonEntry;
const MockApiCtx = th.MockApiCtx;
const ScriptedReply = th.ScriptedReply;
const runMockPodmanServer = th.runMockPodmanServer;
const readHttpRequest = th.readHttpRequest;

/// Falls back to raw passthrough when the stream does not begin with a valid header.
pub fn LogDemuxer(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: WriterType,
        buf: std.array_list.Aligned(u8, null) = .empty,
        raw_mode: bool = false,
        seen_valid_frame: bool = false,

        pub fn deinit(self: *@This()) void {
            self.buf.deinit(self.allocator);
        }

        pub fn push(self: *@This(), chunk: []const u8) !void {
            if (chunk.len == 0) return;
            if (self.raw_mode) {
                try self.writer.writeAll(chunk);
                return;
            }
            const projected = std.math.add(usize, self.buf.items.len, chunk.len) catch return http.Error.InvalidResponse;
            if (projected > http.max_response_bytes) return http.Error.InvalidResponse;
            try self.buf.appendSlice(self.allocator, chunk);

            var pos: usize = 0;
            while (self.buf.items.len - pos >= 8) {
                const hdr = self.buf.items[pos .. pos + 8];
                const stream_type = hdr[0];
                const zeros_ok = hdr[1] == 0 and hdr[2] == 0 and hdr[3] == 0;
                if (stream_type > 2 or !zeros_ok) {
                    if (!self.seen_valid_frame) {
                        self.raw_mode = true;
                        try self.writer.writeAll(self.buf.items[pos..]);
                        self.buf.items.len = 0;
                        return;
                    }
                    break;
                }
                const frame_len: usize = std.mem.readInt(u32, hdr[4..8], .big);
                const payload_start = std.math.add(usize, pos, 8) catch break;
                const payload_end = std.math.add(usize, payload_start, frame_len) catch break;
                if (payload_end > self.buf.items.len) break;
                self.seen_valid_frame = true;
                try self.writer.writeAll(self.buf.items[payload_start..payload_end]);
                pos = payload_end;
            }
            if (pos > 0) {
                const rem = self.buf.items.len - pos;
                if (rem > 0) std.mem.copyForwards(u8, self.buf.items[0..rem], self.buf.items[pos..]);
                self.buf.items.len = rem;
            }
        }

        pub fn flush(self: *@This()) !void {
            if (!self.seen_valid_frame and self.buf.items.len > 0) {
                try self.writer.writeAll(self.buf.items);
            }
            self.buf.items.len = 0;
        }
    };
}

/// Computes Docker-compatible CPU percentage from `cpu_stats` and `precpu_stats`.
pub fn computeCpuPercent(s: ContainerStats) f64 {
    const cpu = s.cpu_stats orelse return 0.0;
    const pre = s.precpu_stats orelse return 0.0;
    const cur_total = (cpu.cpu_usage orelse return 0.0).total_usage orelse return 0.0;
    const pre_total = (pre.cpu_usage orelse return 0.0).total_usage orelse 0;
    const cur_sys = cpu.system_cpu_usage orelse return 0.0;
    const pre_sys = pre.system_cpu_usage orelse 0;

    if (cur_total <= pre_total or cur_sys <= pre_sys) return 0.0;

    const cpu_delta = cur_total - pre_total;
    const sys_delta = cur_sys - pre_sys;

    const online_cpus: u32 = blk: {
        if (cpu.online_cpus) |n| {
            if (n > 0) break :blk n;
        }
        if (cpu.cpu_usage) |usage| {
            if (usage.percpu_usage) |percpu| {
                if (percpu.len > 0) break :blk @intCast(@min(percpu.len, std.math.maxInt(u32)));
            }
        }
        break :blk 1;
    };

    return (@as(f64, @floatFromInt(cpu_delta)) / @as(f64, @floatFromInt(sys_delta))) *
        @as(f64, @floatFromInt(online_cpus)) * 100.0;
}

/// Computes effective memory usage (subtracting page cache / inactive_file) and percentage of limit.
pub fn computeMemoryUsage(ms_opt: ?ContainerStats.MemoryStats) struct { used: u64, limit: u64, percent: f64 } {
    const ms = ms_opt orelse return .{ .used = 0, .limit = 0, .percent = 0.0 };
    const raw_usage = ms.usage orelse 0;
    const reclaimable: u64 = if (ms.stats) |st| (st.inactive_file orelse st.cache orelse 0) else 0;
    const used = if (raw_usage > reclaimable) raw_usage - reclaimable else 0;
    const limit = ms.limit orelse 0;
    const percent: f64 = if (limit > 0)
        (@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(limit))) * 100.0
    else
        0.0;
    return .{ .used = used, .limit = limit, .percent = percent };
}

fn formatStatsRow(writer: anytype, fallback_id: []const u8, s: ContainerStats) !void {
    const id = if (s.id.len > 0) s.id else fallback_id;
    const name = std.mem.trimStart(u8, s.name, "/");
    const cpu_pct = computeCpuPercent(s);
    const mem = computeMemoryUsage(s.memory_stats);
    const pids: u64 = if (s.pids_stats) |p| p.current orelse 0 else 0;

    var cpu_buf: [24]u8 = undefined;
    const cpu_str = std.fmt.bufPrint(&cpu_buf, "{d:.2}%", .{cpu_pct}) catch "0.00%";

    var used_buf: [32]u8 = undefined;
    var limit_buf: [32]u8 = undefined;
    const used_str = formatSizeU64(&used_buf, mem.used);
    const limit_str = if (mem.limit > 0) formatSizeU64(&limit_buf, mem.limit) else "--";
    var mem_col_buf: [68]u8 = undefined;
    const mem_col = std.fmt.bufPrint(&mem_col_buf, "{s} / {s}", .{ used_str, limit_str }) catch "?";

    var mem_pct_buf: [24]u8 = undefined;
    const mem_pct_str = std.fmt.bufPrint(&mem_pct_buf, "{d:.2}%", .{mem.percent}) catch "0.00%";

    try writer.print("{s:<14} {s:<20} {s:<9} {s:<24} {s:<9} {d}\n", .{
        utils.shortId(id),
        name,
        cpu_str,
        mem_col,
        mem_pct_str,
        pids,
    });
}

fn fetchAndPrintStats(
    client: *const http.Client,
    logger: *log.Logger,
    id: []const u8,
    writer: anytype,
) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/stats?stream=false", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(ContainerStats, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try formatStatsRow(writer, id, parsed.value);
}

/// Fetches a one-shot (`stream=false`) snapshot of CPU, memory, and PIDs metrics
/// for the specified containers (or all running/listed containers when empty).
pub fn statsContainers(
    client: *const http.Client,
    logger: *log.Logger,
    containers: []const []const u8,
    all: bool,
    writer: anytype,
) !void {
    if (containers.len > 0) {
        // Validate every target before opening any socket connection.
        for (containers) |c| try validateIdentifier(c);

        try writer.print("{s:<14} {s:<20} {s:<9} {s:<24} {s:<9} {s}\n", .{
            "CONTAINER ID", "NAME", "CPU %", "MEM USAGE / LIMIT", "MEM %", "PIDS",
        });
        for (containers) |c| {
            try fetchAndPrintStats(client, logger, c, writer);
        }
        logger.info("fetched stats for {d} container(s)", .{containers.len});
        return;
    }

    const list_path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/json?all={s}",
        .{ api_prefix, if (all) "true" else "false" },
    );
    defer client.allocator.free(list_path);

    logger.debug("GET {s}", .{list_path});
    const list_resp = try client.request("GET", list_path, null);
    defer list_resp.deinit();
    if (!list_resp.ok()) return logApiFailure(logger, "GET", list_path, list_resp);

    const list_parsed = try std.json.parseFromSlice([]ContainerSummary, client.allocator, list_resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer list_parsed.deinit();

    // Defense-in-depth: validate daemon-returned IDs before assembling /stats paths.
    for (list_parsed.value) |c| try validateIdentifier(c.Id);

    try writer.print("{s:<14} {s:<20} {s:<9} {s:<24} {s:<9} {s}\n", .{
        "CONTAINER ID", "NAME", "CPU %", "MEM USAGE / LIMIT", "MEM %", "PIDS",
    });
    for (list_parsed.value) |c| {
        try fetchAndPrintStats(client, logger, c.Id, writer);
    }
    logger.info("fetched stats for {d} container(s)", .{list_parsed.value.len});
}

fn StatsStreamCtx(comptime WriterType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        id: []const u8,
        writer: WriterType,
        line_buf: std.array_list.Aligned(u8, null) = .empty,
        frames: usize = 0,

        fn deinit(self: *@This()) void {
            self.line_buf.deinit(self.allocator);
        }

        fn onChunk(self: *@This(), chunk: []const u8) !void {
            const projected = std.math.add(usize, self.line_buf.items.len, chunk.len) catch return http.Error.InvalidResponse;
            if (projected > 1024 * 1024) return http.Error.InvalidResponse;
            try self.line_buf.appendSlice(self.allocator, chunk);

            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, self.line_buf.items, start, '\n')) |nl| {
                const line = std.mem.trim(u8, self.line_buf.items[start..nl], " \r\t");
                if (line.len > 0) try self.handleLine(line);
                start = nl + 1;
            }
            if (start > 0) {
                const rem = self.line_buf.items.len - start;
                if (rem > 0) std.mem.copyForwards(u8, self.line_buf.items[0..rem], self.line_buf.items[start..]);
                self.line_buf.items.len = rem;
            }
        }

        fn flush(self: *@This()) !void {
            const line = std.mem.trim(u8, self.line_buf.items, " \r\t");
            if (line.len > 0) try self.handleLine(line);
            self.line_buf.items.len = 0;
        }

        fn handleLine(self: *@This(), line: []const u8) !void {
            const parsed = try std.json.parseFromSlice(ContainerStats, self.allocator, line, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            try formatStatsRow(self.writer, self.id, parsed.value);
            self.frames += 1;
        }
    };
}

/// Streams live CPU, memory, and PIDs metrics (`GET /containers/{id}/stats?stream=true`)
/// via incremental HTTP/1.1 chunked/body streaming until the stream ends.
pub fn streamContainerStats(
    client: *const http.Client,
    logger: *log.Logger,
    id: []const u8,
    writer: anytype,
) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/stats?stream=true", .{ api_prefix, id });
    defer client.allocator.free(path);

    try writer.print("{s:<14} {s:<20} {s:<9} {s:<24} {s:<9} {s}\n", .{
        "CONTAINER ID", "NAME", "CPU %", "MEM USAGE / LIMIT", "MEM %", "PIDS",
    });

    logger.debug("STREAM GET {s}", .{path});
    const WriterType = @TypeOf(writer);
    var ctx = StatsStreamCtx(WriterType){
        .allocator = client.allocator,
        .id = id,
        .writer = writer,
    };
    defer ctx.deinit();

    const resp = try client.streamRequest(
        "GET",
        path,
        null,
        http.blocking_timeout_ms,
        &ctx,
        StatsStreamCtx(WriterType).onChunk,
    );
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "GET", path, err_resp);
    }
    try ctx.flush();
    logger.info("streamed {d} stats frame(s) for container {s}", .{ ctx.frames, utils.shortId(id) });
}

fn fetchStatsJsonEntry(
    client: *const http.Client,
    logger: *log.Logger,
    id: []const u8,
    writer: anytype,
    first: bool,
) !void {
    try validateIdentifier(id);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/stats?stream=false", .{ api_prefix, id });
    defer client.allocator.free(path);

    logger.debug("GET {s}", .{path});
    const resp = try client.request("GET", path, null);
    defer resp.deinit();
    if (!resp.ok()) return logApiFailure(logger, "GET", path, resp);

    const parsed = try std.json.parseFromSlice(ContainerStats, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const s = parsed.value;
    const entry = StatsJsonEntry{
        .id = if (s.id.len > 0) s.id else id,
        .name = std.mem.trimStart(u8, s.name, "/"),
        .cpu_percent = computeCpuPercent(s),
        .mem_used_bytes = computeMemoryUsage(s.memory_stats).used,
        .mem_limit_bytes = computeMemoryUsage(s.memory_stats).limit,
        .mem_percent = computeMemoryUsage(s.memory_stats).percent,
        .pids = if (s.pids_stats) |p| p.current orelse 0 else 0,
    };

    const item_json = try std.json.Stringify.valueAlloc(client.allocator, entry, .{});
    defer client.allocator.free(item_json);
    if (!first) try writer.writeByte(',');
    try writer.writeAll(item_json);
}

/// Emits a JSON array of computed container resource metrics (`zigpod stats --json`).
pub fn statsContainersJson(
    client: *const http.Client,
    logger: *log.Logger,
    containers: []const []const u8,
    all: bool,
    writer: anytype,
) !void {
    if (containers.len > 0) {
        for (containers) |c| try validateIdentifier(c);
        try writer.writeByte('[');
        for (containers, 0..) |c, idx| {
            try fetchStatsJsonEntry(client, logger, c, writer, idx == 0);
        }
        try writer.writeAll("]\n");
        logger.info("fetched JSON stats for {d} container(s)", .{containers.len});
        return;
    }

    const list_path = try std.fmt.allocPrint(
        client.allocator,
        "{s}/containers/json?all={s}",
        .{ api_prefix, if (all) "true" else "false" },
    );
    defer client.allocator.free(list_path);

    logger.debug("GET {s}", .{list_path});
    const list_resp = try client.request("GET", list_path, null);
    defer list_resp.deinit();
    if (!list_resp.ok()) return logApiFailure(logger, "GET", list_path, list_resp);

    const list_parsed = try std.json.parseFromSlice([]ContainerSummary, client.allocator, list_resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer list_parsed.deinit();

    for (list_parsed.value) |c| try validateIdentifier(c.Id);

    try writer.writeByte('[');
    for (list_parsed.value, 0..) |c, idx| {
        try fetchStatsJsonEntry(client, logger, c.Id, writer, idx == 0);
    }
    try writer.writeAll("]\n");
    logger.info("fetched JSON stats for {d} container(s)", .{list_parsed.value.len});
}

/// Demultiplexes Docker/Podman attached log frames ([stream_type, 0, 0, 0, size_be32][payload...]).
/// Falls back to writing `raw` verbatim when the payload is plain text (e.g., TTY containers).
pub fn demuxLogs(raw: []const u8, writer: anytype) !void {
    if (raw.len == 0) return;

    var pos: usize = 0;
    var valid_frames = false;
    while (raw.len - pos >= 8) {
        const stream_type = raw[pos];
        if (stream_type > 2 or raw[pos + 1] != 0 or raw[pos + 2] != 0 or raw[pos + 3] != 0) {
            valid_frames = false;
            break;
        }
        const size = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big);
        const next_pos = std.math.add(usize, pos + 8, @as(usize, size)) catch {
            valid_frames = false;
            break;
        };
        if (next_pos > raw.len) {
            valid_frames = false;
            break;
        }
        valid_frames = true;
        pos = next_pos;
        if (pos == raw.len) break;
    } else {
        valid_frames = false;
    }

    if (!valid_frames or pos != raw.len) {
        try writer.writeAll(raw);
        return;
    }

    pos = 0;
    while (raw.len - pos >= 8) {
        const size = std.mem.readInt(u32, raw[pos + 4 ..][0..4], .big);
        const start = pos + 8;
        const end = start + @as(usize, size);
        try writer.writeAll(raw[start..end]);
        pos = end;
    }
}

// ---------------------------------------------------------------- tests

test "demuxLogs handles multiplexed docker stream frames and zero-length frame" {
    const frame = [_]u8{
        1, 0, 0,   0,   0,   0,    0, 6, 'h', 'e', 'l', 'l', 'o', '\n',
        1, 0, 0,   0,   0,   0,    0, 0, 2,   0,   0,   0,   0,   0,
        0, 4, 'e', 'r', 'r', '\n',
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs(&frame, &out.writer);
    try std.testing.expectEqualStrings("hello\nerr\n", out.written());
}

test "demuxLogs falls back to plain text on malformed frames" {
    const plain = "plain log output\nline 2\n";
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs(plain, &out.writer);
    try std.testing.expectEqualStrings(plain, out.written());

    // Invalid stream type 3
    out.writer.end = 0;
    const bad_stream = [_]u8{ 3, 0, 0, 0, 0, 0, 0, 2, 'h', 'i' };
    try demuxLogs(&bad_stream, &out.writer);
    try std.testing.expectEqualSlices(u8, &bad_stream, out.written());

    // Non-zero reserved byte
    out.writer.end = 0;
    const bad_reserved = [_]u8{ 1, 0, 1, 0, 0, 0, 0, 2, 'h', 'i' };
    try demuxLogs(&bad_reserved, &out.writer);
    try std.testing.expectEqualSlices(u8, &bad_reserved, out.written());

    // Frame size exceeds buffer length
    out.writer.end = 0;
    const truncated_payload = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 99, 'h', 'i' };
    try demuxLogs(&truncated_payload, &out.writer);
    try std.testing.expectEqualSlices(u8, &truncated_payload, out.written());

    // Truncated header (< 8 bytes)
    out.writer.end = 0;
    const short_hdr = [_]u8{ 1, 0, 0, 0, 0 };
    try demuxLogs(&short_hdr, &out.writer);
    try std.testing.expectEqualSlices(u8, &short_hdr, out.written());
}

test "demuxLogs handles empty slice" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demuxLogs("", &out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "computeCpuPercent and computeMemoryUsage handle normal and boundary cases" {
    const s = ContainerStats{
        .cpu_stats = .{
            .cpu_usage = .{ .total_usage = 200_000_000 },
            .system_cpu_usage = 2_000_000_000,
            .online_cpus = 4,
        },
        .precpu_stats = .{
            .cpu_usage = .{ .total_usage = 100_000_000 },
            .system_cpu_usage = 1_000_000_000,
        },
        .memory_stats = .{
            .usage = 100 * 1024 * 1024,
            .limit = 512 * 1024 * 1024,
            .stats = .{ .inactive_file = 36 * 1024 * 1024 },
        },
    };
    // (100M / 1000M) * 4 * 100 = 40.0%
    try std.testing.expectApproxEqAbs(@as(f64, 40.0), computeCpuPercent(s), 0.001);

    const mem = computeMemoryUsage(s.memory_stats);
    try std.testing.expectEqual(@as(u64, 64 * 1024 * 1024), mem.used);
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), mem.limit);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), mem.percent, 0.001);

    // Underflow / zero / missing stats must return 0 safely without panic.
    const empty = ContainerStats{};
    try std.testing.expectEqual(@as(f64, 0.0), computeCpuPercent(empty));
    const zero_mem = computeMemoryUsage(null);
    try std.testing.expectEqual(@as(u64, 0), zero_mem.used);
    try std.testing.expectEqual(@as(f64, 0.0), zero_mem.percent);

    const underflow = ContainerStats{
        .cpu_stats = .{
            .cpu_usage = .{ .total_usage = 50 },
            .system_cpu_usage = 100,
        },
        .precpu_stats = .{
            .cpu_usage = .{ .total_usage = 100 },
            .system_cpu_usage = 200,
        },
        .memory_stats = .{
            .usage = 100,
            .limit = 0,
            .stats = .{ .cache = 200 },
        },
    };
    try std.testing.expectEqual(@as(f64, 0.0), computeCpuPercent(underflow));
    const umem = computeMemoryUsage(underflow.memory_stats);
    try std.testing.expectEqual(@as(u64, 0), umem.used);
    try std.testing.expectEqual(@as(f64, 0.0), umem.percent);
}

test "statsContainers fetches metrics via mock Unix socket and enforces identifier guard" {
    const sock_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zp-stats-test-{d}.sock",
        .{Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer std.testing.allocator.free(sock_path);
    Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const list_json = "[{\"Id\":\"abcdef1234567890\",\"Image\":\"alpine:3.20\",\"Status\":\"Up\",\"Names\":[\"/web\"]}]";
    const list_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ list_json.len, list_json },
    );
    const stats_json =
        "{\"id\":\"abcdef1234567890\",\"name\":\"/web\"," ++
        "\"cpu_stats\":{\"cpu_usage\":{\"total_usage\":200000000},\"system_cpu_usage\":2000000000,\"online_cpus\":2}," ++
        "\"precpu_stats\":{\"cpu_usage\":{\"total_usage\":100000000},\"system_cpu_usage\":1000000000}," ++
        "\"memory_stats\":{\"usage\":67108864,\"limit\":268435456,\"stats\":{\"inactive_file\":16777216}}," ++
        "\"pids_stats\":{\"current\":12}}";
    const stats_resp = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ stats_json.len, stats_json },
    );

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/containers/json?all=false HTTP/1.1\r\n",
            .raw_response = list_resp,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/abcdef1234567890/stats?stream=false HTTP/1.1\r\n",
            .raw_response = stats_resp,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/stats?stream=false HTTP/1.1\r\n",
            .raw_response = stats_resp,
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    const client = http.Client{
        .allocator = std.testing.allocator,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    defer logger.deinit();

    // Invalid identifier must be rejected before any socket traffic.
    var bad_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bad_out.deinit();
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        statsContainers(&client, &logger, &.{"../bad"}, false, &bad_out.writer),
    );

    // 1) All running containers (empty list -> GET /containers/json -> GET /stats?stream=false)
    var out1: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out1.deinit();
    try statsContainers(&client, &logger, &.{}, false, &out1.writer);
    try std.testing.expect(std.mem.indexOf(u8, out1.written(), "CONTAINER ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.written(), "abcdef123456") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.written(), "web") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.written(), "20.00%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.written(), "48.0 MB / 256.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.written(), "18.75%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1.written(), "12") != null);

    // 2) Explicit container name
    var out2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out2.deinit();
    try statsContainers(&client, &logger, &.{"web"}, false, &out2.writer);
    try std.testing.expect(std.mem.indexOf(u8, out2.written(), "48.0 MB / 256.0 MB") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "LogDemuxer handles split frames and raw TTY passthrough" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var d = LogDemuxer(*std.Io.Writer){
        .allocator = std.testing.allocator,
        .writer = &out.writer,
    };
    defer d.deinit();

    // Split an 8-byte header + 5-byte payload across multiple pushes.
    const frame = "\x01\x00\x00\x00\x00\x00\x00\x05hello\x02\x00\x00\x00\x00\x00\x00\x06 world";
    try d.push(frame[0..4]);
    try d.push(frame[4..10]);
    try d.push(frame[10..]);
    try d.flush();
    try std.testing.expectEqualStrings("hello world", out.written());

    // Raw TTY text without multiplexed header.
    var raw_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer raw_out.deinit();
    var d_raw = LogDemuxer(*std.Io.Writer){
        .allocator = std.testing.allocator,
        .writer = &raw_out.writer,
    };
    defer d_raw.deinit();
    try d_raw.push("plain tty ");
    try d_raw.push("output\n");
    try d_raw.flush();
    try std.testing.expectEqualStrings("plain tty output\n", raw_out.written());
}

test "fuzz demuxLogs and LogDemuxer with arbitrary split boundaries and random frames" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7a6967706f64);
    const rng = prng.random();

    // Part A: Differential property test — valid multiplexed stream split at random chunk sizes.
    var iter: usize = 0;
    while (iter < 48) : (iter += 1) {
        var wire: std.Io.Writer.Allocating = .init(alloc);
        defer wire.deinit();
        var expected: std.Io.Writer.Allocating = .init(alloc);
        defer expected.deinit();

        const num_frames = rng.intRangeAtMost(usize, 1, 8);
        var f: usize = 0;
        while (f < num_frames) : (f += 1) {
            const stream_type: u8 = if (rng.boolean()) 1 else 2;
            const payload_len = rng.intRangeAtMost(usize, 0, 64);
            var hdr: [8]u8 = .{ stream_type, 0, 0, 0, 0, 0, 0, 0 };
            std.mem.writeInt(u32, hdr[4..8], @intCast(payload_len), .big);
            try wire.writer.writeAll(&hdr);

            var payload_buf: [64]u8 = undefined;
            const payload = payload_buf[0..payload_len];
            rng.bytes(payload);
            try expected.writer.writeAll(payload);
            try wire.writer.writeAll(payload);
        }

        var oneshot_out: std.Io.Writer.Allocating = .init(alloc);
        defer oneshot_out.deinit();
        try demuxLogs(wire.written(), &oneshot_out.writer);
        try std.testing.expectEqualSlices(u8, expected.written(), oneshot_out.written());

        var stream_out: std.Io.Writer.Allocating = .init(alloc);
        defer stream_out.deinit();
        var demuxer = LogDemuxer(*std.Io.Writer){
            .allocator = alloc,
            .writer = &stream_out.writer,
        };
        defer demuxer.deinit();

        var pos: usize = 0;
        while (pos < wire.written().len) {
            const step = rng.intRangeAtMost(usize, 1, 19);
            const end = @min(wire.written().len, pos + step);
            try demuxer.push(wire.written()[pos..end]);
            pos = end;
        }
        try demuxer.flush();
        try std.testing.expectEqualSlices(u8, expected.written(), stream_out.written());
    }

    // Part B: Arbitrary/corrupted byte streams must never panic, overflow, or leak.
    var fuzz_i: usize = 0;
    while (fuzz_i < 160) : (fuzz_i += 1) {
        const len = rng.intRangeAtMost(usize, 0, 128);
        const buf = try alloc.alloc(u8, len);
        defer alloc.free(buf);
        rng.bytes(buf);

        var out1: std.Io.Writer.Allocating = .init(alloc);
        defer out1.deinit();
        try demuxLogs(buf, &out1.writer);

        var out2: std.Io.Writer.Allocating = .init(alloc);
        defer out2.deinit();
        var demuxer = LogDemuxer(*std.Io.Writer){
            .allocator = alloc,
            .writer = &out2.writer,
        };
        defer demuxer.deinit();

        var pos: usize = 0;
        while (pos < buf.len) {
            const step = rng.intRangeAtMost(usize, 1, 13);
            const end = @min(buf.len, pos + step);
            try demuxer.push(buf[pos..end]);
            pos = end;
        }
        try demuxer.flush();
    }
}

fn runStreamStatsMockServer(server: *Io.net.Server, io: Io) void {
    const frame1 =
        "{\"id\":\"abcdef1234567890\",\"name\":\"/web\"," ++
        "\"cpu_stats\":{\"cpu_usage\":{\"total_usage\":200000000},\"system_cpu_usage\":2000000000,\"online_cpus\":2}," ++
        "\"precpu_stats\":{\"cpu_usage\":{\"total_usage\":100000000},\"system_cpu_usage\":1000000000}," ++
        "\"memory_stats\":{\"usage\":33554432,\"limit\":268435456}," ++
        "\"pids_stats\":{\"current\":5}}\n";
    const frame2 =
        "{\"id\":\"abcdef1234567890\",\"name\":\"/web\"," ++
        "\"cpu_stats\":{\"cpu_usage\":{\"total_usage\":350000000},\"system_cpu_usage\":2500000000,\"online_cpus\":2}," ++
        "\"precpu_stats\":{\"cpu_usage\":{\"total_usage\":200000000},\"system_cpu_usage\":2000000000}," ++
        "\"memory_stats\":{\"usage\":67108864,\"limit\":268435456}," ++
        "\"pids_stats\":{\"current\":9}}\n";
    const raw = std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n{x}\r\n{s}\r\n0\r\n\r\n",
        .{ frame1.len, frame1, frame2.len, frame2 },
    );
    if (server.accept(io)) |conn| {
        defer conn.close(io);
        var req_buf: [512]u8 = undefined;
        var rdata = [_][]u8{&req_buf};
        _ = (io.operate(.{ .net_read = .{ .socket_handle = conn.socket.handle, .data = &rdata } }) catch return).net_read catch return;
        http_socket.http_socket_write(conn.socket.handle, raw);
    } else |_| {}
}

test "streamContainerStats streams live chunked JSON metrics (stream=true)" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-stream-stats-{d}.sock",
        .{Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const thread = try std.Thread.spawn(.{}, runStreamStatsMockServer, .{ &server, std.testing.io });
    var joined = false;
    defer if (!joined) thread.join();

    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();
    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = std.testing.io,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Reject path traversal identifier before any socket traffic.
    try std.testing.expectError(
        ApiError.InvalidIdentifier,
        streamContainerStats(&client, &logger, "../bad", &out.writer),
    );

    try streamContainerStats(&client, &logger, "web", &out.writer);
    thread.join();
    joined = true;

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "CONTAINER ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "20.00%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "32.0 MB / 256.0 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "60.00%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "64.0 MB / 256.0 MB") != null);
}
