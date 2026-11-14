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
                stderr.print("zigpod: audit verification failed for '{s}': {s}\n", .{ audit_path, @errorName(e) }) catch {};
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
            // Defer removal until after fetchLogs when attached so output is not lost.
            const auto_remove = r.detach and r.remove;
            const has_host_cfg = auto_remove or
                r.read_only or
                r.no_new_privileges or
                r.memory != null or
                r.pids_limit != null;
            const sec_opts: []const []const u8 = &.{"no-new-privileges"};
            const host_cfg: ?pod.HostConfig = if (has_host_cfg) .{
                .AutoRemove = auto_remove,
                .ReadonlyRootfs = r.read_only,
                .Memory = r.memory,
                .PidsLimit = r.pids_limit,
                .SecurityOpt = if (r.no_new_privileges) sec_opts else null,
            } else null;
            const req = pod.ContainerCreateRequest{
                .Image = r.image,
                .Cmd = if (r.cmd.len > 0) r.cmd else null,
                .Env = if (r.env.len > 0) r.env else null,
                .HostConfig = host_cfg,
            };
            const id = try pod.createContainer(client, logger, req, r.name);
            try pod.startContainer(client, logger, id);

            if (r.detach) {
                try stdout.print("{s}\n", .{id});
                return 0;
            }

            const status = try pod.waitContainer(client, logger, id);
            try pod.fetchLogs(client, logger, id, stdout);
            if (r.remove) {
                try pod.removeContainer(client, logger, id, false);
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
