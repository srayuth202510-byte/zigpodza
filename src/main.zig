//! zigpod CLI entry point.
const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const demo = @import("demo.zig");
const http = @import("http.zig");
const log = @import("log.zig");
const pod = @import("podman_api.zig");

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
        else => {},
    }

    const cfg = config.Config.load(arena, parsed.global.socket) catch |e| {
        stderr.print("zigpod: failed to load config: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };

    switch (parsed.command) {
        .audit => |opt_path| {
            const audit_path = if (opt_path) |p|
                p
            else
                std.fs.path.join(arena, &.{ cfg.log_dir, "audit.log" }) catch {
                    stderr.writeAll("zigpod: out of memory\n") catch {};
                    return 1;
                };
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
        .help, .client_version, .demo, .audit => return 0,
        .ps => |opts| try pod.listContainers(client, logger, opts.all, stdout),
        .images => try pod.listImages(client, logger, stdout),
        .pull => |image| try pod.pullImage(client, logger, image, stdout),
        .stop => |container| try pod.stopContainer(client, logger, container),
        .rm => |opts| try pod.removeContainer(client, logger, opts.container, opts.force),
        .logs => |container| try pod.fetchLogs(client, logger, container, stdout),
        .version => try pod.showVersion(client, logger, version, stdout),
        .run => |r| {
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
                r.cap_add.len > 0;
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
            } else null;

            const req = pod.ContainerCreateRequest{
                .Image = r.image,
                .Cmd = if (r.cmd.len > 0) r.cmd else null,
                .Env = if (r.env.len > 0) r.env else null,
                .ExposedPorts = if (port_buf.items.len > 0) .{ .ports = port_buf.items } else null,
                .WorkingDir = r.workdir,
                .User = r.user,
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

            const status = try pod.waitContainer(client, logger, id);
            if (r.remove) {
                // BUG-012: honor --rm even when fetching logs fails; the
                // container has already exited by the time wait returns.
                pod.fetchLogs(client, logger, id, stdout) catch |e| {
                    pod.removeContainer(client, logger, id, false) catch {};
                    return e;
                };
                try pod.removeContainer(client, logger, id, false);
            } else {
                try pod.fetchLogs(client, logger, id, stdout);
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
        http.Error.InvalidRequestPath => logger.err(
            "Rejected invalid HTTP request path.",
            .{},
        ),
        pod.ApiError.InvalidIdentifier => logger.err(
            "Invalid container identifier or name (allowed: alphanumeric, '-', '_', '.', ':').",
            .{},
        ),
        pod.ApiError.InvalidHostPath => logger.err(
            "Rejected unsafe host path or volume name. Bind mounts must be absolute, traversal-free, and may not target /, /etc, /proc, /sys, /dev, /boot, /run, /root, or container-engine state; sensitive /etc files are read-only.",
            .{},
        ),
        pod.ApiError.InvalidMountTarget => logger.err(
            "Rejected invalid container mount target (must be an absolute, traversal-free path).",
            .{},
        ),
        pod.ApiError.InvalidPort => logger.err(
            "Rejected invalid port mapping. Use [IP:]HOST:CONTAINER[/tcp|udp|sctp] with ports 1-65535 and an IPv4 host address.",
            .{},
        ),
        pod.ApiError.InvalidNetwork => logger.err(
            "Rejected invalid --network mode. Use none, bridge, host, pasta, or slirp4netns.",
            .{},
        ),
        pod.ApiError.InvalidWorkdir => logger.err(
            "Rejected invalid --workdir (must be an absolute, traversal-free container path).",
            .{},
        ),
        pod.ApiError.InvalidUser => logger.err(
            "Rejected invalid --user. Use USER or USER:GROUP (alphanumerics plus '_', '-', '.').",
            .{},
        ),
        pod.ApiError.InvalidCapability => logger.err(
            "Rejected invalid capability name. Use ALL or an uppercase name such as NET_ADMIN.",
            .{},
        ),
        pod.ApiError.PodmanApiError => {
            // Already logged with HTTP status and response details by podman_api.
        },
        else => logger.err("command '{s}' failed: {s}", .{ @tagName(cmd), @errorName(err) }),
    }
}

test {
    _ = cli;
    _ = config;
    _ = demo;
    _ = http;
    _ = log;
    _ = pod;
    _ = @import("utils.zig");
    std.testing.refAllDecls(@This());
}
