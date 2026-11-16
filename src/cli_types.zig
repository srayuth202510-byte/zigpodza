//! Docker-style command-line parsing.
const std = @import("std");

pub const usage =
    \\Usage: zigpod [GLOBAL OPTIONS] COMMAND [ARGS...]
    \\
    \\A small Docker/Podman-compatible CLI written in Zig. It talks to the
    \\Podman (Docker-compatible) REST API over a Unix socket.
    \\
    \\Commands:
    \\  run [OPTIONS] IMAGE [CMD...]   Create and start a container
    \\      -d, --detach               Run in background and print the container ID
    \\      -i, --interactive          Keep STDIN open
    \\      -t, --tty                  Allocate a pseudo-TTY
    \\      --rm                       Remove the container when it exits
    \\      --name NAME                Assign a name to the container
    \\      -e, --env KEY=VALUE        Set an environment variable (repeatable)
    \\      -v, --volume SRC:DST[:ro|rw]  Bind mount a host path (default: read-only)
    \\      -p, --publish [IP:]HOST:CONTAINER[/proto]  Publish a container port (repeatable)
    \\      --network MODE             Network mode: none|bridge|host|pasta|slirp4netns
    \\      -w, --workdir PATH         Working directory inside the container
    \\      -u, --user USER[:GROUP]    Run as user (and optional group)
    \\      --cap-drop CAP             Drop a Linux capability (repeatable, e.g. ALL)
    \\      --cap-add CAP              Add a Linux capability (repeatable)
    \\      -m, --memory BYTES         Memory limit (e.g., 64m, 1g, 1048576)
    \\      --pids-limit N             Limit container PIDs
    \\      --read-only                Mount container root filesystem as read-only
    \\      --no-new-privileges        Prevent privilege escalation inside container
    \\      --profile PROFILE          Security profile: default|sandbox (fail-closed AI sandbox)
    \\      --policy FILE              Pre-flight policy guardrails JSON (e.g. zigpod-policy.json)
    \\      --cpus N                   Limit CPU cores (e.g., 0.5, 2)
    \\      --env-file FILE            Read environment variables from file (repeatable)
    \\      -l, --label KEY=VALUE      Set metadata label on container (repeatable)
    \\      --entrypoint CMD           Overwrite default image entrypoint
    \\      --hostname NAME            Container host name
    \\      --restart POLICY           Restart policy: no|always|unless-stopped|on-failure[:N]
    \\      --shm-size SIZE            Size of /dev/shm (e.g., 64m, 256m)
    \\      --ulimit NAME=SOFT[:HARD]  Set resource limit (repeatable, e.g. nofile=1024:2048)
    \\      --init                     Run an init process inside the container
    \\      --health-cmd CMD           Command to run to check container health
    \\      --health-interval DUR      Time between running the health check (e.g., 30s, 500ms)
    \\  compose up|down|ps [-f FILE] [-d] [--json]  Manage multi-container stacks from compose.yaml
    \\  ps [-a] [-q] [--filter KEY=VALUE] [--json]  List containers (-a: include stopped, -q: IDs only)
    \\  images [-a] [-q] [--json]      List local images (-a: include intermediate, -q: IDs only)
    \\  pull IMAGE                     Pull an image from a registry
    \\  rmi [-f] IMAGE                 Remove a local image (-f: force)
    \\  start CONTAINER                Start a created or stopped container
    \\  stop [-t SECS] CONTAINER       Stop a running container (-t: stop timeout seconds)
    \\  restart [-t SECS] CONTAINER    Restart a container (-t: stop timeout seconds)
    \\  pause CONTAINER                Pause all processes inside a container
    \\  unpause CONTAINER              Unpause a paused container
    \\  rename CONTAINER NEW_NAME      Rename an existing container
    \\  kill [-s SIGNAL] CONTAINER     Send a signal to a running container (default: SIGTERM)
    \\  rm [-f] CONTAINER              Remove a container (-f: force)
    \\  logs [-f] [-t] [--tail N|all] [--since UNIX_TS] CONTAINER  Print a container's logs
    \\                                 (-f: follow, -t: timestamps)
    \\  top CONTAINER                  Display the running processes of a container
    \\  exec [OPTIONS] CONTAINER CMD...  Run a command in a running container
    \\      -i, --interactive          Keep STDIN open
    \\      -t, --tty                  Allocate a pseudo-TTY
    \\      -e, --env KEY=VALUE        Set an environment variable (repeatable)
    \\      -u, --user USER[:GROUP]    Run as user (and optional group)
    \\      -w, --workdir PATH         Working directory inside the container
    \\  inspect [--json|--format TEMPLATE] TARGET  Show container or image details
    \\                                 (--format: {{.Field.Path}} or {{json .Field}})
    \\  stats [--no-stream] [-a] [--json] [CONTAINER...]  Display CPU, memory, and PIDs metrics
    \\  volume ls|create|rm|inspect [NAME]       Manage named volumes
    \\  network ls|inspect|create|rm ...         Manage container networks
    \\  attach [-i] [-t] CONTAINER               Attach to a running container
    \\  cp SRC DST                               Copy files between container (CTR:PATH) and host path
    \\  create [OPTIONS] IMAGE [CMD...]  Create a container without starting it (same options as run)
    \\  container|image|volume|network prune [-f]  Remove unused containers/images/volumes/networks
    \\  system ping|df|prune [-f]      Check daemon health, disk usage, or prune unused resources
    \\  port CONTAINER [PORT[/PROTO]]  List port mappings for a container
    \\  wait CONTAINER                 Block until a container stops and print its exit code
    \\  diff CONTAINER                 Inspect changes on a container's filesystem
    \\  events [--since TS] [--until TS] [--json]  Stream or query daemon events
    \\  tag SRC_IMAGE TARGET_IMAGE     Create a tag for a local image
    \\  history [--json] IMAGE         Show the history of an image
    \\  commit [-m MSG] [-a AUTHOR] CONTAINER REPO[:TAG]  Create a new image from a container
    \\  search TERM                    Search a registry for images
    \\  save -o FILE IMAGE             Stream an image tarball to a host file
    \\  load -i FILE                   Upload a local image tarball to the daemon
    \\  export -o FILE CONTAINER       Stream a container rootfs tarball to a host file
    \\  import FILE REPO[:TAG]         Upload a local rootfs tarball as a new image
    \\  policy show|check [--json] [FILE]  Inspect or validate a zigpod-policy.json file
    \\  build -t TAG [-f FILE] [--build-arg K=V] [--target STAGE] [--no-cache] DIR
    \\                                 Build an image (-f is relative to DIR)
    \\  pod create NAME|pod ps|pod stop ID|pod rm [-f] ID  Manage pods
    \\  completion bash|zsh|fish       Generate shell tab-completion script
    \\  audit [--json] [FILE]          Verify SHA-256 hash chain of audit.log (--json: structured output)
    \\  demo [--json]                  Run 18-case fail-closed ALLOW/DENY self-test suite (--json: security report)
    \\  version                        Show client and server versions
    \\  help                           Show this help
    \\
    \\Global options:
    \\  -v, --verbose                  Echo INFO/DEBUG log messages to stderr
    \\  --socket PATH                  Podman API socket (default: auto-detect)
    \\  -h, --help                     Show this help
    \\  --version                      Show client version
    \\
    \\Environment:
    \\  ZIGPOD_SOCKET, CONTAINER_HOST, DOCKER_HOST   API socket (unix://...)
    \\  ZIGPOD_LOG_DIR                               Where system.log / error.log go
    \\
;

pub const Global = struct {
    verbose: bool = false,
    socket: ?[]const u8 = null,
};

pub const Volume = struct {
    source: []const u8,
    destination: []const u8,
    /// Read-only unless the user explicitly opts out with `:rw` (BUG-014).
    readonly: bool = true,
};

/// Parsed `-p`/`--publish` mapping. `host_ip` (IPv4) and `host_port` are null
/// when the user only exposes a container port.
pub const PortMapping = struct {
    host_ip: ?[]const u8 = null,
    host_port: ?u16 = null,
    container_port: u16,
    proto: []const u8 = "tcp",
};

pub const Profile = enum {
    default,
    sandbox,
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

pub const RestartPolicySpec = struct {
    name: []const u8,
    max_retry_count: u32 = 0,
};

pub const UlimitSpec = struct {
    name: []const u8,
    soft: i64,
    hard: i64,
};

pub const RunOpts = struct {
    /// `create`: build the container but do not start it.
    create_only: bool = false,
    image: []const u8,
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    env_files: []const []const u8 = &.{},
    volumes: []const Volume = &.{},
    ports: []const PortMapping = &.{},
    labels: []const Label = &.{},
    ulimits: []const UlimitSpec = &.{},
    cap_drop: []const []const u8 = &.{},
    cap_add: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    network: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    user: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    restart_policy: ?RestartPolicySpec = null,
    profile: Profile = .default,
    policy_path: ?[]const u8 = null,
    detach: bool = false,
    interactive: bool = false,
    tty: bool = false,
    remove: bool = false,
    read_only: bool = false,
    no_new_privileges: bool = false,
    init: bool = false,
    memory: ?i64 = null,
    shm_size: ?i64 = null,
    pids_limit: ?i64 = null,
    nano_cpus: ?i64 = null,
    health_cmd: ?[]const u8 = null,
    health_interval_ns: ?i64 = null,
};

pub const RmOpts = struct {
    container: []const u8,
    force: bool = false,
};

pub const LogsOpts = struct {
    container: []const u8,
    follow: bool = false,
    timestamps: bool = false,
    /// null = all lines.
    tail: ?u32 = null,
    /// Unix timestamp (seconds); only logs at or after it are returned.
    since: ?u64 = null,
};

pub const ExecOpts = struct {
    container: []const u8,
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    user: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    interactive: bool = false,
    tty: bool = false,
};

pub const StatsOpts = struct {
    no_stream: bool = false,
    all: bool = false,
    json: bool = false,
    containers: []const []const u8 = &.{},
};

pub const Filter = struct {
    key: []const u8,
    value: []const u8,
};

pub const max_ps_filters = 8;

pub const PsOpts = struct {
    all: bool = false,
    json: bool = false,
    /// `-q`: print only container IDs.
    quiet: bool = false,
    filter_buf: [max_ps_filters]Filter = undefined,
    filter_len: usize = 0,

    pub fn filters(self: *const PsOpts) []const Filter {
        return self.filter_buf[0..self.filter_len];
    }
};

pub const ImagesOpts = struct {
    json: bool = false,
    /// `-q`: print only image IDs.
    quiet: bool = false,
    /// `-a`: include intermediate images.
    all: bool = false,
};

pub const InspectOpts = struct {
    target: []const u8,
    json: bool = false,
    /// `--format '{{.Path.To.Field}}'` template (subset of Go templates).
    format: ?[]const u8 = null,
};

pub const AuditOpts = struct {
    path: ?[]const u8 = null,
    json: bool = false,
};

pub const DemoOpts = struct {
    json: bool = false,
};

pub const max_build_args = 32;

pub const BuildOpts = struct {
    tag: []const u8,
    ctx: []const u8,
    /// `-f`: Dockerfile path relative to the build context.
    dockerfile: ?[]const u8 = null,
    /// `--target`: multi-stage build stage name.
    target: ?[]const u8 = null,
    no_cache: bool = false,
    /// Raw `KEY=VALUE` strings from `--build-arg` (validated again in the API layer).
    build_arg_buf: [max_build_args][]const u8 = undefined,
    build_arg_len: usize = 0,

    pub fn buildArgs(self: *const BuildOpts) []const []const u8 {
        return self.build_arg_buf[0..self.build_arg_len];
    }
};

pub const PodAction = enum { create, ps, stop, rm };

pub const PodOpts = struct {
    action: PodAction,
    arg: ?[]const u8 = null,
    force: bool = false,
};

pub const KillOpts = struct {
    container: []const u8,
    signal: []const u8 = "SIGTERM",
};

pub const RestartOpts = struct {
    container: []const u8,
    timeout_secs: ?u32 = null,
};

pub const RenameOpts = struct {
    container: []const u8,
    new_name: []const u8,
};

pub const RmiOpts = struct {
    image: []const u8,
    force: bool = false,
};

pub const VolumeAction = enum {
    ls,
    create,
    rm,
    inspect,
};

pub const VolumeOpts = struct {
    action: VolumeAction,
    name: ?[]const u8 = null,
    force: bool = false,
};

pub const AttachOpts = struct {
    container: []const u8,
    interactive: bool = false,
    tty: bool = false,
};

pub const CpDirection = enum {
    to_container,
    from_container,
};

pub const CpOpts = struct {
    direction: CpDirection,
    container: []const u8,
    container_path: []const u8,
    host_path: []const u8,
};

pub const NetworkAction = enum {
    ls,
    inspect,
    create,
    rm,
};

pub const NetworkOpts = struct {
    action: NetworkAction,
    name: ?[]const u8 = null,
    driver: []const u8 = "bridge",
    internal: bool = false,
    force: bool = false,
};

pub const PruneKind = enum { container, image, volume, network };

pub const SystemAction = enum {
    ping,
    df,
    prune,
};

pub const SystemOpts = struct {
    action: SystemAction,
    force: bool = false,
};

pub const PortOpts = struct {
    container: []const u8,
    private_port: ?[]const u8 = null,
};

pub const EventsOpts = struct {
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    json: bool = false,
};

pub const Shell = enum {
    bash,
    zsh,
    fish,
};

pub const TagOpts = struct {
    src_image: []const u8,
    target_image: []const u8,
};

pub const HistoryOpts = struct {
    image: []const u8,
    json: bool = false,
};

pub const CommitOpts = struct {
    container: []const u8,
    target_image: []const u8,
    message: ?[]const u8 = null,
    author: ?[]const u8 = null,
};

pub const SearchOpts = struct {
    term: []const u8,
};

pub const SaveOpts = struct {
    image: []const u8,
    output: []const u8,
};

pub const LoadOpts = struct {
    input: []const u8,
};

pub const ExportOpts = struct {
    container: []const u8,
    output: []const u8,
};

pub const ImportOpts = struct {
    input: []const u8,
    ref: []const u8,
};

pub const PolicyAction = enum {
    show,
    check,
};

pub const PolicyOpts = struct {
    action: PolicyAction,
    path: ?[]const u8 = null,
    json: bool = false,
};

pub const ComposeAction = enum {
    up,
    down,
    ps,
};

pub const ComposeOpts = struct {
    action: ComposeAction,
    file: ?[]const u8 = null,
    detach: bool = false,
    json: bool = false,
    profile: Profile = .default,
    policy_path: ?[]const u8 = null,
};

pub const Command = union(enum) {
    help,
    client_version,
    version,
    demo: DemoOpts,
    audit: AuditOpts,
    ps: PsOpts,
    images: ImagesOpts,
    pull: []const u8,
    rmi: RmiOpts,
    run: RunOpts,
    start: []const u8,
    stop: RestartOpts,
    restart: RestartOpts,
    pause: []const u8,
    unpause: []const u8,
    rename: RenameOpts,
    kill: KillOpts,
    rm: RmOpts,
    logs: LogsOpts,
    prune: PruneKind,
    top: []const u8,
    inspect: InspectOpts,
    exec: ExecOpts,
    attach: AttachOpts,
    stats: StatsOpts,
    volume: VolumeOpts,
    network: NetworkOpts,
    cp: CpOpts,
    system: SystemOpts,
    port: PortOpts,
    wait: []const u8,
    diff: []const u8,
    events: EventsOpts,
    tag: TagOpts,
    history: HistoryOpts,
    commit: CommitOpts,
    search: SearchOpts,
    save: SaveOpts,
    load: LoadOpts,
    @"export": ExportOpts,
    import: ImportOpts,
    policy: PolicyOpts,
    build: BuildOpts,
    pod: PodOpts,
    compose: ComposeOpts,
    completion: Shell,
};

pub const Parsed = struct {
    global: Global,
    command: Command,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        switch (self.command) {
            .run => |r| {
                if (r.env.len > 0) allocator.free(r.env);
                if (r.env_files.len > 0) allocator.free(r.env_files);
                if (r.volumes.len > 0) allocator.free(r.volumes);
                if (r.ports.len > 0) allocator.free(r.ports);
                if (r.labels.len > 0) allocator.free(r.labels);
                if (r.ulimits.len > 0) allocator.free(r.ulimits);
                if (r.cap_drop.len > 0) allocator.free(r.cap_drop);
                if (r.cap_add.len > 0) allocator.free(r.cap_add);
            },
            .exec => |e| {
                if (e.env.len > 0) allocator.free(e.env);
            },
            .stats => |s| {
                if (s.containers.len > 0) allocator.free(s.containers);
            },
            else => {},
        }
    }
};

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidValue,
    MissingArgument,
    TooManyArguments,
} || std.mem.Allocator.Error;

pub fn describeError(e: ParseError) []const u8 {
    return switch (e) {
        error.UnknownCommand => "unknown command",
        error.UnknownFlag => "unknown flag",
        error.MissingValue => "flag requires a value",
        error.InvalidValue => "invalid flag value",
        error.MissingArgument => "missing required argument",
        error.TooManyArguments => "too many arguments",
        error.OutOfMemory => "out of memory",
    };
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isFlag(a: []const u8) bool {
    return a.len > 1 and a[0] == '-';
}

/// Returns the value following the flag at `i.*` and advances `i`.
pub fn takeValue(args: []const []const u8, i: *usize) ParseError![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

// ---------------------------------------------------------------- tests

test "Volume struct default readonly is true" {
    const v = Volume{ .source = "/srv/data", .destination = "/data" };
    try std.testing.expectEqualStrings("/srv/data", v.source);
    try std.testing.expectEqualStrings("/data", v.destination);
    try std.testing.expect(v.readonly);

    const v_rw = Volume{ .source = "/srv/cache", .destination = "/cache", .readonly = false };
    try std.testing.expect(!v_rw.readonly);
}

test "PortMapping struct defaults" {
    const pm = PortMapping{ .container_port = 80 };
    try std.testing.expect(pm.host_ip == null);
    try std.testing.expect(pm.host_port == null);
    try std.testing.expectEqual(@as(u16, 80), pm.container_port);
    try std.testing.expectEqualStrings("tcp", pm.proto);

    const pm_full = PortMapping{
        .host_ip = "127.0.0.1",
        .host_port = 8080,
        .container_port = 9000,
        .proto = "udp",
    };
    try std.testing.expectEqualStrings("127.0.0.1", pm_full.host_ip.?);
    try std.testing.expectEqual(@as(?u16, 8080), pm_full.host_port);
    try std.testing.expectEqual(@as(u16, 9000), pm_full.container_port);
    try std.testing.expectEqualStrings("udp", pm_full.proto);
}

test "Profile enum values" {
    try std.testing.expect(@backingInt(Profile.default) == 0);
    try std.testing.expect(@backingInt(Profile.sandbox) == 1);
    try std.testing.expect(std.mem.eql(u8, @tagName(Profile.default), "default"));
    try std.testing.expect(std.mem.eql(u8, @tagName(Profile.sandbox), "sandbox"));
}

test "RunOpts default values" {
    const r = RunOpts{ .image = "alpine:3.20" };
    try std.testing.expectEqualStrings("alpine:3.20", r.image);
    try std.testing.expectEqual(@as(usize, 0), r.cmd.len);
    try std.testing.expectEqual(@as(usize, 0), r.env.len);
    try std.testing.expectEqual(@as(usize, 0), r.env_files.len);
    try std.testing.expectEqual(@as(usize, 0), r.volumes.len);
    try std.testing.expectEqual(@as(usize, 0), r.ports.len);
    try std.testing.expectEqual(@as(usize, 0), r.labels.len);
    try std.testing.expectEqual(@as(usize, 0), r.cap_drop.len);
    try std.testing.expectEqual(@as(usize, 0), r.cap_add.len);
    try std.testing.expect(r.name == null);
    try std.testing.expect(r.network == null);
    try std.testing.expect(r.workdir == null);
    try std.testing.expect(r.user == null);
    try std.testing.expect(r.entrypoint == null);
    try std.testing.expect(r.hostname == null);
    try std.testing.expect(r.restart_policy == null);
    try std.testing.expect(r.profile == .default);
    try std.testing.expect(r.policy_path == null);
    try std.testing.expect(r.detach == false);
    try std.testing.expect(r.interactive == false);
    try std.testing.expect(r.tty == false);
    try std.testing.expect(r.remove == false);
    try std.testing.expect(r.read_only == false);
    try std.testing.expect(r.no_new_privileges == false);
    try std.testing.expect(r.memory == null);
    try std.testing.expect(r.pids_limit == null);
    try std.testing.expect(r.nano_cpus == null);
}

test "Parsed.deinit frees owned slices for run command" {
    const alloc = std.testing.allocator;
    const env_arr = try alloc.alloc([]const u8, 1);
    env_arr[0] = "A=1";
    const env_files_arr = try alloc.alloc([]const u8, 1);
    env_files_arr[0] = "/srv/app.env";
    const volumes_arr = try alloc.alloc(Volume, 1);
    volumes_arr[0] = Volume{ .source = "/srv/data", .destination = "/data", .readonly = true };
    const ports_arr = try alloc.alloc(PortMapping, 1);
    ports_arr[0] = PortMapping{ .container_port = 80 };
    const labels_arr = try alloc.alloc(Label, 1);
    labels_arr[0] = Label{ .key = "env", .value = "prod" };
    const cap_drop_arr = try alloc.alloc([]const u8, 1);
    cap_drop_arr[0] = "ALL";
    const cap_add_arr = try alloc.alloc([]const u8, 1);
    cap_add_arr[0] = "NET_ADMIN";

    var p = Parsed{
        .global = .{},
        .command = .{
            .run = .{
                .image = "alpine:3.20",
                .env = env_arr,
                .env_files = env_files_arr,
                .volumes = volumes_arr,
                .ports = ports_arr,
                .labels = labels_arr,
                .cap_drop = cap_drop_arr,
                .cap_add = cap_add_arr,
            },
        },
    };
    p.deinit(alloc);
}

test "Parsed.deinit frees owned slices for exec command" {
    const alloc = std.testing.allocator;
    const env_arr = try alloc.alloc([]const u8, 1);
    env_arr[0] = "A=1";

    var p = Parsed{
        .global = .{},
        .command = .{
            .exec = .{
                .container = "web",
                .env = env_arr,
                .cmd = &.{"sh"},
            },
        },
    };
    p.deinit(alloc);
}

test "Parsed.deinit frees owned slices for stats command" {
    const alloc = std.testing.allocator;
    const containers_arr = try alloc.alloc([]const u8, 1);
    containers_arr[0] = "web";

    var p = Parsed{
        .global = .{},
        .command = .{
            .stats = .{
                .containers = containers_arr,
            },
        },
    };
    p.deinit(alloc);
}

test "Parsed.deinit is no-op for commands without owned slices" {
    const alloc = std.testing.allocator;
    var p = Parsed{ .global = .{}, .command = .{ .ps = .{} } };
    p.deinit(alloc);

    var p2 = Parsed{ .global = .{}, .command = .help };
    p2.deinit(alloc);

    var p3 = Parsed{ .global = .{}, .command = .{ .pull = "test-image" } };
    p3.deinit(alloc);

    var p4 = Parsed{ .global = .{}, .command = .version };
    p4.deinit(alloc);

    var p5 = Parsed{ .global = .{}, .command = .{ .demo = .{} } };
    p5.deinit(alloc);

    var p6 = Parsed{ .global = .{}, .command = .{ .audit = .{} } };
    p6.deinit(alloc);

    var p7 = Parsed{ .global = .{}, .command = .{ .completion = .bash } };
    p7.deinit(alloc);
}

test "ParseError error set contains expected errors" {
    // Verify each error variant has a distinct name via describeError.
    try std.testing.expectEqualStrings("unknown command", describeError(error.UnknownCommand));
    try std.testing.expectEqualStrings("unknown flag", describeError(error.UnknownFlag));
    try std.testing.expectEqualStrings("flag requires a value", describeError(error.MissingValue));
    try std.testing.expectEqualStrings("invalid flag value", describeError(error.InvalidValue));
    try std.testing.expectEqualStrings("missing required argument", describeError(error.MissingArgument));
    try std.testing.expectEqualStrings("too many arguments", describeError(error.TooManyArguments));
    try std.testing.expectEqualStrings("out of memory", describeError(error.OutOfMemory));
}

test "eql compares byte slices correctly" {
    try std.testing.expect(eql("abc", "abc"));
    try std.testing.expect(!eql("abc", "abd"));
    try std.testing.expect(eql("", ""));
    try std.testing.expect(!eql("a", ""));
    try std.testing.expect(!eql("", "a"));
}

test "isFlag detects dash-prefixed args" {
    try std.testing.expect(isFlag("-v"));
    try std.testing.expect(isFlag("--verbose"));
    try std.testing.expect(isFlag("-it"));
    try std.testing.expect(!isFlag("alpine"));
    try std.testing.expect(!isFlag("-")); // len == 1, not a flag
    try std.testing.expect(!isFlag("")); // empty
}

test "takeValue advances index and returns value, errors when missing" {
    var args = [_][]const u8{ "--socket", "/tmp/x.sock" };
    var i: usize = 0;
    const val = try takeValue(&args, &i);
    try std.testing.expectEqual(@as(usize, 1), i);
    try std.testing.expectEqualStrings("/tmp/x.sock", val);

    var args2 = [_][]const u8{"--socket"};
    var idx2: usize = 0;
    try std.testing.expectError(error.MissingValue, takeValue(&args2, &idx2));
}
