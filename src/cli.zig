//! Pure-Zig Podman/Docker-compatible CLI parser.
const std = @import("std");
pub const types = @import("cli_types.zig");
pub const specs = @import("cli_specs.zig");

pub const usage = types.usage;
pub const Global = types.Global;
pub const Volume = types.Volume;
pub const PortMapping = types.PortMapping;
pub const Label = types.Label;
pub const RestartPolicySpec = types.RestartPolicySpec;
pub const Profile = types.Profile;
pub const RunOpts = types.RunOpts;
pub const AttachOpts = types.AttachOpts;
pub const CpDirection = types.CpDirection;
pub const CpOpts = types.CpOpts;
pub const RmOpts = types.RmOpts;
pub const LogsOpts = types.LogsOpts;
pub const ExecOpts = types.ExecOpts;
pub const StatsOpts = types.StatsOpts;
pub const PsOpts = types.PsOpts;
pub const ImagesOpts = types.ImagesOpts;
pub const InspectOpts = types.InspectOpts;
pub const AuditOpts = types.AuditOpts;
pub const KillOpts = types.KillOpts;
pub const RestartOpts = types.RestartOpts;
pub const RenameOpts = types.RenameOpts;
pub const RmiOpts = types.RmiOpts;
pub const VolumeAction = types.VolumeAction;
pub const VolumeOpts = types.VolumeOpts;
pub const NetworkAction = types.NetworkAction;
pub const NetworkOpts = types.NetworkOpts;
pub const SystemAction = types.SystemAction;
pub const SystemOpts = types.SystemOpts;
pub const PortOpts = types.PortOpts;
pub const EventsOpts = types.EventsOpts;
pub const Shell = types.Shell;
pub const TagOpts = types.TagOpts;
pub const HistoryOpts = types.HistoryOpts;
pub const CommitOpts = types.CommitOpts;
pub const PolicyAction = types.PolicyAction;
pub const PolicyOpts = types.PolicyOpts;
pub const Command = types.Command;
pub const Parsed = types.Parsed;
pub const ParseError = types.ParseError;
pub const describeError = types.describeError;

const eql = types.eql;
const isFlag = types.isFlag;
const takeValue = types.takeValue;

pub const parseMemoryBytes = specs.parseMemoryBytes;
const parseProfile = specs.parseProfile;
const parsePolicyPath = specs.parsePolicyPath;
const parsePidsLimit = specs.parsePidsLimit;
const parseVolumeSpec = specs.parseVolumeSpec;
const parsePortNumber = specs.parsePortNumber;
const parsePortSpec = specs.parsePortSpec;
const parseNetworkMode = specs.parseNetworkMode;
const parseWorkdir = specs.parseWorkdir;
const parseUserSpec = specs.parseUserSpec;
const parseCapName = specs.parseCapName;
const parseSignal = specs.parseSignal;
const parseCpuNanos = specs.parseCpuNanos;
const parseLabelSpec = specs.parseLabelSpec;
const parseHostname = specs.parseHostname;
const parseEntrypoint = specs.parseEntrypoint;
const parseRestartPolicy = specs.parseRestartPolicy;
const parseEnvFilePath = specs.parseEnvFilePath;
const parseNetworkDriver = specs.parseNetworkDriver;
const parseCpEndpoints = specs.parseCpEndpoints;

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
        } else if (std.mem.startsWith(u8, a, "--socket=")) {
            const v = a["--socket=".len..];
            if (v.len == 0) return error.MissingValue;
            global.socket = v;
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
        try parseImages(rest)
    else if (eql(name, "pull"))
        .{ .pull = try single(rest) }
    else if (eql(name, "rmi"))
        try parseRmi(rest)
    else if (eql(name, "start"))
        .{ .start = try single(rest) }
    else if (eql(name, "stop"))
        .{ .stop = try single(rest) }
    else if (eql(name, "restart"))
        try parseRestart(rest)
    else if (eql(name, "pause"))
        .{ .pause = try single(rest) }
    else if (eql(name, "unpause"))
        .{ .unpause = try single(rest) }
    else if (eql(name, "rename"))
        try parseRename(rest)
    else if (eql(name, "kill"))
        try parseKill(rest)
    else if (eql(name, "rm"))
        try parseRm(rest)
    else if (eql(name, "logs"))
        try parseLogs(rest)
    else if (eql(name, "top"))
        .{ .top = try single(rest) }
    else if (eql(name, "inspect"))
        try parseInspect(rest)
    else if (eql(name, "exec"))
        .{ .exec = try parseExec(allocator, rest) }
    else if (eql(name, "attach"))
        try parseAttach(rest)
    else if (eql(name, "cp"))
        try parseCp(rest)
    else if (eql(name, "stats"))
        .{ .stats = try parseStats(allocator, rest) }
    else if (eql(name, "volume"))
        try parseVolume(rest)
    else if (eql(name, "network"))
        try parseNetwork(rest)
    else if (eql(name, "system"))
        try parseSystem(rest)
    else if (eql(name, "port"))
        try parsePortCmd(rest)
    else if (eql(name, "wait"))
        .{ .wait = try single(rest) }
    else if (eql(name, "diff"))
        .{ .diff = try single(rest) }
    else if (eql(name, "events"))
        try parseEvents(rest)
    else if (eql(name, "tag"))
        try parseTag(rest)
    else if (eql(name, "history"))
        try parseHistory(rest)
    else if (eql(name, "commit"))
        try parseCommit(rest)
    else if (eql(name, "search"))
        .{ .search = .{ .term = try single(rest) } }
    else if (eql(name, "save"))
        try parseSave(rest)
    else if (eql(name, "load"))
        try parseLoad(rest)
    else if (eql(name, "export"))
        try parseExport(rest)
    else if (eql(name, "import"))
        try parseImport(rest)
    else if (eql(name, "policy"))
        try parsePolicyCmd(rest)
    else if (eql(name, "build"))
        try parseBuild(rest)
    else if (eql(name, "pod"))
        try parsePodCmd(rest)
    else if (eql(name, "completion"))
        try parseCompletion(rest)
    else if (eql(name, "audit"))
        try parseAudit(rest)
    else if (eql(name, "demo"))
        try parseDemo(rest)
    else if (eql(name, "version"))
        try noArgs(rest, .version)
    else if (eql(name, "help"))
        .help
    else
        return error.UnknownCommand;

    return .{ .global = global, .command = command };
}

fn parseAudit(args: []const []const u8) ParseError!Command {
    var opts = AuditOpts{};
    for (args) |a| {
        if (eql(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (opts.path == null) {
            opts.path = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .audit = opts };
}

fn parseBuild(args: []const []const u8) ParseError!Command {
    var tag: ?[]const u8 = null;
    var ctx: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-t") or eql(a, "--tag")) {
            tag = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--tag=")) {
            const v = a["--tag=".len..];
            if (v.len == 0) return error.MissingValue;
            tag = v;
        } else if (std.mem.startsWith(u8, a, "-t=")) {
            const v = a["-t=".len..];
            if (v.len == 0) return error.MissingValue;
            tag = v;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (ctx == null) {
            ctx = a;
        } else {
            return error.TooManyArguments;
        }
    }
    if (tag == null) return error.MissingValue;
    if (ctx == null) return error.MissingArgument;
    return .{ .build = .{ .tag = tag.?, .ctx = ctx.? } };
}

fn parsePodCmd(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingArgument;
    var rest = args;
    const action_str = rest[0];
    rest = rest[1..];

    if (eql(action_str, "create")) {
        if (rest.len != 1) return if (rest.len > 1) error.TooManyArguments else error.MissingArgument;
        if (isFlag(rest[0])) return error.UnknownFlag;
        return .{ .pod = .{ .action = .create, .arg = rest[0] } };
    }
    if (eql(action_str, "ps")) {
        if (rest.len > 0) return if (isFlag(rest[0])) error.UnknownFlag else error.TooManyArguments;
        return .{ .pod = .{ .action = .ps } };
    }
    if (eql(action_str, "stop")) {
        if (rest.len != 1) return if (rest.len > 1) error.TooManyArguments else error.MissingArgument;
        if (isFlag(rest[0])) return error.UnknownFlag;
        return .{ .pod = .{ .action = .stop, .arg = rest[0] } };
    }
    if (eql(action_str, "rm")) {
        var force = false;
        var arg: ?[]const u8 = null;
        for (rest) |a| {
            if (eql(a, "-f") or eql(a, "--force")) {
                force = true;
            } else if (isFlag(a)) {
                return error.UnknownFlag;
            } else if (arg == null) {
                arg = a;
            } else {
                return error.TooManyArguments;
            }
        }
        if (arg == null) return error.MissingArgument;
        return .{ .pod = .{ .action = .rm, .arg = arg, .force = force } };
    }
    return error.UnknownCommand;
}


fn noArgs(args: []const []const u8, cmd: Command) ParseError!Command {
    if (args.len > 0) return if (isFlag(args[0])) error.UnknownFlag else error.TooManyArguments;
    return cmd;
}

fn parseDemo(args: []const []const u8) ParseError!Command {
    var json_mode = false;
    for (args) |a| {
        if (eql(a, "--json")) {
            json_mode = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .demo = .{ .json = json_mode } };
}

fn single(args: []const []const u8) ParseError![]const u8 {
    if (args.len == 0) return error.MissingArgument;
    if (isFlag(args[0])) return error.UnknownFlag;
    if (args.len > 1) return error.TooManyArguments;
    return args[0];
}

fn parsePs(args: []const []const u8) ParseError!Command {
    var opts = PsOpts{};
    for (args) |a| {
        if (eql(a, "-a") or eql(a, "--all")) {
            opts.all = true;
        } else if (eql(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .ps = opts };
}

fn parseImages(args: []const []const u8) ParseError!Command {
    var opts = ImagesOpts{};
    for (args) |a| {
        if (eql(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .images = opts };
}

fn parseInspect(args: []const []const u8) ParseError!Command {
    var json = false;
    var target: ?[]const u8 = null;
    for (args) |a| {
        if (eql(a, "--json")) {
            json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (target == null) {
            target = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .inspect = .{
        .target = target orelse return error.MissingArgument,
        .json = json,
    } };
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

fn parseLogs(args: []const []const u8) ParseError!Command {
    var opts = LogsOpts{ .container = "" };
    for (args) |a| {
        if (eql(a, "-f") or eql(a, "--follow")) {
            opts.follow = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (opts.container.len == 0) {
            opts.container = a;
        } else return error.TooManyArguments;
    }
    if (opts.container.len == 0) return error.MissingArgument;
    return .{ .logs = opts };
}


fn parseRun(allocator: std.mem.Allocator, args: []const []const u8) ParseError!RunOpts {
    var opts = RunOpts{ .image = "" };
    var env = std.ArrayList([]const u8).init(allocator);
    errdefer env.deinit();
    var env_files = std.ArrayList([]const u8).init(allocator);
    errdefer env_files.deinit();
    var volumes = std.ArrayList(Volume).init(allocator);
    errdefer volumes.deinit();
    var ports = std.ArrayList(PortMapping).init(allocator);
    errdefer ports.deinit();
    var labels = std.ArrayList(Label).init(allocator);
    errdefer labels.deinit();
    var cap_drop = std.ArrayList([]const u8).init(allocator);
    errdefer cap_drop.deinit();
    var cap_add = std.ArrayList([]const u8).init(allocator);
    errdefer cap_add.deinit();

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
        } else if (eql(a, "-p") or eql(a, "--publish")) {
            try ports.append(try parsePortSpec(try takeValue(args, &i)));
        } else if (std.mem.startsWith(u8, a, "--publish=")) {
            try ports.append(try parsePortSpec(a["--publish=".len..]));
        } else if (eql(a, "--network")) {
            opts.network = try parseNetworkMode(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--network=")) {
            opts.network = try parseNetworkMode(a["--network=".len..]);
        } else if (eql(a, "-w") or eql(a, "--workdir")) {
            opts.workdir = try parseWorkdir(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--workdir=")) {
            opts.workdir = try parseWorkdir(a["--workdir=".len..]);
        } else if (eql(a, "-u") or eql(a, "--user")) {
            opts.user = try parseUserSpec(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--user=")) {
            opts.user = try parseUserSpec(a["--user=".len..]);
        } else if (eql(a, "--cap-drop")) {
            try cap_drop.append(try parseCapName(try takeValue(args, &i)));
        } else if (std.mem.startsWith(u8, a, "--cap-drop=")) {
            try cap_drop.append(try parseCapName(a["--cap-drop=".len..]));
        } else if (eql(a, "--cap-add")) {
            try cap_add.append(try parseCapName(try takeValue(args, &i)));
        } else if (std.mem.startsWith(u8, a, "--cap-add=")) {
            try cap_add.append(try parseCapName(a["--cap-add=".len..]));
        } else if (eql(a, "-i") or eql(a, "--interactive")) {
            opts.interactive = true;
        } else if (eql(a, "-t") or eql(a, "--tty")) {
            opts.tty = true;
        } else if (eql(a, "-it") or eql(a, "-ti")) {
            opts.interactive = true;
            opts.tty = true;
        } else if (eql(a, "--profile")) {
            opts.profile = try parseProfile(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--profile=")) {
            opts.profile = try parseProfile(a["--profile=".len..]);
        } else if (eql(a, "--policy")) {
            opts.policy_path = try parsePolicyPath(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--policy=")) {
            opts.policy_path = try parsePolicyPath(a["--policy=".len..]);
        } else if (eql(a, "--cpus")) {
            opts.nano_cpus = try parseCpuNanos(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--cpus=")) {
            opts.nano_cpus = try parseCpuNanos(a["--cpus=".len..]);
        } else if (eql(a, "--env-file")) {
            try env_files.append(try parseEnvFilePath(try takeValue(args, &i)));
        } else if (std.mem.startsWith(u8, a, "--env-file=")) {
            try env_files.append(try parseEnvFilePath(a["--env-file=".len..]));
        } else if (eql(a, "-l") or eql(a, "--label")) {
            try labels.append(try parseLabelSpec(try takeValue(args, &i)));
        } else if (std.mem.startsWith(u8, a, "--label=")) {
            try labels.append(try parseLabelSpec(a["--label=".len..]));
        } else if (eql(a, "--entrypoint")) {
            opts.entrypoint = try parseEntrypoint(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--entrypoint=")) {
            opts.entrypoint = try parseEntrypoint(a["--entrypoint=".len..]);
        } else if (eql(a, "--hostname")) {
            opts.hostname = try parseHostname(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--hostname=")) {
            opts.hostname = try parseHostname(a["--hostname=".len..]);
        } else if (eql(a, "--restart")) {
            opts.restart_policy = try parseRestartPolicy(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--restart=")) {
            opts.restart_policy = try parseRestartPolicy(a["--restart=".len..]);
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else break; // first positional = IMAGE; everything after is the command
    }
    if (i >= args.len) return error.MissingArgument;
    opts.image = args[i];
    opts.cmd = args[i + 1 ..];
    opts.env = try env.toOwnedSlice();
    errdefer allocator.free(opts.env);
    opts.env_files = try env_files.toOwnedSlice();
    errdefer allocator.free(opts.env_files);
    opts.volumes = try volumes.toOwnedSlice();
    errdefer allocator.free(opts.volumes);
    opts.ports = try ports.toOwnedSlice();
    errdefer allocator.free(opts.ports);
    opts.labels = try labels.toOwnedSlice();
    errdefer allocator.free(opts.labels);
    opts.cap_drop = try cap_drop.toOwnedSlice();
    errdefer allocator.free(opts.cap_drop);
    opts.cap_add = try cap_add.toOwnedSlice();
    return opts;
}

/// Parses `exec [OPTIONS] CONTAINER CMD...`. Flags must precede the container
/// name; everything after it is the command, like docker.
fn parseExec(allocator: std.mem.Allocator, args: []const []const u8) ParseError!ExecOpts {
    var opts = ExecOpts{ .container = "" };
    var env = std.ArrayList([]const u8).init(allocator);
    errdefer env.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-e") or eql(a, "--env")) {
            try env.append(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--env=")) {
            try env.append(a["--env=".len..]);
        } else if (eql(a, "-u") or eql(a, "--user")) {
            opts.user = try parseUserSpec(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--user=")) {
            opts.user = try parseUserSpec(a["--user=".len..]);
        } else if (eql(a, "-w") or eql(a, "--workdir")) {
            opts.workdir = try parseWorkdir(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--workdir=")) {
            opts.workdir = try parseWorkdir(a["--workdir=".len..]);
        } else if (eql(a, "-i") or eql(a, "--interactive")) {
            opts.interactive = true;
        } else if (eql(a, "-t") or eql(a, "--tty")) {
            opts.tty = true;
        } else if (eql(a, "-it") or eql(a, "-ti")) {
            opts.interactive = true;
            opts.tty = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else break;
    }
    if (i >= args.len) return error.MissingArgument;
    opts.container = args[i];
    opts.cmd = args[i + 1 ..];
    opts.env = try env.toOwnedSlice();
    errdefer allocator.free(opts.env);
    if (opts.cmd.len == 0) return error.MissingArgument;
    return opts;
}

/// Parses `stats [--no-stream] [-a|--all] [--json] [CONTAINER...]`.
fn parseStats(allocator: std.mem.Allocator, args: []const []const u8) ParseError!StatsOpts {
    var containers = std.ArrayList([]const u8).init(allocator);
    errdefer containers.deinit();

    var opts = StatsOpts{};
    for (args) |a| {
        if (eql(a, "--no-stream")) {
            opts.no_stream = true;
        } else if (eql(a, "-a") or eql(a, "--all")) {
            opts.all = true;
        } else if (eql(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else {
            try containers.append(a);
        }
    }
    opts.containers = try containers.toOwnedSlice();
    return opts;
}


/// Parses `kill [-s|--signal SIGNAL] CONTAINER`.
fn parseKill(args: []const []const u8) ParseError!Command {
    var signal: []const u8 = "SIGTERM";
    var container: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-s") or eql(a, "--signal")) {
            signal = try parseSignal(try takeValue(args, &i));
        } else if (std.mem.startsWith(u8, a, "--signal=")) {
            signal = try parseSignal(a["--signal=".len..]);
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (container == null) {
            container = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .kill = .{
        .container = container orelse return error.MissingArgument,
        .signal = signal,
    } };
}

/// Parses `volume ls|create|rm|inspect [-f|--force] [NAME]`.
fn parseVolume(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingArgument;
    const sub = args[0];
    const rest = args[1..];
    if (eql(sub, "ls") or eql(sub, "list")) {
        if (rest.len > 0) return if (isFlag(rest[0])) error.UnknownFlag else error.TooManyArguments;
        return .{ .volume = .{ .action = .ls } };
    } else if (eql(sub, "create")) {
        return .{ .volume = .{ .action = .create, .name = try single(rest) } };
    } else if (eql(sub, "inspect")) {
        return .{ .volume = .{ .action = .inspect, .name = try single(rest) } };
    } else if (eql(sub, "rm") or eql(sub, "remove")) {
        var force = false;
        var name: ?[]const u8 = null;
        for (rest) |a| {
            if (eql(a, "-f") or eql(a, "--force")) {
                force = true;
            } else if (isFlag(a)) {
                return error.UnknownFlag;
            } else if (name == null) {
                name = a;
            } else {
                return error.TooManyArguments;
            }
        }
        return .{ .volume = .{
            .action = .rm,
            .name = name orelse return error.MissingArgument,
            .force = force,
        } };
    } else if (isFlag(sub)) {
        return error.UnknownFlag;
    } else {
        return error.UnknownCommand;
    }
}

/// Parses `attach [-i|--interactive] [-t|--tty] [-it|-ti] CONTAINER`.
fn parseAttach(args: []const []const u8) ParseError!Command {
    var opts = AttachOpts{ .container = "" };
    var have = false;
    for (args) |a| {
        if (eql(a, "-i") or eql(a, "--interactive")) {
            opts.interactive = true;
        } else if (eql(a, "-t") or eql(a, "--tty")) {
            opts.tty = true;
        } else if (eql(a, "-it") or eql(a, "-ti")) {
            opts.interactive = true;
            opts.tty = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (!have) {
            opts.container = a;
            have = true;
        } else {
            return error.TooManyArguments;
        }
    }
    if (!have) return error.MissingArgument;
    return .{ .attach = opts };
}

/// Parses `cp CONTAINER:PATH HOST_PATH` or `cp HOST_PATH CONTAINER:PATH`.
fn parseCp(args: []const []const u8) ParseError!Command {
    var src: ?[]const u8 = null;
    var dst: ?[]const u8 = null;
    for (args) |a| {
        if (isFlag(a)) return error.UnknownFlag;
        if (src == null) {
            src = a;
        } else if (dst == null) {
            dst = a;
        } else {
            return error.TooManyArguments;
        }
    }
    const s = src orelse return error.MissingArgument;
    const d = dst orelse return error.MissingArgument;
    return .{ .cp = try parseCpEndpoints(s, d) };
}

/// Parses `network ls|inspect|create|rm ...`.
fn parseNetwork(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingArgument;
    const sub = args[0];
    const rest = args[1..];
    if (eql(sub, "ls") or eql(sub, "list")) {
        if (rest.len > 0) return if (isFlag(rest[0])) error.UnknownFlag else error.TooManyArguments;
        return .{ .network = .{ .action = .ls } };
    } else if (eql(sub, "inspect")) {
        return .{ .network = .{ .action = .inspect, .name = try single(rest) } };
    } else if (eql(sub, "create")) {
        var opts = NetworkOpts{ .action = .create };
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const a = rest[i];
            if (eql(a, "-d") or eql(a, "--driver")) {
                opts.driver = try parseNetworkDriver(try takeValue(rest, &i));
            } else if (std.mem.startsWith(u8, a, "--driver=")) {
                opts.driver = try parseNetworkDriver(a["--driver=".len..]);
            } else if (eql(a, "--internal")) {
                opts.internal = true;
            } else if (isFlag(a)) {
                return error.UnknownFlag;
            } else if (opts.name == null) {
                opts.name = a;
            } else {
                return error.TooManyArguments;
            }
        }
        if (opts.name == null) return error.MissingArgument;
        return .{ .network = opts };
    } else if (eql(sub, "rm") or eql(sub, "remove")) {
        var force = false;
        var name: ?[]const u8 = null;
        for (rest) |a| {
            if (eql(a, "-f") or eql(a, "--force")) {
                force = true;
            } else if (isFlag(a)) {
                return error.UnknownFlag;
            } else if (name == null) {
                name = a;
            } else {
                return error.TooManyArguments;
            }
        }
        return .{ .network = .{
            .action = .rm,
            .name = name orelse return error.MissingArgument,
            .force = force,
        } };
    } else if (isFlag(sub)) {
        return error.UnknownFlag;
    } else {
        return error.UnknownCommand;
    }
}

/// Parses `restart [-t|--time SECONDS] CONTAINER`.
fn parseRestart(args: []const []const u8) ParseError!Command {
    var timeout_secs: ?u32 = null;
    var container: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-t") or eql(a, "--time")) {
            const raw = try takeValue(args, &i);
            const secs = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidValue;
            if (secs > 3600) return error.InvalidValue;
            timeout_secs = secs;
        } else if (std.mem.startsWith(u8, a, "--time=")) {
            const raw = a["--time=".len..];
            const secs = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidValue;
            if (secs > 3600) return error.InvalidValue;
            timeout_secs = secs;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (container == null) {
            container = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .restart = .{
        .container = container orelse return error.MissingArgument,
        .timeout_secs = timeout_secs,
    } };
}

/// Parses `rename CONTAINER NEW_NAME`.
fn parseRename(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingArgument;
    if (isFlag(args[0])) return error.UnknownFlag;
    if (args.len < 2) return error.MissingArgument;
    if (isFlag(args[1])) return error.UnknownFlag;
    if (args.len > 2) return error.TooManyArguments;
    return .{ .rename = .{
        .container = args[0],
        .new_name = args[1],
    } };
}

/// Parses `rmi [-f|--force] IMAGE`.
fn parseRmi(args: []const []const u8) ParseError!Command {
    var force = false;
    var image: ?[]const u8 = null;
    for (args) |a| {
        if (eql(a, "-f") or eql(a, "--force")) {
            force = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (image == null) {
            image = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .rmi = .{
        .image = image orelse return error.MissingArgument,
        .force = force,
    } };
}

/// Parses `system ping|df|prune [-f|--force]`.
fn parseSystem(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingArgument;
    const sub = args[0];
    const rest = args[1..];
    if (eql(sub, "ping")) {
        if (rest.len > 0) return if (isFlag(rest[0])) error.UnknownFlag else error.TooManyArguments;
        return .{ .system = .{ .action = .ping } };
    } else if (eql(sub, "df")) {
        if (rest.len > 0) return if (isFlag(rest[0])) error.UnknownFlag else error.TooManyArguments;
        return .{ .system = .{ .action = .df } };
    } else if (eql(sub, "prune")) {
        var force = false;
        for (rest) |a| {
            if (eql(a, "-f") or eql(a, "--force")) {
                force = true;
            } else if (isFlag(a)) {
                return error.UnknownFlag;
            } else {
                return error.TooManyArguments;
            }
        }
        return .{ .system = .{ .action = .prune, .force = force } };
    } else if (isFlag(sub)) {
        return error.UnknownFlag;
    } else {
        return error.UnknownCommand;
    }
}

/// Parses `port CONTAINER [PRIVATE_PORT[/PROTO]]`.
fn parsePortCmd(args: []const []const u8) ParseError!Command {
    var container: ?[]const u8 = null;
    var private_port: ?[]const u8 = null;
    for (args) |a| {
        if (isFlag(a)) return error.UnknownFlag;
        if (container == null) {
            container = a;
        } else if (private_port == null) {
            private_port = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .port = .{
        .container = container orelse return error.MissingArgument,
        .private_port = private_port,
    } };
}

/// Parses `events [--since TS] [--until TS] [--json]`.
fn parseEvents(args: []const []const u8) ParseError!Command {
    var opts = EventsOpts{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "--since")) {
            opts.since = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--since=")) {
            opts.since = a["--since=".len..];
        } else if (eql(a, "--until")) {
            opts.until = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--until=")) {
            opts.until = a["--until=".len..];
        } else if (eql(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .events = opts };
}

/// Parses `completion <bash|zsh|fish>`.
fn parseCompletion(args: []const []const u8) ParseError!Command {
    const raw = try single(args);
    const shell: Shell = if (eql(raw, "bash"))
        .bash
    else if (eql(raw, "zsh"))
        .zsh
    else if (eql(raw, "fish"))
        .fish
    else
        return error.InvalidValue;
    return .{ .completion = shell };
}

/// Parses `tag SRC_IMAGE TARGET_IMAGE`.
fn parseTag(args: []const []const u8) ParseError!Command {
    var src: ?[]const u8 = null;
    var dst: ?[]const u8 = null;
    for (args) |a| {
        if (isFlag(a)) return error.UnknownFlag;
        if (src == null) {
            src = a;
        } else if (dst == null) {
            dst = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .tag = .{
        .src_image = src orelse return error.MissingArgument,
        .target_image = dst orelse return error.MissingArgument,
    } };
}

/// Parses `history [--json] IMAGE`.
fn parseHistory(args: []const []const u8) ParseError!Command {
    var opts = HistoryOpts{ .image = "" };
    var have = false;
    for (args) |a| {
        if (eql(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (!have) {
            opts.image = a;
            have = true;
        } else {
            return error.TooManyArguments;
        }
    }
    if (!have) return error.MissingArgument;
    return .{ .history = opts };
}

/// Parses `commit [-m|--message MSG] [-a|--author AUTHOR] CONTAINER REPO[:TAG]`.
fn parseCommit(args: []const []const u8) ParseError!Command {
    var opts = CommitOpts{ .container = "", .target_image = "" };
    var have_c = false;
    var have_t = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-m") or eql(a, "--message")) {
            opts.message = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--message=")) {
            opts.message = a["--message=".len..];
        } else if (eql(a, "-a") or eql(a, "--author")) {
            opts.author = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--author=")) {
            opts.author = a["--author=".len..];
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (!have_c) {
            opts.container = a;
            have_c = true;
        } else if (!have_t) {
            opts.target_image = a;
            have_t = true;
        } else {
            return error.TooManyArguments;
        }
    }
    if (!have_c or !have_t) return error.MissingArgument;
    return .{ .commit = opts };
}

fn parseSave(args: []const []const u8) ParseError!Command {
    var image: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-o") or eql(a, "--output")) {
            output = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output = try flagValue(a, "--output=");
        } else if (std.mem.startsWith(u8, a, "-o=")) {
            output = try flagValue(a, "-o=");
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (image == null) {
            image = a;
        } else {
            return error.TooManyArguments;
        }
    }
    if (image == null) return error.MissingArgument;
    if (output == null) return error.MissingValue;
    return .{ .save = .{ .image = image.?, .output = output.? } };
}

fn parseLoad(args: []const []const u8) ParseError!Command {
    var input: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-i") or eql(a, "--input")) {
            input = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--input=")) {
            input = try flagValue(a, "--input=");
        } else if (std.mem.startsWith(u8, a, "-i=")) {
            input = try flagValue(a, "-i=");
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else {
            return error.TooManyArguments;
        }
    }
    if (input == null) return error.MissingValue;
    return .{ .load = .{ .input = input.? } };
}

fn parseExport(args: []const []const u8) ParseError!Command {
    var container: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-o") or eql(a, "--output")) {
            output = try takeValue(args, &i);
        } else if (std.mem.startsWith(u8, a, "--output=")) {
            output = try flagValue(a, "--output=");
        } else if (std.mem.startsWith(u8, a, "-o=")) {
            output = try flagValue(a, "-o=");
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (container == null) {
            container = a;
        } else {
            return error.TooManyArguments;
        }
    }
    if (container == null) return error.MissingArgument;
    if (output == null) return error.MissingValue;
    return .{ .@"export" = .{ .container = container.?, .output = output.? } };
}

fn parseImport(args: []const []const u8) ParseError!Command {
    var input: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (input == null) {
            input = a;
        } else if (ref == null) {
            ref = a;
        } else {
            return error.TooManyArguments;
        }
    }
    if (input == null or ref == null) return error.MissingArgument;
    return .{ .import = .{ .input = input.?, .ref = ref.? } };
}

/// Returns the flag value embedded after `prefix` (e.g. `-o=/x.tar`).
fn flagValue(a: []const u8, comptime prefix: []const u8) ParseError![]const u8 {
    const v = a[prefix.len..];
    if (v.len == 0) return error.MissingValue;
    return v;
}

/// Parses `policy show|check [--json] [FILE]`.
fn parsePolicyCmd(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.MissingArgument;
    const sub = args[0];
    const action: PolicyAction = if (eql(sub, "show"))
        .show
    else if (eql(sub, "check"))
        .check
    else if (isFlag(sub))
        return error.UnknownFlag
    else
        return error.UnknownCommand;

    var opts = PolicyOpts{ .action = action };
    for (args[1..]) |a| {
        if (eql(a, "--json")) {
            opts.json = true;
        } else if (isFlag(a)) {
            return error.UnknownFlag;
        } else if (opts.path == null) {
            opts.path = a;
        } else {
            return error.TooManyArguments;
        }
    }
    return .{ .policy = opts };
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
    try std.testing.expectEqualStrings("web", (try testParse(&.{ "logs", "web" })).command.logs.container);
    try std.testing.expect(!(try testParse(&.{ "logs", "web" })).command.logs.follow);
    try std.testing.expect((try testParse(&.{ "logs", "-f", "web" })).command.logs.follow);
    try std.testing.expectEqualStrings("alpine:3.20", (try testParse(&.{ "inspect", "alpine:3.20" })).command.inspect.target);
    try std.testing.expect((try testParse(&.{ "inspect", "--json", "alpine:3.20" })).command.inspect.json);
    try std.testing.expect((try testParse(&.{ "ps", "-a", "--json" })).command.ps.json);
    try std.testing.expect((try testParse(&.{ "images", "--json" })).command.images.json);
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

test "search, save, load, export, and import parsers" {
    const s = (try testParse(&.{ "search", "alpine" })).command.search;
    try std.testing.expectEqualStrings("alpine", s.term);
    try std.testing.expectError(error.MissingArgument, testParse(&.{"search"}));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "search", "a", "b" }));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "search", "--bad" }));

    const sv = (try testParse(&.{ "save", "-o", "/tmp/img.tar", "alpine:3.20" })).command.save;
    try std.testing.expectEqualStrings("alpine:3.20", sv.image);
    try std.testing.expectEqualStrings("/tmp/img.tar", sv.output);
    const sv2 = (try testParse(&.{ "save", "--output=/x.tar", "alpine" })).command.save;
    try std.testing.expectEqualStrings("/x.tar", sv2.output);
    const sv3 = (try testParse(&.{ "save", "-o=/y.tar", "alpine", })).command.save;
    try std.testing.expectEqualStrings("/y.tar", sv3.output);
    try std.testing.expectError(error.MissingValue, testParse(&.{ "save", "alpine" }));
    try std.testing.expectError(error.MissingArgument, testParse(&.{ "save", "-o", "/x.tar" }));
    try std.testing.expectError(error.MissingValue, testParse(&.{ "save", "-o" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "save", "a", "b" }));

    const ld = (try testParse(&.{ "load", "-i", "/tmp/in.tar" })).command.load;
    try std.testing.expectEqualStrings("/tmp/in.tar", ld.input);
    const ld2 = (try testParse(&.{ "load", "--input=/a.tar" })).command.load;
    try std.testing.expectEqualStrings("/a.tar", ld2.input);
    try std.testing.expectError(error.MissingValue, testParse(&.{"load"}));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "load", "-i", "/a.tar", "/b.tar" }));

    const ex = (try testParse(&.{ "export", "-o", "/tmp/fs.tar", "web" })).command.@"export";
    try std.testing.expectEqualStrings("web", ex.container);
    try std.testing.expectEqualStrings("/tmp/fs.tar", ex.output);
    try std.testing.expectError(error.MissingArgument, testParse(&.{"export"}));
    try std.testing.expectError(error.MissingArgument, testParse(&.{ "export", "-o", "/x.tar" }));

    const im = (try testParse(&.{ "import", "/tmp/rootfs.tar", "myrepo/app:v2" })).command.import;
    try std.testing.expectEqualStrings("/tmp/rootfs.tar", im.input);
    try std.testing.expectEqualStrings("myrepo/app:v2", im.ref);
    try std.testing.expectError(error.MissingArgument, testParse(&.{"import"}));
    try std.testing.expectError(error.MissingArgument, testParse(&.{ "import", "/a.tar" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "import", "/a.tar", "repo", "extra" }));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "import", "--bad", "/a.tar" }));
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
    try std.testing.expectError(error.MissingArgument, testParse(&.{"inspect"}));
    try std.testing.expectError(error.UnknownFlag, testParse(&.{ "inspect", "--bad" }));
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "inspect", "a", "b" }));
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

test "parse run publish port mappings" {
    const alloc = std.testing.allocator;
    var parsed = try parse(alloc, &.{
        "run",
        "-p",
        "8080:80",
        "--publish",
        "53:53/udp",
        "--publish=127.0.0.1:9000:9000",
        "--publish",
        "3000",
        "alpine:3.20",
    });
    defer parsed.deinit(alloc);

    const r = parsed.command.run;
    try std.testing.expectEqual(@as(usize, 4), r.ports.len);

    try std.testing.expect(r.ports[0].host_ip == null);
    try std.testing.expectEqual(@as(?u16, 8080), r.ports[0].host_port);
    try std.testing.expectEqual(@as(u16, 80), r.ports[0].container_port);
    try std.testing.expectEqualStrings("tcp", r.ports[0].proto);

    try std.testing.expectEqual(@as(?u16, 53), r.ports[1].host_port);
    try std.testing.expectEqual(@as(u16, 53), r.ports[1].container_port);
    try std.testing.expectEqualStrings("udp", r.ports[1].proto);

    try std.testing.expectEqualStrings("127.0.0.1", r.ports[2].host_ip.?);
    try std.testing.expectEqual(@as(?u16, 9000), r.ports[2].host_port);
    try std.testing.expectEqual(@as(u16, 9000), r.ports[2].container_port);

    try std.testing.expect(r.ports[3].host_port == null);
    try std.testing.expectEqual(@as(u16, 3000), r.ports[3].container_port);
    try std.testing.expectEqualStrings("alpine:3.20", r.image);
}

test "parse rejects malformed publish specs without leaking allocations" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "0:80", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "8080:0", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "70000:80", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "abc:80", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "1.2.3.4.5:80:80", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "1:2:3:4", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "8080:80/bogus", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", "8080:80/", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-p", ":80", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--publish=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "-p" }));
    // A parsed port mapping must be freed when a later error aborts the parse.
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "run", "-p", "8080:80" }));
}

test "parse exec command with env, user, and workdir" {
    const alloc = std.testing.allocator;
    var parsed = try parse(alloc, &.{
        "exec",
        "-e",
        "A=1",
        "--env=B=2",
        "-u",
        "1000:1000",
        "--workdir=/work",
        "web",
        "sh",
        "-c",
        "echo hi",
    });
    defer parsed.deinit(alloc);

    const e = parsed.command.exec;
    try std.testing.expectEqualStrings("web", e.container);
    try std.testing.expectEqual(@as(usize, 3), e.cmd.len);
    try std.testing.expectEqualStrings("echo hi", e.cmd[2]);
    try std.testing.expectEqual(@as(usize, 2), e.env.len);
    try std.testing.expectEqualStrings("A=1", e.env[0]);
    try std.testing.expectEqualStrings("B=2", e.env[1]);
    try std.testing.expectEqualStrings("1000:1000", e.user.?);
    try std.testing.expectEqualStrings("/work", e.workdir.?);
}

test "parse exec rejects malformed specs without leaking allocations" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "exec" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "exec", "web" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "exec", "-e", "A=1" }));
    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "exec", "--bogus", "web", "ls" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "exec", "-u", "bad user", "web", "ls" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "exec", "-w", "relative", "web", "ls" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "exec", "-e" }));
    // A parsed env slice must be freed when a later error aborts the parse.
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "exec", "-e", "A=1", "web" }));
}

test "parse run network, workdir, user, and capability flags" {
    const alloc = std.testing.allocator;
    var parsed = try parse(alloc, &.{
        "run",
        "--network",
        "none",
        "--workdir=/work",
        "-u",
        "1000:1000",
        "--cap-drop",
        "ALL",
        "--cap-drop=CHOWN",
        "--cap-add",
        "NET_BIND_SERVICE",
        "alpine:3.20",
    });
    defer parsed.deinit(alloc);

    const r = parsed.command.run;
    try std.testing.expectEqualStrings("none", r.network.?);
    try std.testing.expectEqualStrings("/work", r.workdir.?);
    try std.testing.expectEqualStrings("1000:1000", r.user.?);
    try std.testing.expectEqual(@as(usize, 2), r.cap_drop.len);
    try std.testing.expectEqualStrings("ALL", r.cap_drop[0]);
    try std.testing.expectEqualStrings("CHOWN", r.cap_drop[1]);
    try std.testing.expectEqual(@as(usize, 1), r.cap_add.len);
    try std.testing.expectEqualStrings("NET_BIND_SERVICE", r.cap_add[0]);
    try std.testing.expectEqualStrings("alpine:3.20", r.image);

    var p_defaults = try parse(alloc, &.{ "run", "-w", "/srv", "alpine:3.20" });
    defer p_defaults.deinit(alloc);
    try std.testing.expect(p_defaults.command.run.network == null);
    try std.testing.expect(p_defaults.command.run.user == null);
    try std.testing.expectEqual(@as(usize, 0), p_defaults.command.run.cap_drop.len);
}

test "parse rejects malformed network/workdir/user/capability values without leaking" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--network", "bogus", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--network=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "--network" }));

    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-w", "relative/path", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--workdir=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "-w" }));

    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-u", ":", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-u", "a:b:c", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-u", "bad user", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "-u", "-root", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--user=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "-u" }));

    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--cap-drop", "net_admin", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--cap-add", "1BAD", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--cap-drop=", "alpine" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "run", "--cap-add" }));
    // Parsed capability slices must be freed when a later error aborts the parse.
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "run", "--cap-drop", "ALL" }));
}

test "parse demo and audit subcommands" {
    const alloc = std.testing.allocator;
    var p_demo = try parse(alloc, &.{"demo"});
    defer p_demo.deinit(alloc);
    try std.testing.expect(p_demo.command == .demo);
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "demo", "extra" }));

    var p_demo_json = try parse(alloc, &.{ "demo", "--json" });
    defer p_demo_json.deinit(alloc);
    switch (p_demo_json.command) {
        .demo => |d| try std.testing.expect(d.json),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "demo", "--verbose" }));

    var p_audit_default = try parse(alloc, &.{"audit"});
    defer p_audit_default.deinit(alloc);
    switch (p_audit_default.command) {
        .audit => |a| {
            try std.testing.expect(a.path == null);
            try std.testing.expect(!a.json);
        },
        else => return error.TestUnexpectedResult,
    }

    var p_audit_file = try parse(alloc, &.{ "audit", "--json", "/tmp/custom-audit.log" });
    defer p_audit_file.deinit(alloc);
    switch (p_audit_file.command) {
        .audit => |a| {
            try std.testing.expectEqualStrings("/tmp/custom-audit.log", a.path.?);
            try std.testing.expect(a.json);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "audit", "a.log", "b.log" }));
    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "audit", "--bogus" }));
}

test "parse run --profile=sandbox and --policy flags" {
    const alloc = std.testing.allocator;
    var p = try parse(alloc, &.{ "run", "--profile=sandbox", "--policy", "zigpod-policy.json", "alpine:3.20" });
    defer p.deinit(alloc);
    try std.testing.expectEqual(Profile.sandbox, p.command.run.profile);
    try std.testing.expectEqualStrings("zigpod-policy.json", p.command.run.policy_path.?);

    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--profile=bogus", "alpine:3.20" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--policy=", "alpine:3.20" }));
}

test "parse stats subcommand with --no-stream, -a, and containers" {
    const alloc = std.testing.allocator;

    var p1 = try parse(alloc, &.{ "stats", "--no-stream" });
    defer p1.deinit(alloc);
    try std.testing.expect(p1.command.stats.no_stream);
    try std.testing.expect(!p1.command.stats.all);
    try std.testing.expectEqual(@as(usize, 0), p1.command.stats.containers.len);

    var p2 = try parse(alloc, &.{ "stats", "--no-stream", "-a", "web", "db" });
    defer p2.deinit(alloc);
    try std.testing.expect(p2.command.stats.no_stream);
    try std.testing.expect(p2.command.stats.all);
    try std.testing.expectEqual(@as(usize, 2), p2.command.stats.containers.len);
    try std.testing.expectEqualStrings("web", p2.command.stats.containers[0]);
    try std.testing.expectEqualStrings("db", p2.command.stats.containers[1]);

    var p3 = try parse(alloc, &.{ "stats", "web", "--no-stream" });
    defer p3.deinit(alloc);
    try std.testing.expect(p3.command.stats.no_stream);
    try std.testing.expectEqual(@as(usize, 1), p3.command.stats.containers.len);
    try std.testing.expectEqualStrings("web", p3.command.stats.containers[0]);

    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "stats", "web", "--bogus" }));
}

test "parse run -it and exec -it interactive/tty flags" {
    const alloc = std.testing.allocator;

    var p_run = try parse(alloc, &.{ "run", "-it", "alpine:3.20", "sh" });
    defer p_run.deinit(alloc);
    try std.testing.expect(p_run.command.run.interactive);
    try std.testing.expect(p_run.command.run.tty);

    var p_exec = try parse(alloc, &.{ "exec", "-i", "-t", "web", "sh" });
    defer p_exec.deinit(alloc);
    try std.testing.expect(p_exec.command.exec.interactive);
    try std.testing.expect(p_exec.command.exec.tty);

    var p_logs = try parse(alloc, &.{ "logs", "--follow", "web" });
    defer p_logs.deinit(alloc);
    try std.testing.expect(p_logs.command.logs.follow);
    try std.testing.expectEqualStrings("web", p_logs.command.logs.container);
}

test "fuzz parseMemoryBytes and cli.parse with deterministic PRNG" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc11f022);
    const rng = prng.random();

    // Part A: Property test for parseMemoryBytes on valid suffix multipliers + random strings.
    const suffixes = [_]struct { s: []const u8, mul: i64 }{
        .{ .s = "", .mul = 1 },
        .{ .s = "b", .mul = 1 },
        .{ .s = "B", .mul = 1 },
        .{ .s = "k", .mul = 1024 },
        .{ .s = "kb", .mul = 1024 },
        .{ .s = "m", .mul = 1024 * 1024 },
        .{ .s = "MB", .mul = 1024 * 1024 },
        .{ .s = "g", .mul = 1024 * 1024 * 1024 },
        .{ .s = "GB", .mul = 1024 * 1024 * 1024 },
    };
    for (suffixes) |suf| {
        const n: i64 = rng.intRangeAtMost(i64, 1, 2048);
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}{s}", .{ n, suf.s });
        try std.testing.expectEqual(n * suf.mul, try parseMemoryBytes(text));
    }

    var mem_i: usize = 0;
    while (mem_i < 200) : (mem_i += 1) {
        var buf: [24]u8 = undefined;
        const len = rng.intRangeAtMost(usize, 0, buf.len);
        rng.bytes(buf[0..len]);
        if (parseMemoryBytes(buf[0..len])) |val| {
            try std.testing.expect(val > 0);
        } else |_| {}
    }

    // Part B: Fuzz cli.parse across random argument sequences to verify leak-free error cleanup.
    const pool = [_][]const u8{
        "run",
        "exec",
        "stats",
        "logs",
        "audit",
        "ps",
        "rm",
        "-d",
        "--rm",
        "-it",
        "-f",
        "--no-stream",
        "-a",
        "--json",
        "--profile=sandbox",
        "--profile=bad",
        "--policy",
        "zigpod-policy.json",
        "-e",
        "K=V",
        "-v",
        "/tmp/a:/app:ro",
        "-p",
        "8080:80",
        "-m",
        "128m",
        "-m",
        "0",
        "--pids-limit",
        "32",
        "--cap-drop",
        "ALL",
        "--cap-add",
        "bad_cap",
        "--network",
        "none",
        "--user",
        "1000:1000",
        "--workdir",
        "/work",
        "kill",
        "-s",
        "SIGKILL",
        "top",
        "volume",
        "network",
        "ls",
        "create",
        "--bogus",
        "",
        "alpine:3.20",
        "sh",
    };

    var parse_i: usize = 0;
    while (parse_i < 160) : (parse_i += 1) {
        const argc = rng.intRangeAtMost(usize, 0, 10);
        var args = try alloc.alloc([]const u8, argc);
        defer alloc.free(args);
        for (0..argc) |idx| {
            args[idx] = pool[rng.intRangeLessThan(usize, 0, pool.len)];
        }
        if (parse(alloc, args)) |parsed| {
            var p = parsed;
            p.deinit(alloc);
        } else |_| {}
    }
}

test "parse kill, top, volume, and network subcommands" {
    const alloc = std.testing.allocator;

    const k1 = try parse(alloc, &.{ "kill", "web" });
    defer k1.deinit(alloc);
    try std.testing.expectEqualStrings("web", k1.command.kill.container);
    try std.testing.expectEqualStrings("SIGTERM", k1.command.kill.signal);

    const k2 = try parse(alloc, &.{ "kill", "-s", "SIGKILL", "web" });
    defer k2.deinit(alloc);
    try std.testing.expectEqualStrings("SIGKILL", k2.command.kill.signal);

    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "kill", "-s", "SIGBAD", "web" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "kill", "-s", "SIGTERM" }));

    const t1 = try parse(alloc, &.{ "top", "web" });
    defer t1.deinit(alloc);
    try std.testing.expectEqualStrings("web", t1.command.top);

    const v_ls = try parse(alloc, &.{ "volume", "ls" });
    defer v_ls.deinit(alloc);
    try std.testing.expectEqual(VolumeAction.ls, v_ls.command.volume.action);

    const v_create = try parse(alloc, &.{ "volume", "create", "app-data" });
    defer v_create.deinit(alloc);
    try std.testing.expectEqual(VolumeAction.create, v_create.command.volume.action);
    try std.testing.expectEqualStrings("app-data", v_create.command.volume.name.?);

    const v_rm = try parse(alloc, &.{ "volume", "rm", "-f", "app-data" });
    defer v_rm.deinit(alloc);
    try std.testing.expectEqual(VolumeAction.rm, v_rm.command.volume.action);
    try std.testing.expect(v_rm.command.volume.force);

    const n_ls = try parse(alloc, &.{ "network", "ls" });
    defer n_ls.deinit(alloc);
    try std.testing.expectEqual(NetworkAction.ls, n_ls.command.network.action);

    const n_insp = try parse(alloc, &.{ "network", "inspect", "podman" });
    defer n_insp.deinit(alloc);
    try std.testing.expectEqual(NetworkAction.inspect, n_insp.command.network.action);
    try std.testing.expectEqualStrings("podman", n_insp.command.network.name.?);
}

test "parse start, restart, pause, unpause, rename, and rmi subcommands" {
    const alloc = std.testing.allocator;

    const p_start = try parse(alloc, &.{ "start", "web" });
    defer p_start.deinit(alloc);
    try std.testing.expectEqualStrings("web", p_start.command.start);

    const p_restart = try parse(alloc, &.{ "restart", "-t", "5", "web" });
    defer p_restart.deinit(alloc);
    try std.testing.expectEqualStrings("web", p_restart.command.restart.container);
    try std.testing.expectEqual(@as(?u32, 5), p_restart.command.restart.timeout_secs);

    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "restart", "-t", "99999", "web" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "restart", "--time=abc", "web" }));

    const p_pause = try parse(alloc, &.{ "pause", "web" });
    defer p_pause.deinit(alloc);
    try std.testing.expectEqualStrings("web", p_pause.command.pause);

    const p_unpause = try parse(alloc, &.{ "unpause", "web" });
    defer p_unpause.deinit(alloc);
    try std.testing.expectEqualStrings("web", p_unpause.command.unpause);

    const p_rename = try parse(alloc, &.{ "rename", "web", "web2" });
    defer p_rename.deinit(alloc);
    try std.testing.expectEqualStrings("web", p_rename.command.rename.container);
    try std.testing.expectEqualStrings("web2", p_rename.command.rename.new_name);
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "rename", "web" }));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "rename", "a", "b", "c" }));

    const p_rmi = try parse(alloc, &.{ "rmi", "-f", "alpine:3.20" });
    defer p_rmi.deinit(alloc);
    try std.testing.expectEqualStrings("alpine:3.20", p_rmi.command.rmi.image);
    try std.testing.expect(p_rmi.command.rmi.force);

    const p_sys_ping = try parse(alloc, &.{ "system", "ping" });
    defer p_sys_ping.deinit(alloc);
    try std.testing.expectEqual(SystemAction.ping, p_sys_ping.command.system.action);

    const p_sys_df = try parse(alloc, &.{ "system", "df" });
    defer p_sys_df.deinit(alloc);
    try std.testing.expectEqual(SystemAction.df, p_sys_df.command.system.action);

    const p_sys_prune = try parse(alloc, &.{ "system", "prune", "-f" });
    defer p_sys_prune.deinit(alloc);
    try std.testing.expectEqual(SystemAction.prune, p_sys_prune.command.system.action);
    try std.testing.expect(p_sys_prune.command.system.force);
}

test {
    _ = types;
    _ = specs;
}

test "parse port, wait, diff, and events observation subcommands" {
    const alloc = std.testing.allocator;
    const p1 = try parse(alloc, &.{ "port", "web", "80/tcp" });
    defer p1.deinit(alloc);
    try std.testing.expectEqualStrings("web", p1.command.port.container);
    try std.testing.expectEqualStrings("80/tcp", p1.command.port.private_port.?);

    const p2 = try parse(alloc, &.{ "wait", "web" });
    defer p2.deinit(alloc);
    try std.testing.expectEqualStrings("web", p2.command.wait);

    const p3 = try parse(alloc, &.{ "diff", "web" });
    defer p3.deinit(alloc);
    try std.testing.expectEqualStrings("web", p3.command.diff);

    const p4 = try parse(alloc, &.{ "events", "--since", "100", "--until=200", "--json" });
    defer p4.deinit(alloc);
    try std.testing.expectEqualStrings("100", p4.command.events.since.?);
    try std.testing.expectEqualStrings("200", p4.command.events.until.?);
    try std.testing.expect(p4.command.events.json);

    // Error & boundary paths
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{"port"}));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "port", "web", "80", "extra" }));
    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "port", "--bogus", "web" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{"wait"}));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "wait", "web", "extra" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{"diff"}));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "diff", "web", "extra" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "events", "--since" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "events", "--until" }));
    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "events", "--bogus" }));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "events", "extra" }));
}

test "parse completion subcommand for bash, zsh, fish, and error paths" {
    const alloc = std.testing.allocator;
    const p1 = try parse(alloc, &.{ "completion", "bash" });
    defer p1.deinit(alloc);
    try std.testing.expectEqual(Shell.bash, p1.command.completion);

    const p2 = try parse(alloc, &.{ "completion", "zsh" });
    defer p2.deinit(alloc);
    try std.testing.expectEqual(Shell.zsh, p2.command.completion);

    const p3 = try parse(alloc, &.{ "completion", "fish" });
    defer p3.deinit(alloc);
    try std.testing.expectEqual(Shell.fish, p3.command.completion);

    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{"completion"}));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "completion", "powershell" }));
    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "completion", "--bogus" }));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "completion", "bash", "extra" }));
}

test "parse tag, history, commit, and policy subcommands + error paths" {
    const alloc = std.testing.allocator;

    const p_tag = try parse(alloc, &.{ "tag", "alpine:3.20", "myrepo/app:v1" });
    defer p_tag.deinit(alloc);
    try std.testing.expectEqualStrings("alpine:3.20", p_tag.command.tag.src_image);
    try std.testing.expectEqualStrings("myrepo/app:v1", p_tag.command.tag.target_image);

    const p_hist = try parse(alloc, &.{ "history", "--json", "alpine:3.20" });
    defer p_hist.deinit(alloc);
    try std.testing.expect(p_hist.command.history.json);
    try std.testing.expectEqualStrings("alpine:3.20", p_hist.command.history.image);

    const p_commit = try parse(alloc, &.{ "commit", "-m", "checkpoint", "-a", "alice", "web", "snap:v1" });
    defer p_commit.deinit(alloc);
    try std.testing.expectEqualStrings("checkpoint", p_commit.command.commit.message.?);
    try std.testing.expectEqualStrings("alice", p_commit.command.commit.author.?);
    try std.testing.expectEqualStrings("web", p_commit.command.commit.container);
    try std.testing.expectEqualStrings("snap:v1", p_commit.command.commit.target_image);

    const p_pol = try parse(alloc, &.{ "policy", "check", "--json", "zigpod-policy.json" });
    defer p_pol.deinit(alloc);
    try std.testing.expectEqual(PolicyAction.check, p_pol.command.policy.action);
    try std.testing.expect(p_pol.command.policy.json);
    try std.testing.expectEqualStrings("zigpod-policy.json", p_pol.command.policy.path.?);

    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "tag", "alpine:3.20" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{"history"}));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "commit", "-m" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "commit", "web" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{"policy"}));
    try std.testing.expectError(error.UnknownCommand, parse(alloc, &.{ "policy", "bogus" }));

    const p_build = try parse(alloc, &.{ "--socket=/tmp/custom.sock", "build", "--tag=myimg:1.0", "." });
    defer p_build.deinit(alloc);
    try std.testing.expectEqualStrings("/tmp/custom.sock", p_build.global.socket.?);
    try std.testing.expectEqualStrings("myimg:1.0", p_build.command.build.tag);
    try std.testing.expectEqualStrings(".", p_build.command.build.ctx);

    const p_build_short = try parse(alloc, &.{ "build", "-t=myimg:2.0", "./app" });
    defer p_build_short.deinit(alloc);
    try std.testing.expectEqualStrings("myimg:2.0", p_build_short.command.build.tag);
    try std.testing.expectEqualStrings("./app", p_build_short.command.build.ctx);

    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "--socket=", "ps" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "build", "--tag=", "." }));
}

test "parse attach, cp, and network create/rm commands + error paths" {
    const alloc = std.testing.allocator;

    const p_att = try parse(alloc, &.{ "attach", "-it", "web" });
    defer p_att.deinit(alloc);
    try std.testing.expectEqualStrings("web", p_att.command.attach.container);
    try std.testing.expect(p_att.command.attach.interactive);
    try std.testing.expect(p_att.command.attach.tty);
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{"attach"}));
    try std.testing.expectError(error.UnknownFlag, parse(alloc, &.{ "attach", "--bogus", "web" }));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "attach", "a", "b" }));

    const p_cp_to = try parse(alloc, &.{ "cp", "/tmp/hello.txt", "web:/tmp" });
    defer p_cp_to.deinit(alloc);
    try std.testing.expectEqual(CpDirection.to_container, p_cp_to.command.cp.direction);
    try std.testing.expectEqualStrings("web", p_cp_to.command.cp.container);
    try std.testing.expectEqualStrings("/tmp", p_cp_to.command.cp.container_path);
    try std.testing.expectEqualStrings("/tmp/hello.txt", p_cp_to.command.cp.host_path);

    const p_cp_from = try parse(alloc, &.{ "cp", "web:/etc/hosts", "/tmp/hosts" });
    defer p_cp_from.deinit(alloc);
    try std.testing.expectEqual(CpDirection.from_container, p_cp_from.command.cp.direction);
    try std.testing.expectEqualStrings("/etc/hosts", p_cp_from.command.cp.container_path);
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "cp", "web:/a" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "cp", "a:/x", "b:/y" }));
    try std.testing.expectError(error.TooManyArguments, parse(alloc, &.{ "cp", "/tmp/a", "web:/b", "extra" }));

    const p_net_create = try parse(alloc, &.{ "network", "create", "--driver=macvlan", "--internal", "isolated-net" });
    defer p_net_create.deinit(alloc);
    try std.testing.expectEqual(NetworkAction.create, p_net_create.command.network.action);
    try std.testing.expectEqualStrings("macvlan", p_net_create.command.network.driver);
    try std.testing.expect(p_net_create.command.network.internal);
    try std.testing.expectEqualStrings("isolated-net", p_net_create.command.network.name.?);

    const p_net_rm = try parse(alloc, &.{ "network", "rm", "-f", "isolated-net" });
    defer p_net_rm.deinit(alloc);
    try std.testing.expectEqual(NetworkAction.rm, p_net_rm.command.network.action);
    try std.testing.expect(p_net_rm.command.network.force);
    try std.testing.expectEqualStrings("isolated-net", p_net_rm.command.network.name.?);

    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "network", "create" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "network", "create", "--driver", "bogus", "mynet" }));
    try std.testing.expectError(error.MissingValue, parse(alloc, &.{ "network", "create", "--driver" }));
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "network", "rm" }));
}

test "parse run supports --cpus, --env-file, -l/--label, --entrypoint, --hostname, --restart without leaks" {
    const alloc = std.testing.allocator;
    const p = try parse(alloc, &.{
        "run",
        "--cpus",
        "0.5",
        "--env-file",
        "/srv/a.env",
        "--env-file=/srv/b.env",
        "-l",
        "app=api",
        "--label=tier=backend",
        "--entrypoint",
        "/bin/sh",
        "--hostname",
        "api-1.local",
        "--restart=on-failure:3",
        "alpine:3.20",
        "-c",
        "echo ok",
    });
    defer p.deinit(alloc);
    const r = p.command.run;
    try std.testing.expectEqual(@as(?i64, 500_000_000), r.nano_cpus);
    try std.testing.expectEqual(@as(usize, 2), r.env_files.len);
    try std.testing.expectEqualStrings("/srv/a.env", r.env_files[0]);
    try std.testing.expectEqualStrings("/srv/b.env", r.env_files[1]);
    try std.testing.expectEqual(@as(usize, 2), r.labels.len);
    try std.testing.expectEqualStrings("app", r.labels[0].key);
    try std.testing.expectEqualStrings("backend", r.labels[1].value);
    try std.testing.expectEqualStrings("/bin/sh", r.entrypoint.?);
    try std.testing.expectEqualStrings("api-1.local", r.hostname.?);
    try std.testing.expectEqualStrings("on-failure", r.restart_policy.?.name);
    try std.testing.expectEqual(@as(u32, 3), r.restart_policy.?.max_retry_count);

    // Error paths after allocating env_files and labels must not leak.
    try std.testing.expectError(error.MissingArgument, parse(alloc, &.{ "run", "--env-file", "/srv/a.env", "-l", "k=v" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--env-file", "/srv/a.env", "-l", "k=v", "--cpus", "0", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--label", "a=b", "--hostname", "-bad", "alpine" }));
    try std.testing.expectError(error.InvalidValue, parse(alloc, &.{ "run", "--label", "a=b", "--restart", "never", "alpine" }));
}
