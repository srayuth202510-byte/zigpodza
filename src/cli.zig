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
    \\  ps [-a]                        List containers (-a: include stopped)
    \\  images                         List local images
    \\  pull IMAGE                     Pull an image from a registry
    \\  stop CONTAINER                 Stop a running container
    \\  rm [-f] CONTAINER              Remove a container (-f: force)
    \\  logs CONTAINER                 Print a container's logs
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

pub const RunOpts = struct {
    image: []const u8,
    cmd: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    detach: bool = false,
    remove: bool = false,
};

pub const RmOpts = struct {
    container: []const u8,
    force: bool = false,
};

pub const Command = union(enum) {
    help,
    client_version,
    version,
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
};

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    MissingArgument,
    TooManyArguments,
} || std.mem.Allocator.Error;

pub fn describeError(e: ParseError) []const u8 {
    return switch (e) {
        error.UnknownCommand => "unknown command",
        error.UnknownFlag => "unknown flag",
        error.MissingValue => "flag requires a value",
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
    else if (eql(name, "version"))
        try noArgs(rest, .version)
    else if (eql(name, "help"))
        .help
    else
        return error.UnknownCommand;

    return .{ .global = global, .command = command };
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

fn parseRun(allocator: std.mem.Allocator, args: []const []const u8) ParseError!RunOpts {
    var opts = RunOpts{ .image = "" };
    var env = std.ArrayList([]const u8).init(allocator);
    errdefer env.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-d") or eql(a, "--detach")) {
            opts.detach = true;
        } else if (eql(a, "--rm")) {
            opts.remove = true;
        } else if (eql(a, "--name")) {
            opts.name = try takeValue(args, &i);
        } else if (eql(a, "-e") or eql(a, "--env")) {
            try env.append(try takeValue(args, &i));
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else break; // first positional = IMAGE; everything after is the command
    }
    if (i >= args.len) return error.MissingArgument;
    opts.image = args[i];
    opts.cmd = args[i + 1 ..];
    opts.env = try env.toOwnedSlice();
    return opts;
}

// ---------------------------------------------------------------- tests

fn testParse(args: []const []const u8) !Parsed {
    // Leaks into the testing arena below; callers use an arena.
    return parse(test_arena.allocator(), args);
}
var test_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

test "run with flags and command" {
    const p = try testParse(&.{ "-v", "run", "--rm", "-e", "A=1", "--env", "B=2", "--name", "web", "alpine:3.20", "echo", "-n", "hi" });
    try std.testing.expect(p.global.verbose);
    const r = p.command.run;
    try std.testing.expectEqualStrings("alpine:3.20", r.image);
    try std.testing.expectEqualStrings("web", r.name.?);
    try std.testing.expect(r.remove and !r.detach);
    try std.testing.expectEqual(@as(usize, 2), r.env.len);
    try std.testing.expectEqualStrings("B=2", r.env[1]);
    // Flags after IMAGE belong to the container command, like docker.
    try std.testing.expectEqual(@as(usize, 3), r.cmd.len);
    try std.testing.expectEqualStrings("-n", r.cmd[1]);
}

test "simple commands" {
    try std.testing.expect((try testParse(&.{})).command == .help);
    try std.testing.expect((try testParse(&.{"--version"})).command == .client_version);
    try std.testing.expect((try testParse(&.{ "ps", "-a" })).command.ps.all);
    try std.testing.expectEqualStrings("alpine", (try testParse(&.{ "pull", "alpine" })).command.pull);
    const rm = (try testParse(&.{ "rm", "-f", "abc" })).command.rm;
    try std.testing.expect(rm.force);
    try std.testing.expectEqualStrings("abc", rm.container);
    const g = (try testParse(&.{ "--socket", "/tmp/s.sock", "images" })).global;
    try std.testing.expectEqualStrings("/tmp/s.sock", g.socket.?);
}

test "parse errors" {
    try std.testing.expectError(error.UnknownCommand, testParse(&.{"frobnicate"}));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{"--bogus"}));
    try std.testing.expectError(error.MissingArgument, testParse(&.{"run"}));
    try std.testing.expectError(error.MissingArgument, testParse(&.{ "run", "--rm" }));
    try std.testing.expectError(error.MissingValue, testParse(&.{ "run", "--name" }));
    try std.testing.expectError(error.MissingArgument, testParse(&.{"pull"}));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "stop", "a", "b" }));
}
