//! Built-in 14-case fail-closed security and reliability self-test (`zigpod demo`).
const std = @import("std");
const cli = @import("cli.zig");
const http = @import("http.zig");
const log = @import("log.zig");
const pod = @import("podman_api.zig");

const total_cases: usize = 14;

/// Runs all 14 deterministic ALLOW/DENY enforcement checks without touching a live Podman daemon.
pub fn runSelfTest(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("zigpod security & reliability self-test (14 cases)\n");

    var idx: usize = 0;
    var passed: usize = 0;

    try recordCase(writer, &idx, &passed, "ALLOW", "hardened container CLI parse (-m 64m --pids-limit 32 --read-only --no-new-privileges)", checkHardenedCliParse(allocator));
    try recordCase(writer, &idx, &passed, "DENY", "reject invalid memory limit (-m 0)", expectParseError(allocator, &.{ "run", "-m", "0", "alpine" }, error.InvalidValue));
    try recordCase(writer, &idx, &passed, "DENY", "reject overflowing memory limit (--memory 99999999999999999g)", expectParseError(allocator, &.{ "run", "--memory", "99999999999999999g", "alpine" }, error.InvalidValue));
    try recordCase(writer, &idx, &passed, "DENY", "reject non-positive pids limit (--pids-limit 0)", expectParseError(allocator, &.{ "run", "--pids-limit", "0", "alpine" }, error.InvalidValue));

    try recordCase(writer, &idx, &passed, "DENY", "reject container identifier path traversal (../etc/passwd)", expectIdentifierDenied("../etc/passwd"));
    try recordCase(writer, &idx, &passed, "DENY", "reject container name query smuggling (web?force=true)", expectIdentifierDenied("web?force=true"));

    try recordCase(writer, &idx, &passed, "DENY", "reject HTTP request-target CRLF injection", expectTargetDenied("/v1.40/version\r\nX-Evil: 1"));
    try recordCase(writer, &idx, &passed, "DENY", "reject non-absolute HTTP request target", expectTargetDenied("v1.40/version"));
    try recordCase(writer, &idx, &passed, "DENY", "reject malformed HTTP response status line", expectMalformedResponseDenied(allocator));

    try recordCase(writer, &idx, &passed, "DENY", "enforce socket poll timeout on stalled daemon", try testSocketTimeout(allocator));
    try recordCase(writer, &idx, &passed, "ALLOW", "serialize hardened HostConfig JSON fields", try testHostConfigJson(allocator));
    try recordCase(writer, &idx, &passed, "ALLOW", "end-to-end hardened mock Podman container lifecycle", try testHardenedLifecycle(allocator));

    const audit_res = try testAuditChainAndTamper(allocator);
    try recordCase(writer, &idx, &passed, "ALLOW", "verify intact SHA-256 hash-chained audit.log", audit_res.chain_ok);
    try recordCase(writer, &idx, &passed, "DENY", "detect single-byte tampering in audit.log", audit_res.tamper_denied);

    try writer.print("demo: {d}/{d} cases passed (fail-closed enforcement verified)\n", .{ passed, total_cases });
    if (passed != total_cases) return error.DemoSelfTestFailed;
}

fn recordCase(
    writer: anytype,
    idx: *usize,
    passed: *usize,
    verdict: []const u8,
    label: []const u8,
    ok: bool,
) !void {
    idx.* += 1;
    if (ok) passed.* += 1;
    const status = if (ok) "PASS" else "FAIL";
    try writer.print("  [{d:>2}/{d}] {s:<5} {s} -> {s}\n", .{ idx.*, total_cases, verdict, label, status });
}

fn checkHardenedCliParse(allocator: std.mem.Allocator) bool {
    var parsed = cli.parse(allocator, &.{
        "run",
        "--rm",
        "-m",
        "64m",
        "--pids-limit",
        "32",
        "--read-only",
        "--no-new-privileges",
        "alpine:3.20",
        "echo",
        "ok",
    }) catch return false;
    defer parsed.deinit(allocator);

    switch (parsed.command) {
        .run => |r| return r.remove and
            r.read_only and
            r.no_new_privileges and
            r.memory == 64 * 1024 * 1024 and
            r.pids_limit == 32 and
            std.mem.eql(u8, r.image, "alpine:3.20") and
            r.cmd.len == 2,
        else => return false,
    }
}

fn expectParseError(allocator: std.mem.Allocator, args: []const []const u8, expected: cli.ParseError) bool {
    var parsed = cli.parse(allocator, args) catch |e| return e == expected;
    parsed.deinit(allocator);
    return false;
}

fn expectIdentifierDenied(name: []const u8) bool {
    pod.validateIdentifier(name) catch |e| return e == pod.ApiError.InvalidIdentifier;
    return false;
}

fn expectTargetDenied(path: []const u8) bool {
    http.validateRequestTarget(path) catch |e| return e == http.Error.InvalidRequestPath;
    return false;
}

fn expectMalformedResponseDenied(allocator: std.mem.Allocator) bool {
    const resp = http.parseResponse(allocator, "NONHTTP 200 OK\r\n\r\n") catch |e| {
        return e == http.Error.InvalidResponse;
    };
    resp.deinit();
    return false;
}

const TimeoutCtx = struct {
    server: *std.net.Server,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn runSilentServer(ctx: *TimeoutCtx) void {
    const conn = ctx.server.accept() catch return;
    defer conn.stream.close();
    while (!ctx.done.load(.acquire)) {
        std.time.sleep(2 * std.time.ns_per_ms);
    }
}

fn testSocketTimeout(allocator: std.mem.Allocator) !bool {
    const sock_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/zp-demo-to-{x:0>16}.sock",
        .{std.crypto.random.int(u64)},
    );
    defer allocator.free(sock_path);
    std.fs.cwd().deleteFile(sock_path) catch {};
    defer std.fs.cwd().deleteFile(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    var ctx = TimeoutCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runSilentServer, .{&ctx});
    var joined = false;
    defer {
        ctx.done.store(true, .release);
        if (!joined) thread.join();
    }

    const client = http.Client{
        .allocator = allocator,
        .socket_path = sock_path,
        .timeout_ms = 25,
    };
    const timed_out = if (client.request("GET", "/v1.40/_ping", null)) |resp| blk: {
        resp.deinit();
        break :blk false;
    } else |e| e == http.Error.Timeout;

    ctx.done.store(true, .release);
    thread.join();
    joined = true;
    return timed_out;
}

fn testHostConfigJson(allocator: std.mem.Allocator) !bool {
    const req = pod.ContainerCreateRequest{
        .Image = "alpine:3.20",
        .HostConfig = pod.HostConfig{
            .AutoRemove = true,
            .ReadonlyRootfs = true,
            .Memory = 67_108_864,
            .PidsLimit = 32,
            .SecurityOpt = &.{"no-new-privileges"},
        },
    };
    const json = try std.json.stringifyAlloc(allocator, req, .{ .emit_null_optional_fields = false });
    defer allocator.free(json);

    return std.mem.indexOf(u8, json, "\"ReadonlyRootfs\":true") != null and
        std.mem.indexOf(u8, json, "\"Memory\":67108864") != null and
        std.mem.indexOf(u8, json, "\"PidsLimit\":32") != null and
        std.mem.indexOf(u8, json, "\"SecurityOpt\":[\"no-new-privileges\"]") != null;
}

const ScriptedReply = struct {
    expected_prefix: []const u8,
    must_contain: ?[]const u8 = null,
    raw_response: []const u8,
};

const MockServerCtx = struct {
    server: *std.net.Server,
    replies: []const ScriptedReply,
    matched: usize = 0,
};

fn readHttpRequest(stream: std.net.Stream, buf: []u8) ![]const u8 {
    var total: usize = 0;
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

fn runMockPodmanServer(ctx: *MockServerCtx) void {
    var buf: [4096]u8 = undefined;
    for (ctx.replies) |reply| {
        const conn = ctx.server.accept() catch return;
        defer conn.stream.close();
        const req = readHttpRequest(conn.stream, &buf) catch return;
        if (std.mem.startsWith(u8, req, reply.expected_prefix)) {
            if (reply.must_contain) |needle| {
                if (std.mem.indexOf(u8, req, needle) != null) ctx.matched += 1;
            } else {
                ctx.matched += 1;
            }
        }
        conn.stream.writeAll(reply.raw_response) catch return;
    }
}

fn testHardenedLifecycle(allocator: std.mem.Allocator) !bool {
    const sock_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/zp-demo-lc-{x:0>16}.sock",
        .{std.crypto.random.int(u64)},
    );
    defer allocator.free(sock_path);
    std.fs.cwd().deleteFile(sock_path) catch {};
    defer std.fs.cwd().deleteFile(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const create_body = "{\"Id\":\"demo1234567890abcd\"}";
    const wait_body = "{\"StatusCode\":0}";
    const ps_body = "[{\"Id\":\"demo1234567890abcd\",\"Image\":\"alpine:3.20\",\"Status\":\"Exited (0)\",\"Names\":[\"/demo-box\"]}]";
    const log_raw = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n\x01\x00\x00\x00\x00\x00\x00\x03hi\n";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo-box HTTP/1.1\r\n",
            .must_contain = "\"ReadonlyRootfs\":true",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}", .{ create_body.len, create_body }),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/demo1234567890abcd/start HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/demo1234567890abcd/wait HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ wait_body.len, wait_body }),
        },
        .{
            .expected_prefix = "GET /v1.40/containers/demo1234567890abcd/logs?stdout=1&stderr=1 HTTP/1.1\r\n",
            .raw_response = log_raw,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/json?all=true HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ ps_body.len, ps_body }),
        },
    };

    var ctx = MockServerCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = allocator,
        .socket_path = sock_path,
    };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    const req = pod.ContainerCreateRequest{
        .Image = "alpine:3.20",
        .Cmd = &.{ "echo", "hi" },
        .HostConfig = pod.HostConfig{
            .AutoRemove = true,
            .ReadonlyRootfs = true,
            .Memory = 67_108_864,
            .PidsLimit = 32,
            .SecurityOpt = &.{"no-new-privileges"},
        },
    };
    const id = try pod.createContainer(&client, &logger, req, "demo-box");
    defer allocator.free(id);

    try pod.startContainer(&client, &logger, id);
    const exit_code = try pod.waitContainer(&client, &logger, id);

    var logs_out = std.ArrayList(u8).init(allocator);
    defer logs_out.deinit();
    try pod.fetchLogs(&client, &logger, id, false, logs_out.writer());

    var ps_out = std.ArrayList(u8).init(allocator);
    defer ps_out.deinit();
    try pod.listContainers(&client, &logger, true, ps_out.writer());

    thread.join();
    joined = true;

    return ctx.matched == replies.len and
        exit_code == 0 and
        std.mem.eql(u8, logs_out.items, "hi\n") and
        std.mem.indexOf(u8, ps_out.items, "demo12345678") != null and
        std.mem.indexOf(u8, ps_out.items, "demo-box") != null;
}

const AuditCheckResult = struct {
    chain_ok: bool,
    tamper_denied: bool,
};

fn testAuditChainAndTamper(allocator: std.mem.Allocator) !AuditCheckResult {
    const demo_dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/zp-demo-audit-{x:0>16}",
        .{std.crypto.random.int(u64)},
    );
    defer allocator.free(demo_dir);
    std.fs.cwd().deleteTree(demo_dir) catch {};
    defer std.fs.cwd().deleteTree(demo_dir) catch {};
    try std.fs.cwd().makePath(demo_dir);

    {
        var logger = log.Logger.init(demo_dir, false);
        logger.echo_stderr = false;
        defer logger.deinit();
        logger.info("demo audit entry one", .{});
        logger.info("demo audit entry two", .{});
    }

    const audit_path = try std.fs.path.join(allocator, &.{ demo_dir, "audit.log" });
    defer allocator.free(audit_path);

    const count = log.verifyAuditFile(allocator, audit_path) catch 0;
    const chain_ok = (count == 2);

    {
        const f = try std.fs.cwd().openFile(audit_path, .{ .mode = .read_write });
        defer f.close();
        const stat = try f.stat();
        if (stat.size < 4) return .{ .chain_ok = chain_ok, .tamper_denied = false };
        var b: [1]u8 = undefined;
        try f.seekTo(stat.size - 2);
        _ = try f.readAll(&b);
        b[0] ^= 0x01;
        try f.seekTo(stat.size - 2);
        try f.writeAll(&b);
    }

    const tamper_denied = if (log.verifyAuditFile(allocator, audit_path)) |_|
        false
    else |e|
        e == log.AuditError.AuditTampered;

    return .{ .chain_ok = chain_ok, .tamper_denied = tamper_denied };
}

test "demo self-test suite passes with zero memory leaks" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try runSelfTest(std.testing.allocator, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "14/14 cases passed") != null);
}
