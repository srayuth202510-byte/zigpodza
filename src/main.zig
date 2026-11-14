//! zigpod CLI entry point.
const std = @import("std");
const cli = @import("cli.zig");
const completion = @import("completion.zig");
const config = @import("config.zig");
const demo = @import("demo.zig");
const http = @import("http.zig");
const log = @import("log.zig");
const pod = @import("podman_api.zig");
const policy = @import("policy.zig");

pub const version = "0.1.0";

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var code = run(gpa.allocator());
    if (gpa.deinit() == .leak) {
        std.io.getStdErr().writer().writeAll("zigpod: internal error: memory leak detected\n") catch {};
        if (code == 0) code = 1;
    }
    return code;
}

fn run(gpa_allocator: std.mem.Allocator) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var it = std.process.argsWithAllocator(arena) catch |e| {
        stderr.print("zigpod: failed to read process arguments: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    _ = it.next(); // skip program name

    var arg_list = std.ArrayList([]const u8).init(arena);
    while (it.next()) |arg| {
        arg_list.append(arg) catch {
            stderr.writeAll("zigpod: out of memory\n") catch {};
            return 1;
        };
    }

    const parsed = cli.parse(arena, arg_list.items) catch |e| {
        stderr.print("zigpod: {s}\nTry 'zigpod --help' for usage.\n", .{cli.describeError(e)}) catch {};
        return 2;
    };

    switch (parsed.command) {
        .help => {
            stdout.writeAll(cli.usage) catch {};
            return 0;
        },
        .client_version => {
            stdout.print("zigpod version {s}\n", .{version}) catch {};
            return 0;
        },
        .demo => {
            demo.runSelfTest(gpa_allocator, stdout) catch |e| {
                stderr.print("zigpod: demo failed: {s}\n", .{@errorName(e)}) catch {};
                return 1;
            };
            return 0;
        },
        .completion => |shell| {
            completion.writeCompletion(shell, stdout) catch |e| {
                stderr.print("zigpod: completion failed: {s}\n", .{@errorName(e)}) catch {};
                return 1;
            };
            return 0;
        },
        else => {},
    }

    const cfg = config.Config.load(arena, parsed.global.socket) catch |e| {
        stderr.print("zigpod: failed to load config: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };

    switch (parsed.command) {
        .audit => |audit_opts| {
            const audit_path = if (audit_opts.path) |p|
                p
            else
                std.fs.path.join(arena, &.{ cfg.log_dir, "audit.log" }) catch {
                    stderr.writeAll("zigpod: out of memory\n") catch {};
                    return 1;
                };
            if (audit_opts.json) {
                const ok = log.writeAuditJson(arena, audit_path, stdout) catch |e| {
                    stderr.print(
                        "zigpod: audit JSON verification failed for '{s}': {s}\n",
                        .{ audit_path, @errorName(e) },
                    ) catch {};
                    return 1;
                };
                return if (ok) 0 else 1;
            }
            const count = log.verifyAuditFile(arena, audit_path) catch |e| {
                if (e == error.StreamTooLong) {
                    stderr.print(
                        "zigpod: audit file '{s}' exceeds the 64 MiB verification limit\n",
                        .{audit_path},
                    ) catch {};
                } else {
                    stderr.print(
                        "zigpod: audit verification failed for '{s}': {s}\n",
                        .{ audit_path, @errorName(e) },
                    ) catch {};
                }
                return 1;
            };
            stdout.print("audit chain verified ({d} entries, path={s})\n", .{ count, audit_path }) catch {};
            return 0;
        },
        else => {},
    }

    var logger = log.Logger.init(cfg.log_dir, parsed.global.verbose);
    defer logger.deinit();

    logger.info("zigpod {s} command={s} socket={s}", .{
        version,
        @tagName(parsed.command),
        cfg.socket_path,
    });

    const client = http.Client{
        .allocator = arena,
        .socket_path = cfg.socket_path,
    };

    return dispatch(&client, &logger, parsed.command, stdout) catch |e| {
        reportFailure(&logger, parsed.command, cfg.socket_path, e);
        return 1;
    };
}

fn dispatch(
    client: *const http.Client,
    logger: *log.Logger,
    cmd: cli.Command,
    stdout: anytype,
) !u8 {
    switch (cmd) {
        .help, .client_version, .demo, .audit, .completion => return 0,
        .ps => |opts| if (opts.json)
            try pod.listContainersJson(client, logger, opts.all, stdout)
        else
            try pod.listContainers(client, logger, opts.all, stdout),
        .images => |opts| if (opts.json)
            try pod.listImagesJson(client, logger, stdout)
        else
            try pod.listImages(client, logger, stdout),
        .pull => |image| try pod.pullImage(client, logger, image, stdout),
        .rmi => |opts| try pod.removeImage(client, logger, opts.image, opts.force, stdout),
        .start => |container| try pod.startContainer(client, logger, container),
        .stop => |container| try pod.stopContainer(client, logger, container),
        .restart => |opts| try pod.restartContainer(client, logger, opts.container, opts.timeout_secs),
        .pause => |container| try pod.pauseContainer(client, logger, container),
        .unpause => |container| try pod.unpauseContainer(client, logger, container),
        .rename => |opts| try pod.renameContainer(client, logger, opts.container, opts.new_name),
        .kill => |opts| try pod.killContainer(client, logger, opts.container, opts.signal),
        .rm => |opts| try pod.removeContainer(client, logger, opts.container, opts.force),
        .logs => |opts| try pod.fetchLogs(client, logger, opts.container, opts.follow, stdout),
        .top => |container| try pod.topContainer(client, logger, container, stdout),
        .inspect => |opts| if (opts.json)
            try pod.inspectJson(client, logger, opts.target, stdout)
        else
            try pod.inspect(client, logger, opts.target, stdout),
        .volume => |v| switch (v.action) {
            .ls => try pod.listVolumes(client, logger, stdout),
            .create => try pod.createVolume(client, logger, v.name.?, stdout),
            .rm => try pod.removeVolume(client, logger, v.name.?, v.force),
            .inspect => try pod.inspectVolume(client, logger, v.name.?, stdout),
        },
        .network => |n| switch (n.action) {
            .ls => try pod.listNetworks(client, logger, stdout),
            .inspect => try pod.inspectNetwork(client, logger, n.name.?, stdout),
        },
        .system => |s| switch (s.action) {
            .ping => try pod.systemPing(client, logger, stdout),
            .df => try pod.systemDf(client, logger, stdout),
            .prune => try pod.systemPrune(client, logger, stdout),
        },
        .port => |opts| try pod.portContainer(client, logger, opts.container, opts.private_port, stdout),
        .wait => |container| {
            const code = try pod.waitContainer(client, logger, container);
            try stdout.print("{d}\n", .{code});
        },
        .diff => |container| try pod.diffContainer(client, logger, container, stdout),
        .events => |opts| try pod.fetchEvents(client, logger, opts.since, opts.until, opts.json, stdout),
        .stats => |opts| {
            if (opts.json) {
                try pod.statsContainersJson(client, logger, opts.containers, opts.all, stdout);
            } else if (!opts.no_stream and opts.containers.len == 1) {
                try pod.streamContainerStats(client, logger, opts.containers[0], stdout);
            } else {
                try pod.statsContainers(client, logger, opts.containers, opts.all, stdout);
            }
        },
        .exec => |opts| {
            const req = pod.ExecCreateRequest{
                .AttachStdin = opts.interactive,
                .Tty = opts.tty,
                .Cmd = opts.cmd,
                .Env = if (opts.env.len > 0) opts.env else null,
                .User = opts.user,
                .WorkingDir = opts.workdir,
            };
            const stdin_fd: ?std.posix.fd_t = if (opts.interactive or opts.tty) std.io.getStdIn().handle else null;
            const code = try pod.execCommandWithIo(client, logger, opts.container, req, stdin_fd, stdout);
            return if (code > 0 and code <= 255) @intCast(code) else if (code == 0) 0 else 1;
        },
        .version => try pod.showVersion(client, logger, version, stdout),
        .run => |r_orig| {
            var r = r_orig;
            var tmpfs_bounds: ?pod.TmpfsBounds = null;
            var loaded_pol: ?std.json.Parsed(policy.Policy) = null;
            defer if (loaded_pol) |lp| lp.deinit();

            if (r.profile == .sandbox or r.policy_path != null) {
                if (r.profile == .sandbox) {
                    policy.applySandboxDefaults(&r);
                }

                const active_pol: policy.Policy = if (r.policy_path) |p_path| blk: {
                    loaded_pol = try policy.loadPolicyFile(client.allocator, p_path);
                    break :blk loaded_pol.?.value;
                } else blk: {
                    // Use ./zigpod-policy.json when present; otherwise use built-in fail-closed defaults.
                    if (std.fs.cwd().access("zigpod-policy.json", .{})) |_| {
                        loaded_pol = try policy.loadPolicyFile(client.allocator, "zigpod-policy.json");
                        break :blk loaded_pol.?.value;
                    } else |_| {
                        break :blk policy.default_sandbox_policy;
                    }
                };

                if (policy.checkRunPolicy(r, active_pol)) |violated_rule| {
                    logger.deny(violated_rule, "container run rejected by pre-flight sandbox policy");
                    return pod.ApiError.PolicyViolation;
                }
                tmpfs_bounds = .{ .tmp_options = active_pol.tmpfs_tmp_options };
            }

            // Validate and classify each -v mount (bind vs named volume).
            var mount_buf = std.ArrayList(pod.Mount).init(client.allocator);
            defer mount_buf.deinit();
            for (r.volumes) |v| {
                try mount_buf.append(try pod.makeMount(v.source, v.destination, v.readonly));
            }

            // Validate each published port mapping.
            var port_buf = std.ArrayList(pod.PortMapping).init(client.allocator);
            defer port_buf.deinit();
            for (r.ports) |p| {
                try port_buf.append(try pod.makePortMapping(p.host_ip, p.host_port, p.container_port, p.proto));
            }
            var has_binding = false;
            for (port_buf.items) |p| {
                if (p.host_port != null) {
                    has_binding = true;
                    break;
                }
            }

            // Validate identity/network/capability flags before touching the socket.
            if (r.network) |m| try pod.validateNetworkMode(m);
            if (r.workdir) |w| try pod.validateWorkdir(w);
            if (r.user) |u| try pod.validateUser(u);
            for (r.cap_drop) |c| try pod.validateCapability(c);
            for (r.cap_add) |c| try pod.validateCapability(c);

            // Defer removal until after fetchLogs when attached so output is not lost.
            const auto_remove = r.detach and r.remove;
            const has_host_cfg = auto_remove or
                r.read_only or
                r.no_new_privileges or
                r.memory != null or
                r.pids_limit != null or
                has_binding or
                r.network != null or
                r.cap_drop.len > 0 or
                r.cap_add.len > 0 or
                tmpfs_bounds != null;
            const sec_opts: []const []const u8 = &.{"no-new-privileges"};
            const host_cfg: ?pod.HostConfig = if (has_host_cfg) .{
                .AutoRemove = auto_remove,
                .ReadonlyRootfs = r.read_only,
                .Memory = r.memory,
                .PidsLimit = r.pids_limit,
                .SecurityOpt = if (r.no_new_privileges) sec_opts else null,
                .PortBindings = if (has_binding) .{ .ports = port_buf.items } else null,
                .NetworkMode = r.network,
                .CapDrop = if (r.cap_drop.len > 0) r.cap_drop else null,
                .CapAdd = if (r.cap_add.len > 0) r.cap_add else null,
                .Tmpfs = tmpfs_bounds,
            } else null;

            const req = pod.ContainerCreateRequest{
                .Image = r.image,
                .Cmd = if (r.cmd.len > 0) r.cmd else null,
                .Env = if (r.env.len > 0) r.env else null,
                .ExposedPorts = if (port_buf.items.len > 0) .{ .ports = port_buf.items } else null,
                .WorkingDir = r.workdir,
                .User = r.user,
                .AttachStdin = r.interactive,
                .OpenStdin = r.interactive,
                .AttachStdout = !r.detach and (r.interactive or r.tty),
                .AttachStderr = !r.detach and (r.interactive or r.tty),
                .Tty = r.tty,
                .Mounts = if (mount_buf.items.len > 0) mount_buf.items else null,
                .HostConfig = host_cfg,
            };
            const id = try pod.createContainer(client, logger, req, r.name);
            defer client.allocator.free(id);
            pod.startContainer(client, logger, id) catch |e| {
                // BUG-012: never leave behind a container we just created.
                pod.removeContainer(client, logger, id, true) catch {};
                return e;
            };

            if (r.detach) {
                try stdout.print("{s}\n", .{id});
                return 0;
            }

            if (r.interactive or r.tty) {
                pod.attachContainer(client, logger, id, r.interactive, r.tty, std.io.getStdIn().handle, stdout) catch |e| {
                    if (r.remove) pod.removeContainer(client, logger, id, true) catch {};
                    return e;
                };
                const status = try pod.waitContainer(client, logger, id);
                if (r.remove) try pod.removeContainer(client, logger, id, false);
                if (status != 0) {
                    return if (status > 0 and status <= 255) @intCast(status) else 1;
                }
                return 0;
            }

            const status = try pod.waitContainer(client, logger, id);
            if (r.remove) {
                // BUG-012: honor --rm even when fetching logs fails; the
                // container has already exited by the time wait returns.
                pod.fetchLogs(client, logger, id, false, stdout) catch |e| {
                    pod.removeContainer(client, logger, id, false) catch {};
                    return e;
                };
                try pod.removeContainer(client, logger, id, false);
            } else {
                try pod.fetchLogs(client, logger, id, false, stdout);
            }
            if (status != 0) {
                return if (status > 0 and status <= 255) @intCast(status) else 1;
            }
        },
    }
    return 0;
}

fn reportFailure(logger: *log.Logger, cmd: cli.Command, socket_path: []const u8, err: anyerror) void {
    switch (err) {
        http.Error.SocketNotFound => logger.err(
            "Podman socket not found at '{s}'. Start it with 'systemctl --user start podman.socket' or 'podman system service -t 0'.",
            .{socket_path},
        ),
        http.Error.DaemonNotRunning => logger.err(
            "Connection refused on '{s}'. Is the Podman service running?",
            .{socket_path},
        ),
        http.Error.PermissionDenied => logger.err(
            "Permission denied accessing Podman socket '{s}'.",
            .{socket_path},
        ),
        http.Error.Timeout => logger.err(
            "Timed out waiting for response from Podman socket '{s}'.",
            .{socket_path},
        ),
        http.Error.InvalidResponse => logger.err(
            "Invalid HTTP response from Podman socket '{s}'.",
            .{socket_path},
        ),
        http.Error.InvalidRequestPath => logger.deny(
            "http.validateRequestTarget",
            "Rejected invalid HTTP request path.",
        ),
        pod.ApiError.InvalidIdentifier => logger.deny(
            "api.validateIdentifier",
            "Invalid container identifier or name (allowed: alphanumeric, '-', '_', '.', ':').",
        ),
        pod.ApiError.InvalidHostPath => logger.deny(
            "api.validateHostPath",
            "Rejected unsafe host path or volume name. Bind mounts must be absolute, traversal-free, and may not target /, /etc, /proc, /sys, /dev, /boot, /run, /root, or container-engine state; sensitive /etc files are read-only.",
        ),
        pod.ApiError.InvalidMountTarget => logger.deny(
            "api.validateContainerPath",
            "Rejected invalid container mount target (must be an absolute, traversal-free path).",
        ),
        pod.ApiError.InvalidPort => logger.deny(
            "api.validatePortMapping",
            "Rejected invalid port mapping. Use [IP:]HOST:CONTAINER[/tcp|udp|sctp] with ports 1-65535 and an IPv4 host address.",
        ),
        pod.ApiError.InvalidNetwork => logger.deny(
            "api.validateNetworkMode",
            "Rejected invalid --network mode. Use none, bridge, host, pasta, or slirp4netns.",
        ),
        pod.ApiError.InvalidWorkdir => logger.deny(
            "api.validateWorkdir",
            "Rejected invalid --workdir (must be an absolute, traversal-free container path).",
        ),
        pod.ApiError.InvalidUser => logger.deny(
            "api.validateUser",
            "Rejected invalid --user. Use USER or USER:GROUP (alphanumerics plus '_', '-', '.').",
        ),
        pod.ApiError.InvalidCapability => logger.deny(
            "api.validateCapability",
            "Rejected invalid capability name. Use ALL or an uppercase name such as NET_ADMIN.",
        ),
        pod.ApiError.InvalidSignal => logger.deny(
            "api.validateSignal",
            "Rejected invalid kill signal. Allowed: SIGTERM, SIGKILL, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2.",
        ),
        pod.ApiError.InvalidPolicyFile => logger.deny(
            "policy.loadPolicyFile",
            "Rejected missing or malformed policy file (zigpod-policy.json).",
        ),
        pod.ApiError.PolicyViolation => {
            // Specific rule already recorded via logger.deny in dispatch.
        },
        pod.ApiError.PodmanApiError => {
            // Already logged with HTTP status and response details by podman_api.
        },
        pod.ApiError.NotFound => {
            // Already logged with the target name by podman_api.inspect.
        },
        else => logger.err("command '{s}' failed: {s}", .{ @tagName(cmd), @errorName(err) }),
    }
}

test {
    _ = cli;
    _ = completion;
    _ = config;
    _ = demo;
    _ = http;
    _ = log;
    _ = pod;
    _ = policy;
    _ = @import("utils.zig");
    std.testing.refAllDecls(@This());
}

const DispatchCleanupMockCtx = struct {
    server: *std.net.Server,
    saw_force_delete: bool = false,
    saw_rm_delete: bool = false,
};

fn runDispatchCleanupMockServer(ctx: *DispatchCleanupMockCtx) void {
    // Scenario 1: create (201) -> start (500) -> remove force=true (204)
    // Scenario 2: create (201) -> start (204) -> wait (200) -> logs (500) -> remove force=false (204)
    const steps = [_]struct {
        match: []const u8,
        reply: []const u8,
        mark_force: bool = false,
        mark_rm: bool = false,
    }{
        .{
            .match = "POST /v1.40/containers/create",
            .reply = "HTTP/1.1 201 Created\r\nContent-Length: 19\r\n\r\n{\"Id\":\"orphan1234\"}",
        },
        .{
            .match = "POST /v1.40/containers/orphan1234/start",
            .reply = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 29\r\n\r\n{\"message\":\"oci start error\"}",
        },
        .{
            .match = "DELETE /v1.40/containers/orphan1234?force=true",
            .reply = "HTTP/1.1 204 No Content\r\n\r\n",
            .mark_force = true,
        },
        .{
            .match = "POST /v1.40/containers/create",
            .reply = "HTTP/1.1 201 Created\r\nContent-Length: 15\r\n\r\n{\"Id\":\"rm1234\"}",
        },
        .{
            .match = "POST /v1.40/containers/rm1234/start",
            .reply = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .match = "POST /v1.40/containers/rm1234/wait",
            .reply = "HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\n{\"StatusCode\":0}",
        },
        .{
            .match = "GET /v1.40/containers/rm1234/logs?stdout=1&stderr=1",
            .reply = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 28\r\n\r\n{\"message\":\"log read error\"}",
        },
        .{
            .match = "DELETE /v1.40/containers/rm1234?force=false",
            .reply = "HTTP/1.1 204 No Content\r\n\r\n",
            .mark_rm = true,
        },
    };

    for (steps) |step| {
        const conn = ctx.server.accept() catch return;
        defer conn.stream.close();
        var req_buf: [1024]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch 0;
        if (std.mem.indexOf(u8, req_buf[0..n], step.match) != null) {
            if (step.mark_force) ctx.saw_force_delete = true;
            if (step.mark_rm) ctx.saw_rm_delete = true;
        }
        conn.stream.writeAll(step.reply) catch return;
    }
}

test "dispatch cleans up orphan container when startContainer or fetchLogs fails (BUG-012)" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-dispatch-bug012-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    var ctx = DispatchCleanupMockCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runDispatchCleanupMockServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
    };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    // 1) startContainer fails -> dispatch must force-remove orphan1234
    try std.testing.expectError(
        pod.ApiError.PodmanApiError,
        dispatch(&client, &logger, .{ .run = .{ .image = "alpine:3.20", .detach = true } }, out.writer()),
    );
    try std.testing.expect(ctx.saw_force_delete);

    // 2) run --rm where fetchLogs fails after waitContainer -> dispatch must remove rm1234
    try std.testing.expectError(
        pod.ApiError.PodmanApiError,
        dispatch(&client, &logger, .{ .run = .{ .image = "alpine:3.20", .remove = true } }, out.writer()),
    );
    try std.testing.expect(ctx.saw_rm_delete);

    thread.join();
    joined = true;
}

const SandboxMockCtx = struct {
    server: *std.net.Server,
    create_req_len: usize = 0,
    create_req_buf: [2048]u8 = undefined,
};

fn runSandboxDispatchMockServer(ctx: *SandboxMockCtx) void {
    // 1) POST /v1.40/containers/create
    if (ctx.server.accept()) |conn| {
        defer conn.stream.close();
        ctx.create_req_len = conn.stream.read(&ctx.create_req_buf) catch 0;
        conn.stream.writeAll(
            "HTTP/1.1 201 Created\r\nContent-Length: 19\r\n\r\n{\"Id\":\"sandbox999\"}",
        ) catch return;
    } else |_| return;

    // 2) POST /v1.40/containers/sandbox999/start
    if (ctx.server.accept()) |conn| {
        defer conn.stream.close();
        var buf: [512]u8 = undefined;
        _ = conn.stream.read(&buf) catch {};
        conn.stream.writeAll("HTTP/1.1 204 No Content\r\n\r\n") catch return;
    } else |_| return;
}

test "dispatch run --profile=sandbox serializes HostConfig.Tmpfs and logs DENY on policy violation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-dispatch-sandbox-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    var ctx = SandboxMockCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runSandboxDispatchMockServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
    };
    var logger = log.Logger.init(dir_path, false);
    defer logger.deinit();
    logger.echo_stderr = false;

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    // 1) Pre-flight violation: 512 MiB exceeds 256 MiB sandbox ceiling (rejected before socket I/O).
    try std.testing.expectError(
        pod.ApiError.PolicyViolation,
        dispatch(&client, &logger, .{
            .run = .{
                .image = "alpine:3.20",
                .profile = .sandbox,
                .memory = 512 * 1024 * 1024,
            },
        }, out.writer()),
    );

    // 2) Happy-path sandbox run (-d): applies defaults + Tmpfs bounds and starts container.
    const exit_code = try dispatch(&client, &logger, .{
        .run = .{
            .image = "alpine:3.20",
            .profile = .sandbox,
            .detach = true,
        },
    }, out.writer());
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("sandbox999\n", out.items);

    thread.join();
    joined = true;

    const create_req = ctx.create_req_buf[0..ctx.create_req_len];
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"ReadonlyRootfs\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"NetworkMode\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"CapDrop\":[\"ALL\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"Memory\":268435456") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"PidsLimit\":64") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, create_req, "\"Tmpfs\":{\"/tmp\":\"rw,noexec,nosuid,nodev,size=67108864\"}") != null,
    );

    // Verify audit.log recorded the DENY event with a valid SHA-256 hash chain.
    const audit_path = try std.fs.path.join(alloc, &.{ dir_path, "audit.log" });
    defer alloc.free(audit_path);
    var audit_json = std.ArrayList(u8).init(alloc);
    defer audit_json.deinit();
    try std.testing.expect(try log.writeAuditJson(alloc, audit_path, audit_json.writer()));
    try std.testing.expect(std.mem.indexOf(u8, audit_json.items, "\"deny_events\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit_json.items, "\"rule\":\"policy.max_memory_bytes\"") != null);
}
