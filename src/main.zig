//! zigpod CLI entry point.
const std = @import("std");
const cli = @import("cli.zig");
const completion = @import("completion.zig");
const config = @import("config.zig");
const demo = @import("demo.zig");
const http = @import("http.zig");
const log = @import("log.zig");
const pod = @import("podman_api.zig");
const pods = @import("podman_pods.zig");
const build_mod = @import("podman_build.zig");
const transfer = @import("podman_transfer.zig");
const compose = @import("compose.zig");
const policy = @import("policy.zig");
const registry = @import("podman_registry.zig");

pub const version = "0.1.0";

pub fn main(init: std.process.Init.Minimal) u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    var code = run(gpa, threaded.io(), init);
    threaded.deinit();
    if (debug_allocator.deinit() == .leak) {
        std.Io.File.stderr().writeStreamingAll(threaded_fallback_io(), "zigpod: internal error: memory leak detected\n") catch {};
        if (code == 0) code = 1;
    }
    return code;
}

/// After the main `Io.Threaded` is torn down, the single-threaded global
/// instance is still usable for a final best-effort stderr write.
fn threaded_fallback_io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn run(gpa_allocator: std.mem.Allocator, io: std.Io, init: std.process.Init.Minimal) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Unbuffered: interactive/streaming commands (logs -f, attach, stats)
    // must surface output immediately, exactly like the 0.13 writers did.
    var stdout_fw: std.Io.File.Writer = .initStreaming(std.Io.File.stdout(), io, &.{});
    var stderr_fw: std.Io.File.Writer = .initStreaming(std.Io.File.stderr(), io, &.{});
    const stdout = &stdout_fw.interface;
    const stderr = &stderr_fw.interface;

    var it = init.args.iterateAllocator(arena) catch |e| {
        stderr.print("zigpod: failed to read process arguments: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    _ = it.next(); // skip program name

    var arg_list: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        arg_list.append(arena, arg) catch {
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
        .demo => |d| {
            if (d.json) {
                var report = demo.runSelfTestReport(gpa_allocator, io) catch |e| {
                    stderr.print("zigpod: demo failed: {s}\n", .{@errorName(e)}) catch {};
                    return 1;
                };
                defer report.deinit(gpa_allocator);
                demo.renderJsonReport(gpa_allocator, report, stdout) catch |e| {
                    stderr.print("zigpod: demo failed: {s}\n", .{@errorName(e)}) catch {};
                    return 1;
                };
                if (report.passed != report.total_cases) return 1;
            } else {
                demo.runSelfTest(gpa_allocator, io, stdout) catch |e| {
                    stderr.print("zigpod: demo failed: {s}\n", .{@errorName(e)}) catch {};
                    return 1;
                };
            }
            return 0;
        },
        .completion => |shell| {
            completion.writeCompletion(shell, stdout) catch |e| {
                stderr.print("zigpod: completion failed: {s}\n", .{@errorName(e)}) catch {};
                return 1;
            };
            return 0;
        },
        .policy => |pol_opts| {
            switch (pol_opts.action) {
                .show => policy.showPolicy(io, gpa_allocator, pol_opts.path, pol_opts.json, stdout) catch |e| {
                    stderr.print("zigpod: policy show failed: {s}\n", .{@errorName(e)}) catch {};
                    return 1;
                },
                .check => {
                    const p = pol_opts.path orelse "zigpod-policy.json";
                    policy.checkPolicyFile(io, gpa_allocator, p, pol_opts.json, stdout) catch |e| {
                        stderr.print("zigpod: policy check failed for '{s}': {s}\n", .{ p, @errorName(e) }) catch {};
                        return 1;
                    };
                },
            }
            return 0;
        },
        else => {},
    }

    const cfg = config.Config.load(arena, io, init.environ, parsed.global.socket) catch |e| {
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
                const ok = log.writeAuditJson(io, arena, audit_path, stdout) catch |e| {
                    stderr.print(
                        "zigpod: audit JSON verification failed for '{s}': {s}\n",
                        .{ audit_path, @errorName(e) },
                    ) catch {};
                    return 1;
                };
                return if (ok) 0 else 1;
            }
            const count = log.verifyAuditFile(io, arena, audit_path) catch |e| {
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

    var logger = log.Logger.init(io, cfg.log_dir, parsed.global.verbose or cfg.verbose);
    defer logger.deinit();

    logger.info("zigpod {s} command={s} socket={s}", .{
        version,
        @tagName(parsed.command),
        cfg.socket_path,
    });

    const client = http.Client{
        .allocator = arena,
        .socket_path = cfg.socket_path,
        .io = io,
    };

    switch (parsed.command) {
        .login, .logout => {
            runRegistryAuth(&client, &logger, parsed.command, init.environ, stdout, stderr) catch |e| {
                reportFailure(&logger, parsed.command, cfg.socket_path, e);
                return 1;
            };
            return 0;
        },
        else => {},
    }

    return dispatch(&client, &logger, parsed.command, stdout) catch |e| {
        var trace_addrs: [32]usize = undefined;
        var saved_trace: ?std.builtin.StackTrace = null;
        if (shouldDumpErrorTrace(init.environ, logger.verbose)) {
            if (@errorReturnTrace()) |t| {
                const count = @min(t.index, @min(t.instruction_addresses.len, trace_addrs.len));
                @memcpy(trace_addrs[0..count], t.instruction_addresses[0..count]);
                saved_trace = .{
                    .index = count,
                    .instruction_addresses = trace_addrs[0..count],
                };
            }
        }
        reportFailure(&logger, parsed.command, cfg.socket_path, e);
        if (saved_trace) |*t| std.debug.dumpErrorReturnTrace(t);
        return 1;
    };
}

/// `login` / `logout`: resolve the auth file from the environment and read
/// the password from stdin (`--password-stdin`) or a no-echo TTY prompt.
fn runRegistryAuth(
    client: *const http.Client,
    logger: *log.Logger,
    cmd: cli.Command,
    environ: std.process.Environ,
    stdout: anytype,
    stderr: *std.Io.Writer,
) !void {
    const loc = try registry.resolveAuthFile(client.allocator, environ);
    switch (cmd) {
        .login => |opts| {
            // Validate cheap inputs before prompting for a secret.
            try registry.validateRegistry(opts.registry);
            const stdin = std.Io.File.stdin();
            const password = if (opts.password_stdin)
                try registry.readPassword(client.io, client.allocator, stdin)
            else
                try registry.promptPassword(client.allocator, stdin.handle, stderr);
            defer {
                std.crypto.secureZero(u8, password);
                client.allocator.free(password);
            }
            try registry.login(client, logger, loc, opts.registry, opts.username, password, stdout);
        },
        .logout => |opts| try registry.logout(client.io, client.allocator, logger, loc, opts.registry, stdout),
        else => unreachable,
    }
}

fn dispatch(
    client: *const http.Client,
    logger: *log.Logger,
    cmd: cli.Command,
    stdout: anytype,
) !u8 {
    const io = client.io;
    switch (cmd) {
        .help, .client_version, .demo, .audit, .completion, .policy => return 0,
        .ps => |opts| {
            var filter_buf: [cli.max_ps_filters]pod.ContainerFilter = undefined;
            const src = opts.filters();
            for (src, 0..) |f, idx| filter_buf[idx] = .{ .key = f.key, .value = f.value };
            const list_opts = pod.ListContainersOptions{
                .all = opts.all,
                .quiet = opts.quiet,
                .filters = filter_buf[0..src.len],
            };
            if (opts.json)
                try pod.listContainersJsonWithOptions(client, logger, list_opts, stdout)
            else
                try pod.listContainersWithOptions(client, logger, list_opts, stdout);
        },
        .images => |opts| try pod.listImagesWithOptions(client, logger, .{
            .all = opts.all,
            .quiet = opts.quiet,
            .json = opts.json,
        }, stdout),
        .pull => |image| try pod.pullImage(client, logger, image, stdout),
        .push => |image| try pod.pushImage(client, logger, image, stdout),
        // Needs the process environment and stdin; handled in `run`.
        .login, .logout => unreachable,
        .info => |opts| try pod.systemInfo(client, logger, opts.format, opts.json, stdout),
        .update => |opts| try pod.updateContainer(client, logger, opts.container, .{
            .memory = opts.memory,
            .nano_cpus = opts.nano_cpus,
            .pids_limit = opts.pids_limit,
            .restart = if (opts.restart_policy) |rp| .{
                .Name = rp.name,
                .MaximumRetryCount = rp.max_retry_count,
            } else null,
        }),
        .rmi => |opts| try pod.removeImage(client, logger, opts.image, opts.force, stdout),
        .start => |container| try pod.startContainer(client, logger, container),
        .stop => |opts| try pod.stopContainer(client, logger, opts.container, opts.timeout_secs),
        .restart => |opts| try pod.restartContainer(client, logger, opts.container, opts.timeout_secs),
        .pause => |container| try pod.pauseContainer(client, logger, container),
        .unpause => |container| try pod.unpauseContainer(client, logger, container),
        .rename => |opts| try pod.renameContainer(client, logger, opts.container, opts.new_name),
        .kill => |opts| try pod.killContainer(client, logger, opts.container, opts.signal),
        .rm => |opts| try pod.removeContainerWithVolumes(client, logger, opts.container, opts.force, opts.volumes),
        .logs => |opts| try pod.fetchLogsWithOptions(client, logger, opts.container, .{
            .follow = opts.follow,
            .timestamps = opts.timestamps,
            .tail = opts.tail,
            .since = opts.since,
        }, stdout),
        .top => |container| try pod.topContainer(client, logger, container, stdout),
        .inspect => |opts| if (opts.format) |fmt|
            try pod.inspectFormat(client, logger, opts.target, fmt, stdout)
        else if (opts.json)
            try pod.inspectJson(client, logger, opts.target, stdout)
        else
            try pod.inspect(client, logger, opts.target, stdout),
        .volume => |v| switch (v.action) {
            .ls => try pod.listVolumes(client, logger, stdout),
            .create => try pod.createVolume(client, logger, v.name.?, stdout),
            .rm => try pod.removeVolume(client, logger, v.name.?, v.force),
            .inspect => try pod.inspectVolume(client, logger, v.name.?, stdout),
        },
        .build => |b| {
            var arg_buf: [cli.max_build_args]build_mod.BuildArg = undefined;
            const raw_args = b.buildArgs();
            for (raw_args, 0..) |raw, idx| arg_buf[idx] = try build_mod.parseBuildArg(raw);
            try build_mod.buildImageWithOptions(client, logger, b.tag, b.ctx, .{
                .dockerfile = b.dockerfile,
                .target = b.target,
                .no_cache = b.no_cache,
                .build_args = arg_buf[0..raw_args.len],
            }, stdout);
        },
        .pod => |p| switch (p.action) {
            .create => try pods.createPod(client, logger, p.arg.?, stdout),
            .ps => try pods.listPods(client, logger, stdout),
            .stop => try pods.stopPod(client, logger, p.arg.?, stdout),
            .rm => try pods.rmPod(client, logger, p.arg.?, p.force, stdout),
        },
        .network => |n| switch (n.action) {
            .ls => try pod.listNetworks(client, logger, stdout),
            .inspect => try pod.inspectNetwork(client, logger, n.name.?, stdout),
            .create => try pod.createNetwork(client, logger, n.name.?, n.driver, n.internal, stdout),
            .rm => try pod.removeNetwork(client, logger, n.name.?, n.force),
        },
        .attach => |opts| {
            const stdin_fd: ?std.posix.fd_t = if (opts.interactive or opts.tty) std.Io.File.stdin().handle else null;
            try pod.attachContainer(client, logger, opts.container, opts.interactive, opts.tty, stdin_fd, stdout);
        },
        .cp => |opts| switch (opts.direction) {
            .to_container => try transfer.cpToContainer(client, logger, opts.container, opts.host_path, opts.container_path, stdout),
            .from_container => try transfer.cpFromContainer(client, logger, opts.container, opts.container_path, opts.host_path, stdout),
        },
        .compose => |opts| return try compose.executeCompose(client, logger, opts, stdout),
        .system => |s| switch (s.action) {
            .ping => try pod.systemPing(client, logger, stdout),
            .df => try pod.systemDf(client, logger, stdout),
            .prune => try pod.systemPrune(client, logger, stdout),
        },
        .prune => |kind| try pod.pruneResource(client, logger, switch (kind) {
            .container => .container,
            .image => .image,
            .volume => .volume,
            .network => .network,
        }, stdout),
        .port => |opts| try pod.portContainer(client, logger, opts.container, opts.private_port, stdout),
        .wait => |container| {
            const code = try pod.waitContainer(client, logger, container);
            try stdout.print("{d}\n", .{code});
        },
        .diff => |container| try pod.diffContainer(client, logger, container, stdout),
        .events => |opts| try pod.fetchEvents(client, logger, opts.since, opts.until, opts.json, stdout),
        .tag => |opts| try pod.tagImage(client, logger, opts.src_image, opts.target_image),
        .history => |opts| try pod.imageHistory(client, logger, opts.image, opts.json, stdout),
        .search => |opts| try transfer.searchImages(client, logger, opts.term, stdout),
        .save => |opts| try transfer.saveImage(client, logger, opts.image, opts.output, stdout),
        .load => |opts| try transfer.loadImage(client, logger, opts.input, stdout),
        .@"export" => |opts| try transfer.exportContainer(client, logger, opts.container, opts.output, stdout),
        .import => |opts| try transfer.importImage(client, logger, opts.input, opts.ref, stdout),
        .commit => |opts| try pod.commitContainer(
            client,
            logger,
            opts.container,
            opts.target_image,
            opts.message,
            opts.author,
            stdout,
        ),
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
            const stdin_fd: ?std.posix.fd_t = if (opts.interactive or opts.tty) std.Io.File.stdin().handle else null;
            const code = try pod.execCommandWithIo(client, logger, opts.container, req, stdin_fd, stdout);
            return if (code > 0 and code <= 255) @intCast(code) else if (code == 0) 0 else 1;
        },
        .version => try pod.showVersion(client, logger, version, stdout),
        .run => |r_orig| {
            var r = r_orig;
            var merged_env: ?pod.validate.MergedEnv = null;
            defer if (merged_env) |*me| me.deinit();
            if (r.env_files.len > 0) {
                merged_env = try pod.loadAndMergeEnv(io, client.allocator, r.env_files, r.env);
                r.env = merged_env.?.items;
            }

            var tmpfs_bounds: ?pod.TmpfsBounds = null;
            var loaded_pol: ?std.json.Parsed(policy.Policy) = null;
            defer if (loaded_pol) |lp| lp.deinit();

            if (r.profile == .sandbox or r.policy_path != null) {
                if (r.profile == .sandbox) {
                    policy.applySandboxDefaults(&r);
                }

                const active_pol: policy.Policy = if (r.policy_path) |p_path| blk: {
                    loaded_pol = try policy.loadPolicyFile(io, client.allocator, p_path);
                    break :blk loaded_pol.?.value;
                } else blk: {
                    // Use ./zigpod-policy.json when present; otherwise use built-in fail-closed defaults.
                    if (std.Io.Dir.cwd().access(io, "zigpod-policy.json", .{})) |_| {
                        loaded_pol = try policy.loadImplicitPolicyFile(io, client.allocator, std.Io.Dir.cwd(), "zigpod-policy.json");
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
            var mount_buf: std.ArrayList(pod.Mount) = .empty;
            defer mount_buf.deinit(client.allocator);
            for (r.volumes) |v| {
                try mount_buf.append(client.allocator, try pod.makeMount(io, v.source, v.destination, v.readonly));
            }

            // Validate each published port mapping.
            var port_buf: std.ArrayList(pod.PortMapping) = .empty;
            defer port_buf.deinit(client.allocator);
            for (r.ports) |p| {
                try port_buf.append(client.allocator, try pod.makePortMapping(p.host_ip, p.host_port, p.container_port, p.proto));
            }
            var has_binding = false;
            for (port_buf.items) |p| {
                if (p.host_port != null) {
                    has_binding = true;
                    break;
                }
            }

            var label_buf: std.ArrayList(pod.LabelEntry) = .empty;
            defer label_buf.deinit(client.allocator);
            for (r.labels) |lbl| {
                const entry = pod.LabelEntry{ .key = lbl.key, .value = lbl.value };
                try pod.validateLabel(entry);
                try label_buf.append(client.allocator, entry);
            }

            // Validate identity/network/capability/resource flags before touching the socket.
            try pod.validateResourceRef(r.image);
            if (r.network) |m| try pod.validateNetworkMode(m);
            if (r.workdir) |w| try pod.validateWorkdir(w);
            if (r.user) |u| try pod.validateUser(u);
            if (r.nano_cpus) |nc| try pod.validateNanoCpus(nc);
            if (r.hostname) |h| try pod.validateHostname(h);
            var api_restart_policy: ?pod.RestartPolicy = null;
            if (r.restart_policy) |rp| {
                const mapped = pod.RestartPolicy{
                    .Name = rp.name,
                    .MaximumRetryCount = rp.max_retry_count,
                };
                try pod.validateRestartPolicy(mapped);
                api_restart_policy = mapped;
            }
            for (r.cap_drop) |c| try pod.validateCapability(c);
            for (r.cap_add) |c| try pod.validateCapability(c);
            if (r.shm_size) |shm| try pod.validateShmSize(shm);

            var ulimit_buf: std.ArrayList(pod.Ulimit) = .empty;
            defer ulimit_buf.deinit(client.allocator);
            for (r.ulimits) |u| {
                const mapped = pod.Ulimit{ .Name = u.name, .Soft = u.soft, .Hard = u.hard };
                try pod.validateUlimit(mapped);
                try ulimit_buf.append(client.allocator, mapped);
            }

            var hc_test_buf: [2][]const u8 = undefined;
            var api_healthcheck: ?pod.HealthConfig = null;
            if (r.health_cmd) |hcmd| {
                hc_test_buf = .{ "CMD-SHELL", hcmd };
                const hc = pod.HealthConfig{
                    .Test = &hc_test_buf,
                    .Interval = r.health_interval_ns,
                };
                try pod.validateHealthConfig(hc);
                api_healthcheck = hc;
            }

            var ep_slice: [1][]const u8 = undefined;
            const api_entrypoint: ?[]const []const u8 = if (r.entrypoint) |ep| blk: {
                ep_slice[0] = ep;
                break :blk &ep_slice;
            } else null;

            // Defer removal until after fetchLogs when attached so output is not lost.
            const auto_remove = (r.detach or r.create_only) and r.remove;
            const has_host_cfg = auto_remove or
                r.read_only or
                r.init or
                r.no_new_privileges or
                r.memory != null or
                r.shm_size != null or
                r.nano_cpus != null or
                r.pids_limit != null or
                ulimit_buf.items.len > 0 or
                api_restart_policy != null or
                has_binding or
                r.network != null or
                r.cap_drop.len > 0 or
                r.cap_add.len > 0 or
                r.dns_len > 0 or
                r.host_len > 0 or
                tmpfs_bounds != null;
            const sec_opts: []const []const u8 = &.{"no-new-privileges"};
            const host_cfg: ?pod.HostConfig = if (has_host_cfg) .{
                .AutoRemove = auto_remove,
                .ReadonlyRootfs = r.read_only,
                .Init = if (r.init) true else null,
                .Memory = r.memory,
                .ShmSize = r.shm_size,
                .NanoCpus = r.nano_cpus,
                .PidsLimit = r.pids_limit,
                .RestartPolicy = api_restart_policy,
                .Ulimits = if (ulimit_buf.items.len > 0) ulimit_buf.items else null,
                .SecurityOpt = if (r.no_new_privileges) sec_opts else null,
                .PortBindings = if (has_binding) .{ .ports = port_buf.items } else null,
                .NetworkMode = r.network,
                .CapDrop = if (r.cap_drop.len > 0) r.cap_drop else null,
                .CapAdd = if (r.cap_add.len > 0) r.cap_add else null,
                .Tmpfs = tmpfs_bounds,
                .Dns = if (r.dns_len > 0) r.dns() else null,
                .ExtraHosts = if (r.host_len > 0) r.extraHosts() else null,
            } else null;

            const req = pod.ContainerCreateRequest{
                .Image = r.image,
                .Hostname = r.hostname,
                .Entrypoint = api_entrypoint,
                .Cmd = if (r.cmd.len > 0) r.cmd else null,
                .Env = if (r.env.len > 0) r.env else null,
                .Labels = if (label_buf.items.len > 0) .{ .entries = label_buf.items } else null,
                .ExposedPorts = if (port_buf.items.len > 0) .{ .ports = port_buf.items } else null,
                .WorkingDir = r.workdir,
                .User = r.user,
                .Healthcheck = api_healthcheck,
                .AttachStdin = r.interactive,
                .OpenStdin = r.interactive,
                .AttachStdout = !r.detach and (r.interactive or r.tty),
                .AttachStderr = !r.detach and (r.interactive or r.tty),
                .Tty = r.tty,
                .Mounts = if (mount_buf.items.len > 0) mount_buf.items else null,
                .StopTimeout = if (r.stop_timeout) |t| @as(i64, t) else null,
                .HostConfig = host_cfg,
            };

            // `--pull`: progress goes to stderr so `run -d` / `create` still print only the ID.
            if (r.pull) |pp| {
                const need_pull = switch (pp) {
                    .always => true,
                    .missing => !(try pod.imageExists(client, logger, r.image)),
                    .never => false,
                };
                if (pp == .never and !(try pod.imageExists(client, logger, r.image))) {
                    logger.err("image {s} not present locally and --pull=never", .{r.image});
                    return pod.ApiError.NotFound;
                }
                if (need_pull) {
                    var err_buf: [256]u8 = undefined;
                    var stderr_w: std.Io.File.Writer = .init(std.Io.File.stderr(), io, &err_buf);
                    try pod.pullImage(client, logger, r.image, &stderr_w.interface);
                    stderr_w.interface.flush() catch {};
                }
            }

            const id = try pod.createContainerOnPlatform(client, logger, req, r.name, r.platform);
            defer client.allocator.free(id);
            if (r.create_only) {
                try stdout.print("{s}\n", .{id});
                return 0;
            }
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
                pod.attachContainer(client, logger, id, r.interactive, r.tty, std.Io.File.stdin().handle, stdout) catch |e| {
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
        pod.ApiError.InvalidCpuLimit => logger.deny(
            "api.validateNanoCpus",
            "Rejected invalid --cpus limit (must be > 0 and <= 1024 CPUs).",
        ),
        pod.ApiError.InvalidShmSize => logger.deny(
            "api.validateShmSize",
            "Rejected invalid --shm-size (must be > 0 and <= 64 GiB).",
        ),
        pod.ApiError.InvalidHostname => logger.deny(
            "api.validateHostname",
            "Rejected invalid --hostname (use 1..64 RFC-1123 characters [a-zA-Z0-9.-]).",
        ),
        pod.ApiError.InvalidRestartPolicy => logger.deny(
            "api.validateRestartPolicy",
            "Rejected invalid --restart policy. Allowed: no, always, unless-stopped, on-failure[:N].",
        ),
        pod.ApiError.InvalidLabel => logger.deny(
            "api.validateLabel",
            "Rejected invalid container label (KEY=VALUE with non-empty control-free key).",
        ),
        pod.ApiError.InvalidNetworkDriver => logger.deny(
            "api.validateNetworkDriver",
            "Rejected invalid network driver. Allowed: bridge, macvlan, ipvlan.",
        ),
        pod.ApiError.InvalidEnvFile => logger.deny(
            "api.loadAndMergeEnv",
            "Rejected malformed or oversized --env-file (must contain KEY=VALUE lines <= 1 MiB).",
        ),
        pod.ApiError.InvalidUlimit => logger.deny(
            "api.validateUlimit",
            "Rejected invalid --ulimit specification (must be allowed name with 0 <= soft <= hard).",
        ),
        pod.ApiError.InvalidHealthcheck => logger.deny(
            "api.validateHealthConfig",
            "Rejected invalid --health-cmd / --health-interval configuration.",
        ),
        pod.ApiError.InvalidTimeout => logger.deny(
            "api.restartContainer",
            "Rejected invalid container stop/restart timeout (must be <= 3600 seconds).",
        ),
        pod.ApiError.InvalidDns => logger.deny(
            "api.validateDnsServer",
            "Rejected --dns value (must be an IPv4/IPv6 literal).",
        ),
        pod.ApiError.InvalidExtraHost => logger.deny(
            "api.validateExtraHost",
            "Rejected --add-host entry (must be HOSTNAME:IP).",
        ),
        pod.ApiError.InvalidPlatform => logger.deny(
            "api.validatePlatform",
            "Rejected --platform value (must be os/arch[/variant]).",
        ),
        pod.ApiError.InvalidUpdate => logger.deny(
            "api.validateUpdate",
            "Rejected update: give at least one of --memory (6 MiB..1 TiB), --cpus, --pids-limit (1..4194304), --restart.",
        ),
        pod.ApiError.InvalidRegistry => logger.deny(
            "registry.validateRegistry",
            "Rejected registry (use HOST[:PORT] without scheme or path, e.g. quay.io or localhost:5000).",
        ),
        pod.ApiError.InvalidCredentials => logger.deny(
            "registry.validateCredentials",
            "Rejected credentials: username must be non-empty without ':' or whitespace; password must be 1..4096 bytes without control characters. Use --password-stdin when stdin is not a terminal.",
        ),
        pod.ApiError.InvalidAuthFile => logger.deny(
            "registry.resolveAuthFile",
            "Refused registry auth file: it must be a regular file you own in a directory you own that is not group/world-writable, contain a JSON object, and be located via an absolute REGISTRY_AUTH_FILE or XDG_RUNTIME_DIR.",
        ),
        pod.ApiError.NotLoggedIn => {
            // Already logged with the registry name by registry.logout.
        },
        pod.ApiError.InvalidFilter => logger.deny(
            "api.validateContainerFilter",
            "Rejected invalid ps --filter (unknown key or unsafe value).",
        ),
        pod.ApiError.InvalidBuildArg => logger.deny(
            "build.validateBuildArg",
            "Rejected invalid --build-arg (KEY must match [A-Za-z_][A-Za-z0-9_]*, VALUE has no control characters).",
        ),
        pod.ApiError.InvalidDockerfilePath => logger.deny(
            "build.validateDockerfilePath",
            "Rejected -f Dockerfile path (must be a relative regular file inside the build context, no '..').",
        ),
        pod.ApiError.InvalidBuildTarget => logger.deny(
            "build.validateBuildTarget",
            "Rejected invalid --target stage name.",
        ),
        pod.ApiError.InvalidFormat => logger.deny(
            "api.validateFormat",
            "Rejected unsupported inspect --format template (only {{.A.B}} and {{json .A.B}}).",
        ),
        compose.ComposeError.UnknownService => logger.deny(
            "compose.selectServices",
            "Rejected compose command: service name not defined in compose.yaml.",
        ),
        compose.ComposeError.CyclicDependency,
        compose.ComposeError.UnknownDependency,
        => logger.deny(
            "compose.topoSortServices",
            "Rejected compose.yaml dependency graph (cycle or unknown service in depends_on).",
        ),
        compose.ComposeError.ComposeFileNotFound,
        compose.ComposeError.InvalidComposePath,
        compose.ComposeError.InvalidComposeSyntax,
        compose.ComposeError.MissingServiceImage,
        compose.ComposeError.DuplicateService,
        compose.ComposeError.TooManyServices,
        => logger.deny(
            "compose.loadComposeFile",
            "Rejected missing or malformed compose.yaml file.",
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
            // Already logged with the target name by inspect/buildImage.
        },
        pod.ApiError.MissingDockerfile => logger.err(
            "No Dockerfile or Containerfile found in build context directory.",
            .{},
        ),
        pod.ApiError.BuildContextTooLarge => logger.err(
            "Build context or input tarball exceeds the size limit.",
            .{},
        ),
        pod.ApiError.BuildFailed => {
            // Already logged with build stream error details by podman_build.
        },
        else => logger.err("command '{s}' failed: {s}", .{ @tagName(cmd), @errorName(err) }),
    }
}

fn shouldDumpErrorTrace(environ: std.process.Environ, verbose: bool) bool {
    if (verbose) return true;
    if (environ.getPosix("ZIGPOD_TRACE")) |val| {
        return val.len > 0 and !std.mem.eql(u8, val, "0");
    }
    return false;
}

test {
    _ = cli;
    _ = completion;
    _ = config;
    _ = demo;
    _ = http;
    _ = log;
    _ = pod;
    _ = pods;
    _ = build_mod;
    _ = transfer;
    _ = compose;
    _ = policy;
    _ = registry;
    _ = @import("utils.zig");
    std.testing.refAllDecls(@This());
}

const DispatchCleanupMockCtx = struct {
    server: *std.Io.net.Server,
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
        const conn = ctx.server.accept(std.testing.io) catch return;
        defer conn.close(std.testing.io);
        var req_buf: [1024]u8 = undefined;
        const n = http.socket.streamRead(std.testing.io, conn, &req_buf) catch 0;
        if (std.mem.indexOf(u8, req_buf[0..n], step.match) != null) {
            if (step.mark_force) ctx.saw_force_delete = true;
            if (step.mark_rm) ctx.saw_rm_delete = true;
        }
        http.socket.streamWriteAll(conn, step.reply) catch return;
    }
}

test "ps --filter allow-lists stay in sync between CLI and API" {
    try std.testing.expectEqual(cli.ps_filter_keys.len, pod.container_filter_keys.len);
    for (cli.ps_filter_keys, pod.container_filter_keys) |a, b| {
        try std.testing.expectEqualStrings(a, b);
    }
}

test "dispatch cleans up orphan container when startContainer or fetchLogs fails (BUG-012)" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-dispatch-bug012-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    var ctx = DispatchCleanupMockCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runDispatchCleanupMockServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // 1) startContainer fails -> dispatch must force-remove orphan1234
    try std.testing.expectError(
        pod.ApiError.PodmanApiError,
        dispatch(&client, &logger, .{ .run = .{ .image = "alpine:3.20", .detach = true } }, &out.writer),
    );
    try std.testing.expect(ctx.saw_force_delete);

    // 2) run --rm where fetchLogs fails after waitContainer -> dispatch must remove rm1234
    try std.testing.expectError(
        pod.ApiError.PodmanApiError,
        dispatch(&client, &logger, .{ .run = .{ .image = "alpine:3.20", .remove = true } }, &out.writer),
    );
    try std.testing.expect(ctx.saw_rm_delete);

    thread.join();
    joined = true;
}

const SandboxMockCtx = struct {
    server: *std.Io.net.Server,
    create_req_len: usize = 0,
    create_req_buf: [2048]u8 = undefined,
};

fn runSandboxDispatchMockServer(ctx: *SandboxMockCtx) void {
    // 1) POST /v1.40/containers/create
    if (ctx.server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        ctx.create_req_len = http.socket.streamRead(std.testing.io, conn, &ctx.create_req_buf) catch 0;
        http.socket.streamWriteAll(
            conn,
            "HTTP/1.1 201 Created\r\nContent-Length: 19\r\n\r\n{\"Id\":\"sandbox999\"}",
        ) catch return;
    } else |_| return;

    // 2) POST /v1.40/containers/sandbox999/start
    if (ctx.server.accept(std.testing.io)) |conn| {
        defer conn.close(std.testing.io);
        var buf: [512]u8 = undefined;
        _ = http.socket.streamRead(std.testing.io, conn, &buf) catch {};
        http.socket.streamWriteAll(conn, "HTTP/1.1 204 No Content\r\n\r\n") catch return;
    } else |_| return;
}

test "dispatch run --profile=sandbox serializes HostConfig.Tmpfs and logs DENY on policy violation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-dispatch-sandbox-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    var ctx = SandboxMockCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runSandboxDispatchMockServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{
        .allocator = alloc,
        .socket_path = sock_path,
        .io = std.testing.io,
    };
    var logger = log.Logger.init(std.testing.io, dir_path, false);
    defer logger.deinit();
    logger.echo_stderr = false;

    var out: std.Io.Writer.Allocating = .init(alloc);
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
        }, &out.writer),
    );

    // 2) Happy-path sandbox run (-d): applies defaults + Tmpfs bounds and starts container.
    const exit_code = try dispatch(&client, &logger, .{
        .run = .{
            .image = "alpine:3.20",
            .profile = .sandbox,
            .detach = true,
        },
    }, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("sandbox999\n", out.written());

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
    var audit_json: std.Io.Writer.Allocating = .init(alloc);
    defer audit_json.deinit();
    try std.testing.expect(try log.writeAuditJson(std.testing.io, alloc, audit_path, &audit_json.writer));
    try std.testing.expect(std.mem.indexOf(u8, audit_json.written(), "\"deny_events\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit_json.written(), "\"rule\":\"policy.max_memory_bytes\"") != null);
}

const ExtendedDispatchMockCtx = struct {
    server: *std.Io.net.Server,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    create_body: [4096]u8 = undefined,
    create_body_len: usize = 0,
    matched: usize = 0,
};

fn runExtendedDispatchMockServer(ctx: *ExtendedDispatchMockCtx) void {
    // Step 1: run --cpus --env-file -l --entrypoint --hostname --restart -> POST create (201) + POST start (204)
    // Step 2: network create -> POST /networks/create (201)
    // Step 3: network rm -> DELETE /networks/iso?force=true (204)
    // Step 4: attach -> POST /containers/web/attach?stream=1&stdout=1&stderr=1 (101 + "attached\n")
    // Step 5: cp to container -> PUT /containers/web/archive?path=%2Ftmp (200)
    const steps = [_]struct {
        match: []const u8,
        reply: []const u8,
        capture_body: bool = false,
    }{
        .{
            .match = "POST /v1.40/containers/create",
            .reply = "HTTP/1.1 201 Created\r\nContent-Length: 17\r\n\r\n{\"Id\":\"runnew12\"}",
            .capture_body = true,
        },
        .{
            .match = "POST /v1.40/containers/runnew12/start",
            .reply = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .match = "POST /v1.40/networks/create",
            .reply = "HTTP/1.1 201 Created\r\nContent-Length: 28\r\n\r\n{\"Id\":\"netabc\",\"Warning\":\"\"}",
        },
        .{
            .match = "DELETE /v1.40/networks/iso?force=true",
            .reply = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .match = "POST /v1.40/containers/web/attach",
            .reply = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\nattached\n",
        },
        .{
            .match = "PUT /v1.40/containers/web/archive?path=%2Ftmp",
            .reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        },
    };

    for (steps) |step| {
        var polls: usize = 0;
        while (!ctx.stop.load(.acquire) and polls < 100) : (polls += 1) {
            var pfd = [1]std.posix.pollfd{.{
                .fd = ctx.server.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfd, 50) catch return;
            if (ready > 0 and (pfd[0].revents & std.posix.POLL.IN) != 0) break;
        }
        if (ctx.stop.load(.acquire) or polls >= 100) return;

        const conn = ctx.server.accept(std.testing.io) catch return;
        defer conn.close(std.testing.io);
        var req_buf: [4096]u8 = undefined;
        var total: usize = 0;
        // Read headers + initial payload; short poll drains split writes (headers then body).
        while (total < req_buf.len) {
            const n = http.socket.streamRead(std.testing.io, conn, req_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) {
                var dpfd = [1]std.posix.pollfd{.{
                    .fd = conn.socket.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const more = std.posix.poll(&dpfd, 15) catch 0;
                if (more == 0) break;
            }
        }
        const req_data = req_buf[0..total];
        if (std.mem.startsWith(u8, req_data, step.match)) {
            ctx.matched += 1;
            if (step.capture_body) {
                const copy_len = @min(req_data.len, ctx.create_body.len);
                @memcpy(ctx.create_body[0..copy_len], req_data[0..copy_len]);
                ctx.create_body_len = copy_len;
            }
            http.socket.streamWriteAll(conn, step.reply) catch return;
        } else {
            http.socket.streamWriteAll(conn, "HTTP/1.1 500 Unexpected\r\nContent-Length: 0\r\n\r\n") catch return;
        }
    }
}

test "dispatch handles extended run flags (--cpus, --env-file, --label, --entrypoint, --hostname, --restart), network CRUD, attach, and cp" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.env", .data = "# env\nMODE=sandbox\n" });
    const env_path = try std.fs.path.join(alloc, &.{ dir_path, "app.env" });
    defer alloc.free(env_path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret.env", .data = "API_KEY=sk-1234567890abcdef123456\n" });
    const secret_env_path = try std.fs.path.join(alloc, &.{ dir_path, "secret.env" });
    defer alloc.free(secret_env_path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "hello" });
    const note_path = try std.fs.path.join(alloc, &.{ dir_path, "note.txt" });
    defer alloc.free(note_path);

    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-disp-ext-{d}.sock", .{std.Io.Clock.awake.now(std.testing.io).nanoseconds});
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    var ctx = ExtendedDispatchMockCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, runExtendedDispatchMockServer, .{&ctx});
    var joined = false;
    defer {
        ctx.stop.store(true, .release);
        if (!joined) thread.join();
    }

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger.init(std.testing.io, dir_path, false);
    defer logger.deinit();
    logger.echo_stderr = false;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Pre-flight secret check must block secrets coming from --env-file in sandbox mode.
    try std.testing.expectError(
        pod.ApiError.PolicyViolation,
        dispatch(&client, &logger, .{
            .run = .{
                .image = "alpine:3.20",
                .profile = .sandbox,
                .env_files = &.{secret_env_path},
                .detach = true,
            },
        }, &out.writer),
    );

    // Run with all new flags serialized cleanly.
    const labels = [_]cli.Label{.{ .key = "svc", .value = "worker" }};
    const rc = try dispatch(&client, &logger, .{
        .run = .{
            .image = "alpine:3.20",
            .detach = true,
            .nano_cpus = 500_000_000,
            .env_files = &.{env_path},
            .env = &.{"EXTRA=1"},
            .labels = &labels,
            .entrypoint = "/bin/sh",
            .hostname = "worker-1.local",
            .restart_policy = .{ .name = "on-failure", .max_retry_count = 2 },
        },
    }, &out.writer);
    try std.testing.expectEqual(@as(u8, 0), rc);
    try std.testing.expectEqualStrings("runnew12\n", out.written());

    out.clearRetainingCapacity();
    _ = try dispatch(&client, &logger, .{
        .network = .{ .action = .create, .name = "iso", .driver = "bridge", .internal = true },
    }, &out.writer);
    try std.testing.expectEqualStrings("netabc\n", out.written());

    _ = try dispatch(&client, &logger, .{
        .network = .{ .action = .rm, .name = "iso", .force = true },
    }, &out.writer);

    out.clearRetainingCapacity();
    _ = try dispatch(&client, &logger, .{
        .attach = .{ .container = "web", .tty = true },
    }, &out.writer);
    try std.testing.expectEqualStrings("attached\n", out.written());

    out.clearRetainingCapacity();
    _ = try dispatch(&client, &logger, .{
        .cp = .{
            .direction = .to_container,
            .container = "web",
            .container_path = "/tmp",
            .host_path = note_path,
        },
    }, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "web:/tmp") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 6), ctx.matched);

    const req_slice = ctx.create_body[0..ctx.create_body_len];
    try std.testing.expect(std.mem.indexOf(u8, req_slice, "\"NanoCpus\":500000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_slice, "\"Hostname\":\"worker-1.local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_slice, "\"Entrypoint\":[\"/bin/sh\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_slice, "\"Labels\":{\"svc\":\"worker\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_slice, "\"Env\":[\"MODE=sandbox\",\"EXTRA=1\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_slice, "\"RestartPolicy\":{\"Name\":\"on-failure\",\"MaximumRetryCount\":2}") != null);
}

test "shouldDumpErrorTrace honors verbose flag and explicit trace requests" {
    try std.testing.expect(shouldDumpErrorTrace(std.testing.environ, true));
    if (std.testing.environ.getPosix("ZIGPOD_TRACE") == null) {
        try std.testing.expect(!shouldDumpErrorTrace(std.testing.environ, false));
    }
}
