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
    \\      --rm                       Remove the container when it exits
    \\      --name NAME                Assign a name to the container
    \\      -e, --env KEY=VALUE        Set an environment variable (repeatable)
    \\      -v, --volume SRC:DST[:ro|rw]  Bind mount a host path (default: read-only)
    \\      -m, --memory BYTES         Memory limit (e.g., 64m, 1g, 1048576)
    \\      --pids-limit N             Limit container PIDs
    \\      --read-only                Mount container root filesystem as read-only
    \\      --no-new-privileges        Prevent privilege escalation inside container
    \\  ps [-a]                        List containers (-a: include stopped)
    \\  images                         List local images
    \\  pull IMAGE                     Pull an image from a registry
    \\  stop CONTAINER                 Stop a running container
    \\  rm [-f] CONTAINER              Remove a container (-f: force)
    \\  logs CONTAINER                 Print a container's logs
    \\  audit [FILE]                   Verify SHA-256 hash chain of audit.log
    \\  demo                           Run 14-case fail-closed ALLOW/DENY self-test suite
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

pub const RunOpts = struct {
    image: []const u8,
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    volumes: []const Volume = &.{},
    name: ?[]const u8 = null,
    detach: bool = false,
    remove: bool = false,
    read_only: bool = false,
    no_new_privileges: bool = false,
    memory: ?i64 = null,
    pids_limit: ?i64 = null,
};

pub const RmOpts = struct {
    container: []const u8,
    force: bool = false,
};

pub const Command = union(enum) {
    help,
    client_version,
    version,
    demo,
    audit: ?[]const u8,
    ps: struct { all: bool = false },
    images,
    pull: []const u8,
    run: RunOpts,
    stop: []const u8,
    rm: RmOpts,
    logs: []const u8,
};

pub const Parsed = struct {
    global: Global,
    command: Command,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        switch (self.command) {
            .run => |r| {
                if (r.env.len > 0) allocator.free(r.env);
                if (r.volumes.len > 0) allocator.free(r.volumes);
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

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isFlag(a: []const u8) bool {
    return a.len > 1 and a[0] == '-';
}

/// Returns the value following the flag at `i.*` and advances `i`.
fn takeValue(args: []const []const u8, i: *usize) ParseError![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

/// `args` excludes the program name. Slices in the result point into `args`
/// or into memory from `allocator` (use an arena).
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Parsed {
    var global = Global{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-v") or eql(a, "--verbose")) {
            global.verbose = true;
        } else if (eql(a, "--socket")) {
            global.socket = try takeValue(args, &i);
        } else if (eql(a, "-h") or eql(a, "--help")) {
            return .{ .global = global, .command = .help };
        } else if (eql(a, "--version")) {
            return .{ .global = global, .command = .client_version };
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else break;
    }
    if (i >= args.len) return .{ .global = global, .command = .help };

    const name = args[i];
    const rest = args[i + 1 ..];
    const command: Command = if (eql(name, "run"))
        .{ .run = try parseRun(allocator, rest) }
    else if (eql(name, "ps"))
        try parsePs(rest)
    else if (eql(name, "images"))
        try noArgs(rest, .images)
    else if (eql(name, "pull"))
        .{ .pull = try single(rest) }
    else if (eql(name, "stop"))
        .{ .stop = try single(rest) }
    else if (eql(name, "rm"))
        try parseRm(rest)
    else if (eql(name, "logs"))
        .{ .logs = try single(rest) }
    else if (eql(name, "audit"))
        try parseAudit(rest)
    else if (eql(name, "demo"))
        try noArgs(rest, .demo)
    else if (eql(name, "version"))
        try noArgs(rest, .version)
    else if (eql(name, "help"))
        .help
    else
        return error.UnknownCommand;

    return .{ .global = global, .command = command };
}

fn parseAudit(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .{ .audit = null };
    if (isFlag(args[0])) return error.UnknownFlag;
    if (args.len > 1) return error.TooManyArguments;
    return .{ .audit = args[0] };
}

fn noArgs(args: []const []const u8, cmd: Command) ParseError!Command {
    if (args.len > 0) return if (isFlag(args[0])) error.UnknownFlag else error.TooManyArguments;
    return cmd;
}

fn single(args: []const []const u8) ParseError![]const u8 {
    if (args.len == 0) return error.MissingArgument;
    if (isFlag(args[0])) return error.UnknownFlag;
    if (args.len > 1) return error.TooManyArguments;
    return args[0];
}

fn parsePs(args: []const []const u8) ParseError!Command {
    var all = false;
    for (args) |a| {
        if (eql(a, "-a") or eql(a, "--all")) all = true else if (isFlag(a)) return error.UnknownFlag else return error.TooManyArguments;
    }
    return .{ .ps = .{ .all = all } };
}

fn parseRm(args: []const []const u8) ParseError!Command {
    var opts = RmOpts{ .container = "" };
    for (args) |a| {
        if (eql(a, "-f") or eql(a, "--force")) {
            opts.force = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (opts.container.len == 0) {
            opts.container = a;
        } else return error.TooManyArguments;
    }
    if (opts.container.len == 0) return error.MissingArgument;
    return .{ .rm = opts };
}

pub fn parseMemoryBytes(s: []const u8) ParseError!i64 {
    if (s.len == 0) return error.InvalidValue;
    var num_end = s.len;
    var mult: i64 = 1;
    if (std.ascii.endsWithIgnoreCase(s, "kb")) {
        num_end = s.len - 2;
        mult = 1024;
    } else if (std.ascii.endsWithIgnoreCase(s, "mb")) {
        num_end = s.len - 2;
        mult = 1024 * 1024;
    } else if (std.ascii.endsWithIgnoreCase(s, "gb")) {
        num_end = s.len - 2;
        mult = 1024 * 1024 * 1024;
    } else {
        switch (s[s.len - 1]) {
            'b', 'B' => {
                num_end = s.len - 1;
                mult = 1;
            },
            'k', 'K' => {
                num_end = s.len - 1;
                mult = 1024;
            },
            'm', 'M' => {
                num_end = s.len - 1;
                mult = 1024 * 1024;
            },
            'g', 'G' => {
                num_end = s.len - 1;
                mult = 1024 * 1024 * 1024;
            },
            else => {},
        }
    }
    if (num_end == 0) return error.InvalidValue;
    const base = std.fmt.parseInt(i64, s[0..num_end], 10) catch return error.InvalidValue;
    if (base <= 0) return error.InvalidValue;
    return std.math.mul(i64, base, mult) catch error.InvalidValue;
}

fn parsePidsLimit(s: []const u8) ParseError!i64 {
    const limit = std.fmt.parseInt(i64, s, 10) catch return error.InvalidValue;
    if (limit <= 0) return error.InvalidValue;
    return limit;
}

/// Parses a `SRC:DST[:ro|rw]` volume specification. Only syntax is checked
/// here; the host-path security policy is enforced by `podman_api.makeMount`.
fn parseVolumeSpec(spec: []const u8) ParseError!Volume {
    const first = std.mem.indexOfScalar(u8, spec, ':') orelse return error.InvalidValue;
    const source = spec[0..first];
    const rest = spec[first + 1 ..];

    var destination = rest;
    var readonly = true;
    if (std.mem.indexOfScalar(u8, rest, ':')) |second| {
        destination = rest[0..second];
        const opt = rest[second + 1 ..];
        if (std.mem.indexOfScalar(u8, opt, ':') != null) return error.InvalidValue;
        if (eql(opt, "ro")) {
            readonly = true;
        } else if (eql(opt, "rw")) {
            readonly = false;
        } else return error.InvalidValue;
    }
    if (source.len == 0 or destination.len == 0) return error.InvalidValue;
    return .{ .source = source, .destination = destination, .readonly = readonly };
}

fn parseRun(allocator: std.mem.Allocator, args: []const []const u8) ParseError!RunOpts {
    var opts = RunOpts{ .image = "" };
    var env = std.ArrayList([]const u8).init(allocator);
    errdefer env.deinit();
    var volumes = std.ArrayList(Volume).init(allocator);
    errdefer volumes.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-d") or eql(a, "--detach")) {
            opts.detach = true;
        } else if (eql(a, "--rm")) {
            opts.remove = true;
        } else if (eql(a, "--read-only")) {
            opts.read_only = true;
        } else if (eql(a, "--no-new-privileges")) {
            opts.no_new_privileges = true;
        } else if (eql(a, "-m") or eql(a, "--memory")) {
            opts.memory = try parseMemoryBytes(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--memory=")) {
            opts.memory = try parseMemoryBytes(a["--memory=".len..]);
        } else if (eql(a, "--pids-limit")) {
            opts.pids_limit = try parsePidsLimit(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--pids-limit=")) {
            opts.pids_limit = try parsePidsLimit(a["--pids-limit=".len..]);
        } else if (eql(a, "--name")) {
            opts.name = try takeValue(args, &i);
        } else if (eql(a, "-e") or eql(a, "--env")) {
            try env.append(try takeValue(args, &i));
        } else if (eql(a, "-v") or eql(a, "--volume")) {
            try volumes.append(try parseVolumeSpec(try takeValue(args, &i)));
        } else if (std.mem.startsWith(u8, a, "--volume=")) {
            try volumes.append(try parseVolumeSpec(a["--volume=".len..]));
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else break; // first positional = IMAGE; everything after is the command
    }
    if (i >= args.len) return error.MissingArgument;
    opts.image = args[i];
    opts.cmd = args[i + 1 ..];
    opts.env = try env.toOwnedSlice();
    errdefer allocator.free(opts.env);
    opts.volumes = try volumes.toOwnedSlice();
    return opts;
}

// ---------------------------------------------------------------- tests

fn testParse(args: []const []const u8) !Parsed {
    return parse(std.testing.allocator, args);
}

test "run with flags and command" {
    const p = try testParse(&.{ "-v", "run", "--rm", "-e", "A=1", "--env", "B=2", "--name", "web", "alpine:3.20", "echo", "-n", "hi" });
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(p.global.verbose);
    const r = p.command.run;
    try std.testing.expectEqualStrings("alpine:3.20", r.image);
    try std.testing.expectEqualStrings("web", r.name.?);
    try std.testing.expect(r.remove and !r.detach);
    try std.testing.expectEqual(@as(usize, 2), r.env.len);
    try std.testing.expectEqualStrings("A=1", r.env[0]);
    try std.testing.expectEqualStrings("B=2", r.env[1]);
    // Flags after IMAGE belong to the container command, like docker.
    try std.testing.expectEqual(@as(usize, 3), r.cmd.len);
    try std.testing.expectEqualStrings("-n", r.cmd[1]);
}

test "run detached without command or env" {
    const p = try testParse(&.{ "run", "-d", "nginx:alpine" });
    defer p.deinit(std.testing.allocator);
    const r = p.command.run;
    try std.testing.expect(r.detach);
    try std.testing.expect(!r.remove);
    try std.testing.expect(r.name == null);
    try std.testing.expectEqual(@as(usize, 0), r.env.len);
    try std.testing.expectEqual(@as(usize, 0), r.cmd.len);
    try std.testing.expectEqualStrings("nginx:alpine", r.image);
}

test "run error path frees env allocations without leaks" {
    try std.testing.expectError(error.MissingValue, testParse(&.{ "run", "-e", "A=1", "--env", "B=2", "--name" }));
    try std.testing.expectError(error.MissingArgument, testParse(&.{ "run", "-e", "A=1", "--rm" }));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "run", "-e", "A=1", "--bogus", "alpine" }));
}

test "simple commands" {
    try std.testing.expect((try testParse(&.{})).command == .help);
    try std.testing.expect((try testParse(&.{ "-h" })).command == .help);
    try std.testing.expect((try testParse(&.{"--help"})).command == .help);
    try std.testing.expect((try testParse(&.{"help"})).command == .help);
    try std.testing.expect((try testParse(&.{"--version"})).command == .client_version);
    try std.testing.expect((try testParse(&.{"version"})).command == .version);
    try std.testing.expect((try testParse(&.{"images"})).command == .images);
    try std.testing.expect(!(try testParse(&.{"ps"})).command.ps.all);
    try std.testing.expect((try testParse(&.{ "ps", "-a" })).command.ps.all);
    try std.testing.expect((try testParse(&.{ "ps", "--all" })).command.ps.all);
    try std.testing.expectEqualStrings("alpine", (try testParse(&.{ "pull", "alpine" })).command.pull);
    try std.testing.expectEqualStrings("web", (try testParse(&.{ "stop", "web" })).command.stop);
    try std.testing.expectEqualStrings("web", (try testParse(&.{ "logs", "web" })).command.logs);
    const rm_plain = (try testParse(&.{ "rm", "abc" })).command.rm;
    try std.testing.expect(!rm_plain.force);
    try std.testing.expectEqualStrings("abc", rm_plain.container);
    const rm = (try testParse(&.{ "rm", "-f", "abc" })).command.rm;
    try std.testing.expect(rm.force);
    try std.testing.expectEqualStrings("abc", rm.container);
    const rm_long = (try testParse(&.{ "rm", "--force", "abc" })).command.rm;
    try std.testing.expect(rm_long.force);
    const g = (try testParse(&.{ "--socket", "/tmp/s.sock", "--verbose", "images" })).global;
    try std.testing.expect(g.verbose);
    try std.testing.expectEqualStrings("/tmp/s.sock", g.socket.?);
}

test "parse errors" {
    try std.testing.expectError(error.UnknownCommand, testParse(&.{"frobnicate"}));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{"--bogus"}));
    try std.testing.expectError(error.MissingValue, testParse(&.{"--socket"}));
    try std.testing.expectError(error.MissingArgument, testParse(&.{"run"}));
    try std.testing.expectError(error.MissingArgument, testParse(&.{ "run", "--rm" }));
    try std.testing.expectError(error.MissingValue, testParse(&.{ "run", "--name" }));
    try std.testing.expectError(error.MissingArgument, testParse(&.{"pull"}));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "pull", "--bad" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "pull", "a", "b" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "stop", "a", "b" }));
    try std.testing.expectError(error.MissingArgument, testParse(&.{"logs"}));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "logs", "a", "b" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "images", "extra" }));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "images", "--all" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "version", "extra" }));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "ps", "--bogus" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "ps", "extra" }));
    try std.testing.expectError(error.MissingArgument, testParse(&.{ "rm", "-f" }));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "rm", "--bogus", "a" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "rm", "a", "b" }));
}

test "parse run hardening flags and memory suffixes" {
    const alloc = std.testing.allocator;
    var parsed = try parse(alloc, &.{
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
    });
    defer parsed.deinit(alloc);

    switch (parsed.command) {
        .run => |r| {
            try std.testing.expect(r.remove);
            try std.testing.expect(r.read_only);
            try std.testing.expect(r.no_new_privileges);
            try std.testing.expectEqual(@as(?i64, 64 * 1024 * 1024), r.memory);
            try std.testing.expectEqual(@as(?i64, 32), r.pids_limit);
            try std.testing.expectEqualStrings("alpine:3.20", r.image);
            try std.testing.expectEqual(@as(usize, 2), r.cmd.len);
        },
        else => return error.TestUnexpectedResult,
    }

    var p_bytes = try parse(alloc, &.{ "run", "--memory=1024b", "alpine:3.20" });
    defer p_bytes.deinit(alloc);
    try std.testing.expectEqual(@as(?i64, 1024), p_bytes.command.run.memory);

    var p_kib = try parse(alloc, &.{ "run", "-m", "2K", "alpine:3.20" });
    defer p_kib.deinit(alloc);
    try std.testing.expectEqual(@as(?i64, 2048), p_kib.command.run.memory);

    var p_gib = try parse(alloc, &.{ "run", "--memory", "1g", "alpine:3.20" });
    defer p_gib.deinit(alloc);
    try std.testing.expectEqual(@as(?i64, 1024 * 1024 * 1024), p_gib.command.run.memory);
}

test "parse rejects invalid hardening values" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-m", "0", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--memory", "-1m", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--memory", "abc", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--memory", "99999999999999999g", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--memory=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "-m" }));

    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--pids-limit", "0", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--pids-limit", "-5", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--pids-limit", "nope", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--pids-limit=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "--pids-limit" }));
}

test "parse run volume mounts with default read-only and explicit options" {
    const alloc = std.testing.allocator;
    var parsed = try parse(alloc, &.{
        "run",
        "-v",
        "/srv/data:/data",
        "--volume",
        "/srv/cache:/cache:rw",
        "--volume=/etc/hosts:/etc/hosts:ro",
        "alpine:3.20",
    });
    defer parsed.deinit(alloc);

    const r = parsed.command.run;
    try std.testing.expectEqual(@as(usize, 3), r.volumes.len);
    try std.testing.expectEqualStrings("/srv/data", r.volumes[0].source);
    try std.testing.expectEqualStrings("/data", r.volumes[0].destination);
    try std.testing.expect(r.volumes[0].readonly); // default is read-only
    try std.testing.expectEqualStrings("/srv/cache", r.volumes[1].source);
    try std.testing.expect(!r.volumes[1].readonly);
    try std.testing.expectEqualStrings("/etc/hosts", r.volumes[2].source);
    try std.testing.expect(r.volumes[2].readonly);
    try std.testing.expectEqualStrings("alpine:3.20", r.image);
}

test "parse rejects malformed volume specs without leaking allocations" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-v", "/onlysource", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-v", ":/dest", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-v", "/src:", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-v", "/src:/dst:bogus", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-v", "/a:/b:ro:extra", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--volume=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "-v" }));
    // A parsed volume must be freed when a later error aborts the parse.
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "run", "-v", "/src:/dst" }));
}

test "parse demo and audit subcommands" {
    const alloc = std.testing.allocator;
    var p_demo = try parse(alloc, &.{"demo"});
    defer p_demo.deinit(alloc);
    try std.testing.expect(p_demo.command == .demo);
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "demo", "extra" }));

    var p_audit_default = try parse(alloc, &.{"audit"});
    defer p_audit_default.deinit(alloc);
    switch (p_audit_default.command) {
        .audit => |path| try std.testing.expect(path == null),
        else => return error.TestUnexpectedResult,
    }

    var p_audit_file = try parse(alloc, &.{ "audit", "/tmp/custom-audit.log" });
    defer p_audit_file.deinit(alloc);
    switch (p_audit_file.command) {
        .audit => |path| try std.testing.expectEqualStrings("/tmp/custom-audit.log", path.?),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "audit", "a.log", "b.log" }));
}
