//! Input, path, port, identity, and signal validation for Podman API requests.
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");
pub const types = @import("podman_types.zig");

pub const api_prefix = "/v1.40";

pub const ApiError = types.ApiError;
pub const TmpfsBounds = types.TmpfsBounds;
pub const HostConfig = types.HostConfig;
pub const RestartPolicy = types.RestartPolicy;
pub const Mount = types.Mount;
pub const PortMapping = types.PortMapping;
pub const ExposedPorts = types.ExposedPorts;
pub const PortBindings = types.PortBindings;
pub const LabelEntry = types.LabelEntry;
pub const LabelsMap = types.LabelsMap;
pub const ContainerCreateRequest = types.ContainerCreateRequest;
pub const NetworkCreateRequest = types.NetworkCreateRequest;
pub const NetworkCreateResponse = types.NetworkCreateResponse;

/// Validates a container ID or name to prevent path traversal, query injection,
/// and HTTP request-line tampering.
pub fn validateIdentifier(id: []const u8) ApiError!void {
    if (id.len == 0 or id.len > 128) return ApiError.InvalidIdentifier;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return ApiError.InvalidIdentifier;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':') continue;
        return ApiError.InvalidIdentifier;
    }
}

/// Validates a container/image reference used inside an inspect URL path.
/// Allows image-reference characters (including `/` and `:`) while rejecting
/// control chars, URL delimiters that could alter the request line, and any
/// `..` path segment that could escape the API prefix (BUG-021).
pub fn validateResourceRef(ref: []const u8) ApiError!void {
    if (ref.len == 0 or ref.len > 256) return ApiError.InvalidIdentifier;
    if (std.mem.eql(u8, ref, ".") or std.mem.eql(u8, ref, "..")) return ApiError.InvalidIdentifier;
    var segments = std.mem.splitScalar(u8, ref, '/');
    while (segments.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return ApiError.InvalidIdentifier;
    }
    for (ref) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':' or c == '/' or c == '@') continue;
        return ApiError.InvalidIdentifier;
    }
}

/// Host directories whose subtree must never be bind-mounted into a container.
/// Matched as `path == prefix` or `path` living under `prefix/`.
const blocked_host_prefixes = [_][]const u8{
    "/proc",
    "/sys",
    "/dev",
    "/boot",
    "/run",
    "/var/run",
    "/var/lib/docker",
    "/var/lib/containers",
    "/etc",
    "/root",
};

/// Specific `/etc` files that are safe to bind-mount, but only read-only.
const safe_etc_files = [_][]const u8{
    "/etc/localtime",
    "/etc/timezone",
    "/etc/hosts",
    "/etc/resolv.conf",
    "/etc/nsswitch.conf",
    "/etc/hostname",
};

/// True when `path` equals `prefix` or is a descendant of `prefix/`.
fn isUnder(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// Rejects empty, relative, over-long, control-char, `..`/`.`-containing, and
/// `//`/trailing-slash paths. Used for both host sources and container targets.
fn validateAbsolutePath(path: []const u8) ApiError!void {
    if (path.len == 0 or path.len > 4096) return ApiError.InvalidHostPath;
    if (path[0] != '/') return ApiError.InvalidHostPath;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidHostPath;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    _ = it.next(); // leading empty component produced by the root slash
    while (it.next()) |comp| {
        if (comp.len == 0) return ApiError.InvalidHostPath; // "//" or trailing "/"
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return ApiError.InvalidHostPath;
    }
}

fn isSafeEtcFile(path: []const u8) bool {
    for (safe_etc_files) |f| {
        if (std.mem.eql(u8, path, f)) return true;
    }
    return false;
}

fn validateHostPathLexical(path: []const u8, readonly: bool) ApiError!void {
    try validateAbsolutePath(path);

    if (isSafeEtcFile(path)) {
        if (!readonly) return ApiError.InvalidHostPath;
        return;
    }
    for (blocked_host_prefixes) |prefix| {
        if (isUnder(path, prefix)) return ApiError.InvalidHostPath;
    }
}

/// Checks symlink targets along `path` (or its deepest existing ancestor when
/// `path` does not exist yet) so symlinks into blocked roots cannot bypass the
/// lexical bind-mount deny-list (BUG-025).
fn validateHostPathSymlinks(io: std.Io, path: []const u8, readonly: bool) ApiError!void {
    var real_buf: [utils.max_path_bytes]u8 = undefined;
    if (utils.realpath(io, path, &real_buf)) |real| {
        if (!std.mem.eql(u8, real, path)) {
            try validateHostPathLexical(real, readonly);
        }
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return ApiError.InvalidHostPath,
    }

    // Walk up missing components: reject dangling symlinks on any missing node
    // and re-check the resolved deepest existing ancestor combined with the tail.
    var cur: []const u8 = path;
    while (true) {
        var link_buf: [utils.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(io, cur, &link_buf)) |_| {
            return ApiError.InvalidHostPath; // dangling symlink cannot be safely verified
        } else |lerr| switch (lerr) {
            error.FileNotFound, error.NotLink => {},
            else => return ApiError.InvalidHostPath,
        }

        const parent = std.fs.path.dirname(cur) orelse "/";
        if (utils.realpath(io, parent, &real_buf)) |real_parent| {
            const tail = if (std.mem.eql(u8, parent, "/")) path else path[parent.len..];
            var combined_buf: [utils.max_path_bytes]u8 = undefined;
            const combined = if (std.mem.eql(u8, real_parent, "/"))
                tail
            else
                std.fmt.bufPrint(&combined_buf, "{s}{s}", .{ real_parent, tail }) catch return ApiError.InvalidHostPath;
            try validateHostPathLexical(combined, readonly);
            return;
        } else |perr| switch (perr) {
            error.FileNotFound => {
                if (std.mem.eql(u8, parent, "/")) return;
                cur = parent;
            },
            else => return ApiError.InvalidHostPath,
        }
    }
}

/// Fail-closed host-path policy for bind mounts (BUG-014, BUG-025). Rejects
/// dangerous system roots, traversal, symlink escapes into blocked prefixes,
/// dangling symlinks, and read-write mounts of sensitive `/etc` files.
pub fn validateHostPath(io: std.Io, path: []const u8, readonly: bool) ApiError!void {
    try validateHostPathLexical(path, readonly);
    try validateHostPathSymlinks(io, path, readonly);
}

/// Validates the in-container mount destination (must be an absolute,
/// traversal-free path).
pub fn validateContainerPath(path: []const u8) ApiError!void {
    return validateAbsolutePath(path) catch ApiError.InvalidMountTarget;
}

/// Validates a Podman named volume (no host path involved).
pub fn validateVolumeName(name: []const u8) ApiError!void {
    if (name.len == 0 or name.len > 128) return ApiError.InvalidHostPath;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return ApiError.InvalidHostPath;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return ApiError.InvalidHostPath;
    }
}

/// Classifies and validates a `-v` mount: absolute sources become `bind`
/// mounts (policy-checked), everything else a named `volume`.
pub fn makeMount(io: std.Io, source: []const u8, target: []const u8, readonly: bool) ApiError!Mount {
    try validateContainerPath(target);
    if (std.mem.startsWith(u8, source, "/")) {
        try validateHostPath(io, source, readonly);
        return .{ .Type = "bind", .Source = source, .Target = target, .ReadOnly = readonly };
    }
    try validateVolumeName(source);
    return .{ .Type = "volume", .Source = source, .Target = target, .ReadOnly = readonly };
}

pub fn validateMount(io: std.Io, m: Mount) ApiError!void {
    if (std.mem.eql(u8, m.Type, "bind")) {
        try validateHostPath(io, m.Source, m.ReadOnly);
    } else if (std.mem.eql(u8, m.Type, "volume")) {
        try validateVolumeName(m.Source);
    } else {
        return ApiError.InvalidHostPath;
    }
    try validateContainerPath(m.Target);
}

/// Validates a published port: container/host ports are 1..65535, the protocol
/// is tcp/udp/sctp, and any host address must be a valid IPv4 literal (BUG-015).
pub fn validatePortMapping(p: PortMapping) ApiError!void {
    if (p.container_port == 0) return ApiError.InvalidPort;
    if (p.host_port) |hp| {
        if (hp == 0) return ApiError.InvalidPort;
    }
    if (!types.isValidPortProto(p.proto)) {
        return ApiError.InvalidPort;
    }
    if (p.host_ip) |ip| {
        _ = std.Io.net.IpAddress.parseIp4(ip, 0) catch return ApiError.InvalidPort;
    }
}

/// Validates and constructs a `PortMapping` (defense-in-depth re-check used by
/// `main` before the request is serialized).
pub fn makePortMapping(
    host_ip: ?[]const u8,
    host_port: ?u16,
    container_port: u16,
    proto: []const u8,
) ApiError!PortMapping {
    const mapping = PortMapping{
        .host_ip = host_ip,
        .host_port = host_port,
        .container_port = container_port,
        .proto = proto,
    };
    try validatePortMapping(mapping);
    return mapping;
}

/// Network modes accepted for `--network` (BUG-016). Any other value is
/// rejected so the daemon never receives an unexpected network configuration.
const allowed_network_modes = [_][]const u8{ "none", "bridge", "host", "pasta", "slirp4netns" };

pub fn validateNetworkMode(mode: []const u8) ApiError!void {
    for (allowed_network_modes) |m| {
        if (std.mem.eql(u8, mode, m)) return;
    }
    return ApiError.InvalidNetwork;
}

/// Validates the in-container working directory (same path policy as mount
/// targets: absolute, traversal-free, control-char-free, ≤ 4096 bytes).
pub fn validateWorkdir(path: []const u8) ApiError!void {
    validateAbsolutePath(path) catch return ApiError.InvalidWorkdir;
}

/// Validates `USER[:GROUP]`: one or two non-empty fields of alphanumerics plus
/// `_`, `-`, `.`, each not starting with `-`/`.` (BUG-016).
pub fn validateUser(user: []const u8) ApiError!void {
    if (user.len == 0 or user.len > 128) return ApiError.InvalidUser;
    var it = std.mem.splitScalar(u8, user, ':');
    var fields: usize = 0;
    while (it.next()) |field| {
        fields += 1;
        if (fields > 2) return ApiError.InvalidUser;
        if (field.len == 0 or field.len > 64) return ApiError.InvalidUser;
        for (field, 0..) |c, idx| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
                if (idx == 0 and (c == '-' or c == '.')) return ApiError.InvalidUser;
                continue;
            }
            return ApiError.InvalidUser;
        }
    }
    return;
}

/// Validates a Linux capability name: `ALL` or an uppercase `[A-Z][A-Z0-9_]*`
/// token (BUG-016). Rejects injection characters and lowercase names.
pub fn validateCapability(cap: []const u8) ApiError!void {
    if (cap.len == 0 or cap.len > 64) return ApiError.InvalidCapability;
    if (std.mem.eql(u8, cap, "ALL")) return;
    if (!std.ascii.isUpper(cap[0])) return ApiError.InvalidCapability;
    for (cap) |c| {
        if (std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_') continue;
        return ApiError.InvalidCapability;
    }
}

/// Signals accepted by `zigpod kill -s` (`POST /containers/{id}/kill?signal=...`).
/// Restricted to a strict allow-list so arbitrary query strings cannot reach the daemon.
const allowed_signals = [_][]const u8{
    "SIGTERM",
    "SIGKILL",
    "SIGINT",
    "SIGHUP",
    "SIGQUIT",
    "SIGUSR1",
    "SIGUSR2",
    "TERM",
    "KILL",
    "INT",
    "HUP",
    "QUIT",
    "USR1",
    "USR2",
};

pub fn validateSignal(sig: []const u8) ApiError!void {
    for (allowed_signals) |s| {
        if (std.mem.eql(u8, sig, s)) return;
    }
    return ApiError.InvalidSignal;
}

pub fn appendQueryEncoded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "%{X:0>2}", .{c});
        }
    }
}

pub fn logApiFailure(logger: *log.Logger, method: []const u8, path: []const u8, resp: http.Response) ApiError {
    const trimmed = std.mem.trim(u8, resp.body, " \r\n\t");
    if (trimmed.len > 0) {
        logger.err("API {s} {s} failed (HTTP {d}): {s}", .{ method, path, resp.status, trimmed });
    } else {
        logger.err("API {s} {s} failed (HTTP {d})", .{ method, path, resp.status });
    }
    return ApiError.PodmanApiError;
}

pub fn formatSizeU64(buf: []u8, bytes: u64) []const u8 {
    const clamped: i64 = if (bytes > std.math.maxInt(i64)) std.math.maxInt(i64) else @intCast(bytes);
    return utils.formatSize(buf, clamped);
}

pub const max_nano_cpus: i64 = 1024 * 1_000_000_000;
pub const max_env_file_bytes: usize = 1024 * 1024;

pub fn validateNanoCpus(nano_cpus: i64) ApiError!void {
    if (nano_cpus <= 0 or nano_cpus > max_nano_cpus) return ApiError.InvalidCpuLimit;
}

pub fn validateHostname(h: []const u8) ApiError!void {
    if (h.len == 0 or h.len > 64) return ApiError.InvalidHostname;
    if (h[0] == '.' or h[0] == '-' or h[h.len - 1] == '.' or h[h.len - 1] == '-') {
        return ApiError.InvalidHostname;
    }
    var prev_dot = false;
    for (h) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-') {
            prev_dot = false;
        } else if (c == '.') {
            if (prev_dot) return ApiError.InvalidHostname;
            prev_dot = true;
        } else {
            return ApiError.InvalidHostname;
        }
    }
}

/// `--dns`: must be an IPv4/IPv6 literal (no hostnames, ports, or scopes).
pub fn validateDnsServer(ip: []const u8) ApiError!void {
    if (ip.len == 0 or ip.len > 45) return ApiError.InvalidDns;
    _ = std.Io.net.IpAddress.parse(ip, 0) catch return ApiError.InvalidDns;
}

/// `--add-host`: `HOSTNAME:IP` where HOSTNAME passes the hostname rules and IP
/// is an IPv4/IPv6 literal (IPv6 keeps its own colons after the first one).
pub fn validateExtraHost(entry: []const u8) ApiError!void {
    if (entry.len == 0 or entry.len > 128) return ApiError.InvalidExtraHost;
    const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return ApiError.InvalidExtraHost;
    validateHostname(entry[0..colon]) catch return ApiError.InvalidExtraHost;
    const ip = entry[colon + 1 ..];
    if (ip.len == 0) return ApiError.InvalidExtraHost;
    _ = std.Io.net.IpAddress.parse(ip, 0) catch return ApiError.InvalidExtraHost;
}

/// `--platform`: `os/arch[/variant]`, each part `[a-z0-9_]{1,32}`.
pub fn validatePlatform(p: []const u8) ApiError!void {
    if (p.len == 0 or p.len > 100) return ApiError.InvalidPlatform;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        parts += 1;
        if (part.len == 0 or part.len > 32) return ApiError.InvalidPlatform;
        for (part) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return ApiError.InvalidPlatform;
        }
    }
    if (parts < 2 or parts > 3) return ApiError.InvalidPlatform;
}

pub fn validateRestartPolicy(rp: RestartPolicy) ApiError!void {
    if (std.mem.eql(u8, rp.Name, "on-failure")) {
        if (rp.MaximumRetryCount > 10_000) return ApiError.InvalidRestartPolicy;
        return;
    }
    if ((std.mem.eql(u8, rp.Name, "no") or
        std.mem.eql(u8, rp.Name, "always") or
        std.mem.eql(u8, rp.Name, "unless-stopped")) and rp.MaximumRetryCount == 0)
    {
        return;
    }
    return ApiError.InvalidRestartPolicy;
}

pub fn validateLabel(entry: LabelEntry) ApiError!void {
    if (entry.key.len == 0 or entry.key.len > 256) return ApiError.InvalidLabel;
    for (entry.key) |c| {
        if (c <= 0x20 or c == 0x7f) return ApiError.InvalidLabel;
    }
    if (entry.value.len > 4096) return ApiError.InvalidLabel;
    for (entry.value) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidLabel;
    }
}

const allowed_network_drivers = [_][]const u8{ "bridge", "macvlan", "ipvlan" };

pub fn validateNetworkDriver(driver: []const u8) ApiError!void {
    for (allowed_network_drivers) |d| {
        if (std.mem.eql(u8, driver, d)) return;
    }
    return ApiError.InvalidNetworkDriver;
}

/// Validates a container path for `zigpod cp` (allows `"/"` as well as any
/// safe absolute path allowed by `validateContainerPath`).
pub fn validateCpContainerPath(path: []const u8) ApiError!void {
    if (std.mem.eql(u8, path, "/")) return;
    return validateContainerPath(path);
}

/// Validates and normalizes an archive entry path before extraction. Returns
/// empty slice ONLY for a benign `"."` / `"./"` root directory marker; rejects
/// absolute paths, `..`, backslashes, and control characters (Tar-Slip guard).
pub fn validateTarEntryPath(raw_name: []const u8) ApiError![]const u8 {
    if (raw_name.len == 0 or raw_name.len > 4096) return ApiError.InvalidHostPath;
    for (raw_name) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') return ApiError.InvalidHostPath;
    }
    var trimmed = raw_name;
    while (std.mem.startsWith(u8, trimmed, "./")) {
        trimmed = trimmed[2..];
    }
    if (std.mem.eql(u8, trimmed, ".") or trimmed.len == 0) return "";
    if (trimmed[0] == '/') return ApiError.InvalidHostPath;
    if (trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
        if (trimmed.len == 0) return ApiError.InvalidHostPath;
    }
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) {
            return ApiError.InvalidHostPath;
        }
    }
    return trimmed;
}

/// Ensures a tar symlink target stays strictly relative and cannot traverse
/// above the extraction root directory (`..` depth balance check).
pub fn validateTarSymlinkTarget(entry_rel_path: []const u8, link_target: []const u8) ApiError!void {
    if (link_target.len == 0 or link_target.len >= utils.max_path_bytes) return ApiError.InvalidHostPath;
    if (link_target[0] == '/') return ApiError.InvalidHostPath;
    for (link_target) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') return ApiError.InvalidHostPath;
    }

    var depth: usize = 0;
    if (std.fs.path.dirname(entry_rel_path)) |dir| {
        var dir_it = std.mem.splitScalar(u8, dir, '/');
        while (dir_it.next()) |comp| {
            if (comp.len > 0) depth += 1;
        }
    }

    var it = std.mem.splitScalar(u8, link_target, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (depth == 0) return ApiError.InvalidHostPath;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
}

pub const MergedEnv = struct {
    items: [][]const u8,
    owned_strings: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MergedEnv) void {
        for (self.owned_strings) |s| self.allocator.free(s);
        self.allocator.free(self.owned_strings);
        self.allocator.free(self.items);
    }
};

/// Safely loads `KEY=VALUE` entries from `--env-file` paths (checked against
/// `validateHostPath` + `realpathAlloc` + regular-file verification) and merges
/// explicit `-e`/`--env` items afterward.
pub fn loadAndMergeEnv(
    io: std.Io,
    allocator: std.mem.Allocator,
    env_files: []const []const u8,
    cli_env: []const []const u8,
) !MergedEnv {
    var owned: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(allocator);

    for (env_files) |raw_path| {
        try validateHostPath(io, raw_path, false);
        const real_path = utils.realpathAlloc(io, std.Io.Dir.cwd(), raw_path, allocator) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return err,
            else => return ApiError.InvalidHostPath,
        };
        defer allocator.free(real_path);
        try validateHostPath(io, real_path, false);

        const st = std.Io.Dir.cwd().statFile(io, real_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return err,
            else => return ApiError.InvalidHostPath,
        };
        if (st.kind != .file) return ApiError.InvalidHostPath;

        const file = try std.Io.Dir.openFileAbsolute(io, real_path, .{});
        defer file.close(io);
        const opened_st = try file.stat(io);
        if (opened_st.kind != .file) return ApiError.InvalidHostPath;

        const content = utils.readFileToEndAlloc(io, file, allocator, max_env_file_bytes) catch |err| switch (err) {
            error.FileTooBig => return ApiError.InvalidEnvFile,
            else => return err,
        };
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            var line = raw_line;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return ApiError.InvalidEnvFile;
            const key = trimmed[0..eq];
            const val = trimmed[eq + 1 ..];
            if (key.len == 0 or key.len > 256) return ApiError.InvalidEnvFile;
            for (key) |c| {
                if (c <= 0x20 or c == 0x7f) return ApiError.InvalidEnvFile;
            }
            for (val) |c| {
                if (c < 0x20 or c == 0x7f) return ApiError.InvalidEnvFile;
            }
            if (items.items.len >= 4096) return ApiError.InvalidEnvFile;

            try items.ensureUnusedCapacity(allocator, 1);
            try owned.ensureUnusedCapacity(allocator, 1);
            const dup = try allocator.dupe(u8, trimmed);
            owned.appendAssumeCapacity(dup);
            items.appendAssumeCapacity(dup);
        }
    }

    for (cli_env) |e| {
        try items.append(allocator, e);
    }

    const owned_slice = try owned.toOwnedSlice(allocator);
    errdefer {
        for (owned_slice) |s| allocator.free(s);
        allocator.free(owned_slice);
    }
    const items_slice = try items.toOwnedSlice(allocator);
    return .{
        .items = items_slice,
        .owned_strings = owned_slice,
        .allocator = allocator,
    };
}

pub const max_shm_bytes: i64 = 64 * 1024 * 1024 * 1024;

pub fn validateShmSize(shm_bytes: i64) ApiError!void {
    if (shm_bytes <= 0 or shm_bytes > max_shm_bytes) return ApiError.InvalidShmSize;
}

const allowed_ulimit_names = [_][]const u8{
    "nofile",
    "nproc",
    "fsize",
    "core",
    "memlock",
    "stack",
    "data",
    "cpu",
    "as",
};

pub fn validateUlimit(u: types.Ulimit) ApiError!void {
    var allowed = false;
    for (allowed_ulimit_names) |name| {
        if (std.mem.eql(u8, u.Name, name)) {
            allowed = true;
            break;
        }
    }
    if (!allowed) return ApiError.InvalidUlimit;
    if (u.Soft < 0 or u.Hard < u.Soft or u.Hard > 1_000_000_000_000) return ApiError.InvalidUlimit;
}

pub fn validateHealthConfig(hc: types.HealthConfig) ApiError!void {
    if (hc.Test.len == 0 or hc.Test.len > 8) return ApiError.InvalidHealthcheck;
    for (hc.Test) |arg| {
        if (arg.len == 0 or arg.len > 1024) return ApiError.InvalidHealthcheck;
        for (arg) |c| {
            if (c < 0x20 or c == 0x7f) return ApiError.InvalidHealthcheck;
        }
    }
    if (hc.Interval) |iv| {
        if (iv < 1_000_000 or iv > 24 * 3600 * @as(i64, 1_000_000_000)) return ApiError.InvalidHealthcheck;
    }
}

// ---------------------------------------------------------------- tests

fn rep(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

test "validateIdentifier rejects traversal, injection, and invalid sizes" {
    try validateIdentifier("abcdef123456");
    try validateIdentifier("web-1");
    try validateIdentifier("my_container.service");
    try validateIdentifier("sha256:abcdef0123");

    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier(""));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("."));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier(".."));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("../containers"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("abc/def"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("id?force=true"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("id#frag"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("id\r\nX-Evil: 1"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier("has space"));

    const too_long = &rep("a", 129);
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier(too_long));
}

test "validateHostPath enforces the fail-closed bind-mount policy" {
    try validateHostPath(std.testing.io, "/home/user/data", true);
    try validateHostPath(std.testing.io, "/home/user/data", false);
    try validateHostPath(std.testing.io, "/srv/app", false);
    try validateHostPath(std.testing.io, "/etc/hosts", true);
    try validateHostPath(std.testing.io, "/etc/localtime", true);

    const bad = [_][]const u8{
        "",                    "relative/path",           "/",
        "/etc",                "/etc/passwd",             "/etc/ssh",
        "/proc",               "/proc/1",                 "/sys",
        "/dev",                "/dev/sda",                "/boot",
        "/run",                "/run/podman/podman.sock", "/var/run/docker.sock",
        "/root",               "/root/.ssh",              "/var/lib/docker",
        "/var/lib/containers", "/home/user/../etc",       "/home/user/..",
        "/home//user",         "/srv/data/",              "/etc/../etc/hosts",
    };
    for (bad) |p| {
        try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath(std.testing.io, p, true));
    }

    // Sensitive /etc files may only be mounted read-only.
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath(std.testing.io, "/etc/hosts", false));
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath(std.testing.io, "/etc/resolv.conf", false));
    // Control characters are rejected.
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath(std.testing.io, "/srv/\x00evil", true));
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath(std.testing.io, "/srv/a\nb", true));
}

test "makeMount classifies bind vs named volume and validates the target" {
    const b = try makeMount(std.testing.io, "/srv/data", "/data", true);
    try std.testing.expectEqualStrings("bind", b.Type);
    try std.testing.expectEqualStrings("/srv/data", b.Source);
    try std.testing.expectEqualStrings("/data", b.Target);
    try std.testing.expect(b.ReadOnly);

    const v = try makeMount(std.testing.io, "myvol", "/var/lib/data", false);
    try std.testing.expectEqualStrings("volume", v.Type);
    try std.testing.expect(!v.ReadOnly);

    try std.testing.expectError(ApiError.InvalidHostPath, makeMount(std.testing.io, "/etc", "/data", true));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount(std.testing.io, "../evil", "/data", true));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount(std.testing.io, "bad/name", "/data", true));
    try std.testing.expectError(ApiError.InvalidMountTarget, makeMount(std.testing.io, "/srv/data", "data", true));
    try std.testing.expectError(ApiError.InvalidMountTarget, makeMount(std.testing.io, "/srv/data", "/data/../etc", true));
}

test "ContainerCreateRequest serializes bind mounts" {
    const alloc = std.testing.allocator;
    const mounts = [_]Mount{
        .{ .Type = "bind", .Source = "/srv/data", .Target = "/data", .ReadOnly = true },
        .{ .Type = "volume", .Source = "myvol", .Target = "/vol", .ReadOnly = false },
    };
    const req = ContainerCreateRequest{ .Image = "alpine:3.20", .Mounts = &mounts };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"Mounts\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Type\":\"bind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Source\":\"/srv/data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Target\":\"/data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Type\":\"volume\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadOnly\":false") != null);
}

test "validatePortMapping and makePortMapping reject invalid ports" {
    try validatePortMapping(.{ .container_port = 80 });
    try validatePortMapping(.{ .host_ip = "127.0.0.1", .host_port = 8080, .container_port = 80, .proto = "udp" });

    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 0 }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .host_port = 0 }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .proto = "icmp" }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .host_ip = "not-an-ip" }));
    try std.testing.expectError(ApiError.InvalidPort, validatePortMapping(.{ .container_port = 80, .host_ip = "1.2.3.4.5" }));

    const m = try makePortMapping("10.0.0.1", 9000, 9000, "sctp");
    try std.testing.expectEqualStrings("10.0.0.1", m.host_ip.?);
    try std.testing.expectEqual(@as(?u16, 9000), m.host_port);
    try std.testing.expectError(ApiError.InvalidPort, makePortMapping(null, null, 0, "tcp"));
}

test "ExposedPorts and PortBindings serialize to Docker JSON" {
    const alloc = std.testing.allocator;
    const ports = [_]PortMapping{
        .{ .host_port = 8080, .container_port = 80 },
        .{ .host_port = 53, .container_port = 53, .proto = "udp" },
        .{ .host_ip = "127.0.0.1", .host_port = 9000, .container_port = 9000 },
        .{ .container_port = 3000 },
    };
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .ExposedPorts = .{ .ports = &ports },
        .HostConfig = .{ .PortBindings = .{ .ports = &ports } },
    };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"ExposedPorts\":{\"80/tcp\":{},\"53/udp\":{},\"9000/tcp\":{},\"3000/tcp\":{}}") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"PortBindings\":{\"80/tcp\":[{\"HostPort\":\"8080\"}],\"53/udp\":[{\"HostPort\":\"53\"}],\"9000/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"9000\"}]}",
    ) != null);
}

test "validate network, workdir, user, and capability fields" {
    for (allowed_network_modes) |m| try validateNetworkMode(m);
    try std.testing.expectError(ApiError.InvalidNetwork, validateNetworkMode("bogus"));
    try std.testing.expectError(ApiError.InvalidNetwork, validateNetworkMode(""));
    try std.testing.expectError(ApiError.InvalidNetwork, validateNetworkMode("host;rm -rf /"));

    try validateWorkdir("/work");
    try validateWorkdir("/var/lib/data");
    try std.testing.expectError(ApiError.InvalidWorkdir, validateWorkdir("relative"));
    try std.testing.expectError(ApiError.InvalidWorkdir, validateWorkdir("/work/../etc"));
    try std.testing.expectError(ApiError.InvalidWorkdir, validateWorkdir("/work/"));

    try validateUser("1000");
    try validateUser("1000:1000");
    try validateUser("nobody:nogroup");
    try std.testing.expectError(ApiError.InvalidUser, validateUser(""));
    try std.testing.expectError(ApiError.InvalidUser, validateUser(":"));
    try std.testing.expectError(ApiError.InvalidUser, validateUser("a:b:c"));
    try std.testing.expectError(ApiError.InvalidUser, validateUser("bad user"));
    try std.testing.expectError(ApiError.InvalidUser, validateUser("-root"));

    try validateCapability("ALL");
    try validateCapability("NET_ADMIN");
    try validateCapability("CHOWN");
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability(""));
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability("net_admin"));
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability("1BAD"));
    try std.testing.expectError(ApiError.InvalidCapability, validateCapability("NET ADMIN"));
}

test "ContainerCreateRequest serializes network, workdir, user, and capabilities" {
    const alloc = std.testing.allocator;
    const cap_drop = [_][]const u8{"ALL"};
    const cap_add = [_][]const u8{"NET_BIND_SERVICE"};
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .WorkingDir = "/work",
        .User = "1000:1000",
        .HostConfig = .{
            .NetworkMode = "none",
            .CapDrop = &cap_drop,
            .CapAdd = &cap_add,
        },
    };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"WorkingDir\":\"/work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"User\":\"1000:1000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NetworkMode\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"CapDrop\":[\"ALL\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"CapAdd\":[\"NET_BIND_SERVICE\"]") != null);
}

test "validateResourceRef accepts image refs and rejects injection" {
    try validateResourceRef("alpine:3.20");
    try validateResourceRef("docker.io/library/alpine:3.20");
    try validateResourceRef("sha256:abc123");
    try validateResourceRef("web");
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef(""));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef(".."));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a b"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a?b"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a\nb"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("alpine;rm-rf /"));
}

test "validateResourceRef rejects traversal path segments (BUG-021)" {
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("a/../b"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("web/../../etc/shadow"));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef("..hidden/../etc"));
    try validateResourceRef("a/./b");
    try validateResourceRef("docker.io/library/alpine:3.20");
    try validateResourceRef("reg.mirror/team/name:1.2.3");
}

test "validateResourceRef accepts image refs at the 256-byte boundary and rejects longer" {
    const ref_256 = "docker.io/library/" ++ &rep("a", 233) ++ ":3.20";
    try std.testing.expectEqual(@as(usize, 256), ref_256.len);
    try validateResourceRef(ref_256);

    const ref_257 = "docker.io/library/" ++ &rep("a", 234) ++ ":3.20";
    try std.testing.expectEqual(@as(usize, 257), ref_257.len);
    try std.testing.expectError(ApiError.InvalidIdentifier, validateResourceRef(ref_257));

    const digest_ref = "docker.io/library/alpine@sha256:" ++ &rep("0123456789abcdef", 4);
    try std.testing.expectEqual(@as(usize, 96), digest_ref.len);
    try validateResourceRef(digest_ref);
}

test "validateIdentifier enforces the 128-byte length boundary" {
    try validateIdentifier(&rep("x", 128));
    try std.testing.expectError(ApiError.InvalidIdentifier, validateIdentifier(&rep("x", 129)));
}

test "ContainerCreateRequest serializes hardening HostConfig fields" {
    const alloc = std.testing.allocator;
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .HostConfig = HostConfig{
            .AutoRemove = true,
            .ReadonlyRootfs = true,
            .Memory = 67_108_864,
            .PidsLimit = 32,
            .SecurityOpt = &.{"no-new-privileges"},
        },
    };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadonlyRootfs\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Memory\":67108864") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"PidsLimit\":32") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SecurityOpt\":[\"no-new-privileges\"]") != null);
}

test "validateShmSize, validateUlimit, and validateHealthConfig enforce bounds" {
    try validateShmSize(1);
    try validateShmSize(max_shm_bytes);
    try std.testing.expectError(ApiError.InvalidShmSize, validateShmSize(0));
    try std.testing.expectError(ApiError.InvalidShmSize, validateShmSize(-1));
    try std.testing.expectError(ApiError.InvalidShmSize, validateShmSize(max_shm_bytes + 1));

    try validateUlimit(.{ .Name = "nofile", .Soft = 1024, .Hard = 2048 });
    try validateUlimit(.{ .Name = "core", .Soft = 0, .Hard = 0 });
    try std.testing.expectError(ApiError.InvalidUlimit, validateUlimit(.{ .Name = "rtprio", .Soft = 1, .Hard = 1 }));
    try std.testing.expectError(ApiError.InvalidUlimit, validateUlimit(.{ .Name = "nofile", .Soft = 10, .Hard = 5 }));
    try std.testing.expectError(ApiError.InvalidUlimit, validateUlimit(.{ .Name = "nofile", .Soft = -1, .Hard = 5 }));
    try std.testing.expectError(ApiError.InvalidUlimit, validateUlimit(.{ .Name = "nofile", .Soft = 1, .Hard = 1_000_000_000_001 }));

    try validateHealthConfig(.{ .Test = &.{ "CMD-SHELL", "true" }, .Interval = 1_000_000 });
    try validateHealthConfig(.{ .Test = &.{ "CMD-SHELL", "true" } });
    try std.testing.expectError(ApiError.InvalidHealthcheck, validateHealthConfig(.{ .Test = &.{} }));
    try std.testing.expectError(ApiError.InvalidHealthcheck, validateHealthConfig(.{ .Test = &.{ "CMD-SHELL", "" } }));
    try std.testing.expectError(ApiError.InvalidHealthcheck, validateHealthConfig(.{ .Test = &.{ "CMD-SHELL", "a\nb" } }));
    try std.testing.expectError(ApiError.InvalidHealthcheck, validateHealthConfig(.{ .Test = &.{ "CMD-SHELL", "true" }, .Interval = 999_999 }));
    try std.testing.expectError(ApiError.InvalidHealthcheck, validateHealthConfig(.{ .Test = &.{ "CMD-SHELL", "true" }, .Interval = 24 * 3600 * @as(i64, 1_000_000_000) + 1 }));
}

test "validateNanoCpus, Hostname, RestartPolicy, Label, Driver, and Tar-Slip validators" {
    try validateNanoCpus(500_000_000);
    try validateNanoCpus(max_nano_cpus);
    try std.testing.expectError(ApiError.InvalidCpuLimit, validateNanoCpus(0));
    try std.testing.expectError(ApiError.InvalidCpuLimit, validateNanoCpus(-1));
    try std.testing.expectError(ApiError.InvalidCpuLimit, validateNanoCpus(max_nano_cpus + 1));

    try validateHostname("api-1.local");
    try std.testing.expectError(ApiError.InvalidHostname, validateHostname("-bad"));
    try std.testing.expectError(ApiError.InvalidHostname, validateHostname("a..b"));

    try validateRestartPolicy(.{ .Name = "no" });
    try validateRestartPolicy(.{ .Name = "always" });
    try validateRestartPolicy(.{ .Name = "unless-stopped" });
    try validateRestartPolicy(.{ .Name = "on-failure", .MaximumRetryCount = 5 });
    try std.testing.expectError(ApiError.InvalidRestartPolicy, validateRestartPolicy(.{ .Name = "always", .MaximumRetryCount = 1 }));
    try std.testing.expectError(ApiError.InvalidRestartPolicy, validateRestartPolicy(.{ .Name = "bogus" }));

    try validateLabel(.{ .key = "app", .value = "web service" });
    try std.testing.expectError(ApiError.InvalidLabel, validateLabel(.{ .key = "", .value = "v" }));
    try std.testing.expectError(ApiError.InvalidLabel, validateLabel(.{ .key = "k\x00", .value = "v" }));

    try validateNetworkDriver("bridge");
    try validateNetworkDriver("macvlan");
    try validateNetworkDriver("ipvlan");
    try std.testing.expectError(ApiError.InvalidNetworkDriver, validateNetworkDriver("bogus"));

    try validateCpContainerPath("/");
    try validateCpContainerPath("/etc/hosts");
    try std.testing.expectError(ApiError.InvalidMountTarget, validateCpContainerPath("rel"));

    try std.testing.expectEqualStrings("", try validateTarEntryPath("."));
    try std.testing.expectEqualStrings("", try validateTarEntryPath("./"));
    try std.testing.expectEqualStrings("app/main.sh", try validateTarEntryPath("./app/main.sh"));
    try std.testing.expectEqualStrings("app", try validateTarEntryPath("app/"));
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarEntryPath("/etc/passwd"));
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarEntryPath("../escape"));
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarEntryPath("a/../../etc/shadow"));
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarEntryPath("a\\b"));
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarEntryPath("a//b"));

    try validateTarSymlinkTarget("app/sub/link", "../ok.txt");
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarSymlinkTarget("link", "../outside"));
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarSymlinkTarget("app/link", "../../outside"));
    try std.testing.expectError(ApiError.InvalidHostPath, validateTarSymlinkTarget("app/link", "/etc/passwd"));
}

test "loadAndMergeEnv parses safe env files, rejects malformed/symlinks, and frees memory cleanly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.env",
        .data = "# comment line\r\n\n  FOO=bar\r\nEMPTY=\nSPACED=hello world\n",
    });
    const env_path = try std.fs.path.join(alloc, &.{ dir_path, "app.env" });
    defer alloc.free(env_path);

    var merged = try loadAndMergeEnv(std.testing.io, alloc, &.{env_path}, &.{"CLI=override"});
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 4), merged.items.len);
    try std.testing.expectEqualStrings("FOO=bar", merged.items[0]);
    try std.testing.expectEqualStrings("EMPTY=", merged.items[1]);
    try std.testing.expectEqualStrings("SPACED=hello world", merged.items[2]);
    try std.testing.expectEqualStrings("CLI=override", merged.items[3]);

    // Symlink into /etc must fail closed.
    try tmp.dir.symLink(std.testing.io, "/etc/hosts", "etc_link.env", .{});
    const link_path = try std.fs.path.join(alloc, &.{ dir_path, "etc_link.env" });
    defer alloc.free(link_path);
    try std.testing.expectError(ApiError.InvalidHostPath, loadAndMergeEnv(std.testing.io, alloc, &.{link_path}, &.{}));

    // Malformed line without '=' must fail closed with no leaks.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.env", .data = "FOO=ok\nMISSING_EQUALS\n" });
    const bad_path = try std.fs.path.join(alloc, &.{ dir_path, "bad.env" });
    defer alloc.free(bad_path);
    try std.testing.expectError(ApiError.InvalidEnvFile, loadAndMergeEnv(std.testing.io, alloc, &.{bad_path}, &.{}));

    // Relative path must fail closed.
    try std.testing.expectError(ApiError.InvalidHostPath, loadAndMergeEnv(std.testing.io, alloc, &.{"relative.env"}, &.{}));
}

test "BUG-025: validateHostPath and makeMount reject symlinks to denied paths" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    try tmp.dir.createDir(std.testing.io, "safe_dir", .default_dir);
    const safe_sub = try std.fs.path.join(alloc, &.{ dir_path, "safe_dir" });
    defer alloc.free(safe_sub);

    try tmp.dir.symLink(std.testing.io, safe_sub, "ok_link", .{});
    try tmp.dir.symLink(std.testing.io, "/etc", "etc_link", .{});
    try tmp.dir.symLink(std.testing.io, "/etc/hosts", "hosts_link", .{});
    try tmp.dir.symLink(std.testing.io, "/etc/nonexistent_zigpod_target", "dangling_link", .{});

    const ok_link = try std.fs.path.join(alloc, &.{ dir_path, "ok_link" });
    defer alloc.free(ok_link);
    const etc_link = try std.fs.path.join(alloc, &.{ dir_path, "etc_link" });
    defer alloc.free(etc_link);
    const etc_link_sub = try std.fs.path.join(alloc, &.{ dir_path, "etc_link", "future_sub" });
    defer alloc.free(etc_link_sub);
    const hosts_link = try std.fs.path.join(alloc, &.{ dir_path, "hosts_link" });
    defer alloc.free(hosts_link);
    const dangling_link = try std.fs.path.join(alloc, &.{ dir_path, "dangling_link" });
    defer alloc.free(dangling_link);

    // Safe symlink target inside allowed directory must succeed.
    const safe_mount = try makeMount(std.testing.io, ok_link, "/data", false);
    try std.testing.expectEqualStrings("bind", safe_mount.Type);

    // Symlinks resolving into denied directories or rw /etc files must fail closed.
    try std.testing.expectError(ApiError.InvalidHostPath, validateHostPath(std.testing.io, etc_link, true));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount(std.testing.io, etc_link, "/data", true));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount(std.testing.io, etc_link_sub, "/data", true));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount(std.testing.io, hosts_link, "/data", false));
    try std.testing.expectError(ApiError.InvalidHostPath, makeMount(std.testing.io, dangling_link, "/data", true));
}
