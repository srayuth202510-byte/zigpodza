//! Fail-closed sandbox security profiles and pre-flight `zigpod-policy.json` enforcement.
const std = @import("std");
const cli = @import("cli.zig");
const types = @import("podman_types.zig");
const log = @import("log.zig");
const utils = @import("utils.zig");

pub const ApiError = types.ApiError;

pub const default_sandbox_memory_bytes: i64 = 256 * 1024 * 1024;
pub const default_sandbox_pids_limit: i64 = 64;
pub const default_sandbox_nano_cpus: i64 = 1_000_000_000;
pub const default_sandbox_tmpfs_opts = "rw,noexec,nosuid,nodev,size=67108864";

pub const default_allowed_networks = [_][]const u8{"none"};
pub const default_cap_drop_all = [_][]const u8{"ALL"};

pub const Policy = struct {
    profile: []const u8 = "sandbox",
    max_memory_bytes: i64 = default_sandbox_memory_bytes,
    max_shm_bytes: i64 = 64 * 1024 * 1024,
    max_pids_limit: i64 = default_sandbox_pids_limit,
    max_nano_cpus: i64 = default_sandbox_nano_cpus,
    require_read_only: bool = true,
    require_no_new_privileges: bool = true,
    require_cap_drop_all: bool = true,
    forbid_cap_add: bool = true,
    forbid_rw_mounts: bool = true,
    forbid_published_ports: bool = false,
    forbid_secret_env: bool = true,
    allowed_networks: []const []const u8 = &default_allowed_networks,
    tmpfs_tmp_options: []const u8 = default_sandbox_tmpfs_opts,
};

/// Deterministic secret/hash hygiene check for a single `KEY=VALUE` env entry
/// (mirrors the offline rules in `scripts/balor-security-audit.sh`; the exact
/// hash-type identification stays with `hashid` / `balorsh password`).
pub fn looksLikeSecretEnv(entry: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    const key = entry[0..eq];
    const value = entry[eq + 1 ..];

    if (std.mem.startsWith(u8, value, "$2a$") or
        std.mem.startsWith(u8, value, "$2b$") or
        std.mem.startsWith(u8, value, "$2y$") or
        std.mem.startsWith(u8, value, "$2x$") or
        std.mem.startsWith(u8, value, "$6$") or
        std.mem.startsWith(u8, value, "$5$") or
        std.mem.startsWith(u8, value, "$argon2"))
    {
        return true;
    }
    if (std.mem.startsWith(u8, value, "AKIA") and value.len >= 20) return true;
    const gh_prefixes = [_][]const u8{ "ghp_", "gho_", "ghu_", "ghs_", "ghr_" };
    for (gh_prefixes) |p| {
        if (std.mem.startsWith(u8, value, p) and value.len >= p.len + 20) return true;
    }
    if (std.mem.startsWith(u8, value, "sk-") and value.len >= 19) return true;

    const sensitive_markers = [_][]const u8{ "PASSWORD", "SECRET", "TOKEN", "API_KEY", "PRIVATE_KEY" };
    var upper_buf: [64]u8 = undefined;
    if (key.len > 0 and key.len <= upper_buf.len) {
        const upper = std.ascii.upperString(upper_buf[0..key.len], key);
        for (sensitive_markers) |m| {
            if (std.mem.indexOf(u8, upper, m) != null) {
                const v = std.mem.trim(u8, value, " \t");
                if (v.len == 0 or std.ascii.eqlIgnoreCase(v, "changeme") or std.ascii.eqlIgnoreCase(v, "placeholder")) {
                    return false;
                }
                return true;
            }
        }
    }
    return false;
}

fn hasSecretEnv(env: []const []const u8) bool {
    for (env) |e| {
        if (looksLikeSecretEnv(e)) return true;
    }
    return false;
}

pub const default_sandbox_policy = Policy{};

/// Applies fail-closed defaults for `--profile=sandbox` when the caller did not
/// explicitly specify a flag, so untrusted / AI-agent workloads run locked down
/// by default while still allowing stricter user overrides (e.g. `-m 64m`).
pub fn applySandboxDefaults(r: *cli.RunOpts) void {
    r.read_only = true;
    r.no_new_privileges = true;
    if (r.network == null) r.network = "none";
    if (r.memory == null) r.memory = default_sandbox_memory_bytes;
    if (r.pids_limit == null) r.pids_limit = default_sandbox_pids_limit;
    if (r.nano_cpus == null) r.nano_cpus = default_sandbox_nano_cpus;
    if (r.cap_drop.len == 0) r.cap_drop = &default_cap_drop_all;
}

/// Loads and validates a `zigpod-policy.json` file from disk.
pub fn loadPolicyFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Policy) {
    if (path.len == 0 or path.len > 4096) return ApiError.InvalidPolicyFile;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidPolicyFile;
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024 + 1)) catch return ApiError.InvalidPolicyFile;
    defer allocator.free(raw);

    return parsePolicyJson(allocator, raw);
}

fn parsePolicyJson(allocator: std.mem.Allocator, raw: []const u8) !std.json.Parsed(Policy) {
    const parsed = std.json.parseFromSlice(Policy, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return ApiError.InvalidPolicyFile;
    errdefer parsed.deinit();

    try validatePolicySchema(parsed.value);
    return parsed;
}

/// Loads an implicitly discovered policy file (`./zigpod-policy.json`). Like
/// `zigpod.toml` (BUG-033) it must be a regular file (no symlink) owned by the
/// current user and not group/world-writable, otherwise a planted file in the
/// working directory could silently raise the sandbox ceilings.
pub fn loadImplicitPolicyFile(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) !std.json.Parsed(Policy) {
    const file = dir.openFile(io, sub_path, .{ .follow_symlinks = false }) catch return ApiError.InvalidPolicyFile;
    defer file.close(io);

    const st = log.statxFd(file.handle) orelse return ApiError.InvalidPolicyFile;
    if (!std.posix.S.ISREG(st.mode)) return ApiError.InvalidPolicyFile;
    if (st.uid != std.os.linux.getuid()) return ApiError.InvalidPolicyFile;
    if ((st.mode & 0o022) != 0) return ApiError.InvalidPolicyFile;

    const raw = utils.readFileToEndAlloc(io, file, allocator, 1024 * 1024) catch return ApiError.InvalidPolicyFile;
    defer allocator.free(raw);
    return parsePolicyJson(allocator, raw);
}

pub fn validatePolicySchema(pol: Policy) ApiError!void {
    if (pol.max_memory_bytes <= 0) return ApiError.InvalidPolicyFile;
    if (pol.max_shm_bytes <= 0) return ApiError.InvalidPolicyFile;
    if (pol.max_pids_limit <= 0) return ApiError.InvalidPolicyFile;
    if (pol.max_nano_cpus <= 0) return ApiError.InvalidPolicyFile;
    if (pol.allowed_networks.len == 0) return ApiError.InvalidPolicyFile;
    if (pol.tmpfs_tmp_options.len == 0 or pol.tmpfs_tmp_options.len > 256) return ApiError.InvalidPolicyFile;
    for (pol.tmpfs_tmp_options) |c| {
        if (c <= 0x20 or c == 0x7f) return ApiError.InvalidPolicyFile;
    }
}

/// Validates effective `RunOpts` against `pol` pre-flight (before any socket traffic).
/// Returns the specific rule identifier violated on failure.
pub fn checkRunPolicy(r: cli.RunOpts, pol: Policy) ?[]const u8 {
    if (pol.require_read_only and !r.read_only) return "policy.require_read_only";
    if (pol.require_no_new_privileges and !r.no_new_privileges) return "policy.require_no_new_privileges";

    const mem = r.memory orelse return "policy.max_memory_bytes";
    if (mem <= 0 or mem > pol.max_memory_bytes) return "policy.max_memory_bytes";

    if (r.shm_size) |shm| {
        if (shm <= 0 or shm > pol.max_shm_bytes) return "policy.max_shm_bytes";
    }

    const pids = r.pids_limit orelse return "policy.max_pids_limit";
    if (pids <= 0 or pids > pol.max_pids_limit) return "policy.max_pids_limit";

    const cpus = r.nano_cpus orelse return "policy.max_nano_cpus";
    if (cpus <= 0 or cpus > pol.max_nano_cpus) return "policy.max_nano_cpus";

    if (pol.require_cap_drop_all) {
        var drops_all = false;
        for (r.cap_drop) |cap| {
            if (std.mem.eql(u8, cap, "ALL")) {
                drops_all = true;
                break;
            }
        }
        if (!drops_all) return "policy.require_cap_drop_all";
    }

    if (pol.forbid_cap_add and r.cap_add.len > 0) return "policy.forbid_cap_add";

    if (pol.forbid_rw_mounts) {
        for (r.volumes) |v| {
            if (!v.readonly) return "policy.forbid_rw_mounts";
        }
    }

    if (pol.forbid_published_ports and r.ports.len > 0) return "policy.forbid_published_ports";

    if (pol.forbid_secret_env and hasSecretEnv(r.env)) return "policy.forbid_secret_env";

    const net = r.network orelse return "policy.allowed_networks";
    if (!isNetworkAllowed(pol, net)) return "policy.allowed_networks";

    return null;
}

/// Reports whether `net` is present in `pol.allowed_networks`.
pub fn isNetworkAllowed(pol: Policy, net: []const u8) bool {
    for (pol.allowed_networks) |allowed| {
        if (std.mem.eql(u8, net, allowed)) return true;
    }
    return false;
}

pub fn enforceRunPolicy(r: cli.RunOpts, pol: Policy) ApiError!void {
    if (checkRunPolicy(r, pol) != null) return ApiError.PolicyViolation;
}

/// Renders a policy JSON file (or `default_sandbox_policy` if `path` is null) for `zigpod policy show`.
pub fn showPolicy(io: std.Io, allocator: std.mem.Allocator, path_opt: ?[]const u8, json_mode: bool, writer: anytype) !void {
    if (path_opt) |p| {
        const parsed = try loadPolicyFile(io, allocator, p);
        defer parsed.deinit();
        if (json_mode) {
            const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
            defer allocator.free(out);
            try writer.print("{s}\n", .{out});
            return;
        }
        try printPolicyHuman(writer, p, parsed.value);
        return;
    }

    if (json_mode) {
        const out = try std.json.Stringify.valueAlloc(allocator, default_sandbox_policy, .{ .whitespace = .indent_2 });
        defer allocator.free(out);
        try writer.print("{s}\n", .{out});
        return;
    }
    try printPolicyHuman(writer, "<builtin:sandbox>", default_sandbox_policy);
}

/// Validates a policy file schema and prints a pass/fail summary for `zigpod policy check`.
pub fn checkPolicyFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, json_mode: bool, writer: anytype) !void {
    const parsed = try loadPolicyFile(io, allocator, path);
    defer parsed.deinit();
    if (json_mode) {
        try std.json.Stringify.value(.{
            .valid = true,
            .path = path,
            .profile = parsed.value.profile,
        }, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("policy '{s}' valid (profile={s})\n", .{ path, parsed.value.profile });
    }
}

fn printPolicyHuman(writer: anytype, source: []const u8, pol: Policy) !void {
    try writer.print("Source:                  {s}\n", .{source});
    try writer.print("Profile:                 {s}\n", .{pol.profile});
    try writer.print("Max Memory (bytes):      {d}\n", .{pol.max_memory_bytes});
    try writer.print("Max PIDs Limit:          {d}\n", .{pol.max_pids_limit});
    try writer.print("Max CPU (nanocpus):      {d}\n", .{pol.max_nano_cpus});
    try writer.print("Require Read-Only:       {}\n", .{pol.require_read_only});
    try writer.print("Require No-New-Privs:    {}\n", .{pol.require_no_new_privileges});
    try writer.print("Require CapDrop=ALL:     {}\n", .{pol.require_cap_drop_all});
    try writer.print("Forbid CapAdd:           {}\n", .{pol.forbid_cap_add});
    try writer.print("Forbid RW Mounts:        {}\n", .{pol.forbid_rw_mounts});
    try writer.print("Forbid Published Ports:  {}\n", .{pol.forbid_published_ports});
    try writer.print("Forbid Secret Env:       {}\n", .{pol.forbid_secret_env});
}

test "applySandboxDefaults locks down unset RunOpts and passes default policy" {
    var r = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox };
    applySandboxDefaults(&r);

    try std.testing.expect(r.read_only);
    try std.testing.expect(r.no_new_privileges);
    try std.testing.expectEqualStrings("none", r.network.?);
    try std.testing.expectEqual(default_sandbox_memory_bytes, r.memory.?);
    try std.testing.expectEqual(default_sandbox_pids_limit, r.pids_limit.?);
    try std.testing.expectEqual(default_sandbox_nano_cpus, r.nano_cpus.?);
    try std.testing.expectEqual(@as(usize, 1), r.cap_drop.len);
    try std.testing.expectEqualStrings("ALL", r.cap_drop[0]);

    try enforceRunPolicy(r, default_sandbox_policy);
}

test "enforceRunPolicy rejects flags exceeding sandbox guardrails" {
    // 1) Memory exceeding 256 MiB ceiling
    var r_mem = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .memory = 512 * 1024 * 1024 };
    applySandboxDefaults(&r_mem);
    try std.testing.expectEqualStrings("policy.max_memory_bytes", checkRunPolicy(r_mem, default_sandbox_policy).?);
    try std.testing.expectError(ApiError.PolicyViolation, enforceRunPolicy(r_mem, default_sandbox_policy));

    // 2) PIDs limit exceeding 64
    var r_pids = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .pids_limit = 128 };
    applySandboxDefaults(&r_pids);
    try std.testing.expectEqualStrings("policy.max_pids_limit", checkRunPolicy(r_pids, default_sandbox_policy).?);

    // 3) Disallowed network mode (bridge when only none is allowed)
    var r_net = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .network = "bridge" };
    applySandboxDefaults(&r_net);
    try std.testing.expectEqualStrings("policy.allowed_networks", checkRunPolicy(r_net, default_sandbox_policy).?);

    // 4) Capability addition forbidden in sandbox
    const caps = [_][]const u8{"NET_ADMIN"};
    var r_cap = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .cap_add = &caps };
    applySandboxDefaults(&r_cap);
    try std.testing.expectEqualStrings("policy.forbid_cap_add", checkRunPolicy(r_cap, default_sandbox_policy).?);

    // 5) Writable volume mount forbidden in sandbox
    const rw_vols = [_]cli.Volume{.{ .source = "/srv/data", .destination = "/data", .readonly = false }};
    var r_vol = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .volumes = &rw_vols };
    applySandboxDefaults(&r_vol);
    try std.testing.expectEqualStrings("policy.forbid_rw_mounts", checkRunPolicy(r_vol, default_sandbox_policy).?);

    // 6) CPU limit exceeding 1 CPU sandbox ceiling
    var r_cpu = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .nano_cpus = 2_000_000_000 };
    applySandboxDefaults(&r_cpu);
    try std.testing.expectEqualStrings("policy.max_nano_cpus", checkRunPolicy(r_cpu, default_sandbox_policy).?);

    // 7) /dev/shm exceeding 64 MiB sandbox ceiling (boundary: exactly 64 MiB is allowed)
    var r_shm = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .shm_size = 128 * 1024 * 1024 };
    applySandboxDefaults(&r_shm);
    try std.testing.expectEqualStrings("policy.max_shm_bytes", checkRunPolicy(r_shm, default_sandbox_policy).?);
    var r_shm_ok = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .shm_size = 64 * 1024 * 1024 };
    applySandboxDefaults(&r_shm_ok);
    try std.testing.expect(checkRunPolicy(r_shm_ok, default_sandbox_policy) == null);
}

test "forbid_secret_env fail-closed blocks credential-bearing env" {
    const secrets = [_][]const u8{
        "DB_PASS=$2b$12$abcdefghijklmnopqrstuv",
        "LEGACY_HASH=$6$salt$abcdefghijklmnopqrst",
        "ARG=$argon2id$v=19$m=65536,t=3,p=4$saltsaltsalt",
        "AWS_KEY=AKIAIOSFODNN7EXAMPLE",
        "GH_TOKEN=ghp_1234567890abcdefghij123456",
        "OPENAI_KEY=sk-abcdefghij123456",
        "MY_PASSWORD=s3cr3t-value",
    };
    for (secrets) |s| {
        try std.testing.expect(looksLikeSecretEnv(s));
    }

    const benign = [_][]const u8{
        "PATH=/usr/bin:/bin",
        "DB_PASSWORD=changeme",
        "MY_SECRET=placeholder",
        "EMPTY_TOKEN=",
        "LANG=C.UTF-8",
    };
    for (benign) |s| {
        try std.testing.expect(!looksLikeSecretEnv(s));
    }

    const env = [_][]const u8{"DB_PASS=$2b$12$abcdefghijklmnopqrstuv"};
    var r_secret = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox, .env = &env };
    applySandboxDefaults(&r_secret);
    try std.testing.expectEqualStrings("policy.forbid_secret_env", checkRunPolicy(r_secret, default_sandbox_policy).?);
    try std.testing.expectError(ApiError.PolicyViolation, enforceRunPolicy(r_secret, default_sandbox_policy));

    const allowed = default_sandbox_policy;
    const pol_open = Policy{ .forbid_secret_env = false };
    try std.testing.expectEqualStrings("policy.forbid_secret_env", checkRunPolicy(r_secret, allowed).?);
    try std.testing.expectEqual(@as(?[]const u8, null), checkRunPolicy(r_secret, pol_open));
}

test "showPolicy and checkPolicyFile render and validate policy JSON without leaks" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try showPolicy(std.testing.io, alloc, null, true, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"profile\": \"sandbox\"") != null);

    out.clearRetainingCapacity();
    try checkPolicyFile(std.testing.io, alloc, "zigpod-policy.json", false, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "valid") != null);

    out.clearRetainingCapacity();
    try checkPolicyFile(std.testing.io, alloc, "zigpod-policy.json", true, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"valid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"profile\":\"sandbox\"") != null);
}

test "loadImplicitPolicyFile rejects world/group-writable and symlinked policies (BUG-033)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const body =
        \\{"max_memory_bytes":134217728,"max_pids_limit":32,"allowed_networks":["none"]}
    ;
    const f = try tmp.dir.createFile(io, "zigpod-policy.json", .{});
    try f.writeStreamingAll(io, body);
    try f.setPermissions(io, .fromMode(0o666));
    f.close(io);
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadImplicitPolicyFile(io, alloc, tmp.dir, "zigpod-policy.json"));

    const g = try tmp.dir.openFile(io, "zigpod-policy.json", .{});
    try g.setPermissions(io, .fromMode(0o660));
    g.close(io);
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadImplicitPolicyFile(io, alloc, tmp.dir, "zigpod-policy.json"));

    const ok = try tmp.dir.openFile(io, "zigpod-policy.json", .{});
    try ok.setPermissions(io, .fromMode(0o600));
    ok.close(io);
    const parsed = try loadImplicitPolicyFile(io, alloc, tmp.dir, "zigpod-policy.json");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 134_217_728), parsed.value.max_memory_bytes);

    try tmp.dir.symLink(io, "zigpod-policy.json", "link-policy.json", .{});
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadImplicitPolicyFile(io, alloc, tmp.dir, "link-policy.json"));
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadImplicitPolicyFile(io, alloc, tmp.dir, "missing.json"));
}

test "loadPolicyFile parses valid zigpod-policy.json and rejects malformed files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    const ok_path = try std.fs.path.join(alloc, &.{ dir_path, "ok-policy.json" });
    defer alloc.free(ok_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ok-policy.json",
        .data =
        \\{"max_memory_bytes":134217728,"max_pids_limit":32,"allowed_networks":["none","pasta"]}
        ,
    });

    const parsed = try loadPolicyFile(std.testing.io, alloc, ok_path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 134_217_728), parsed.value.max_memory_bytes);
    try std.testing.expectEqual(@as(i64, 32), parsed.value.max_pids_limit);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.allowed_networks.len);

    const bad_path = try std.fs.path.join(alloc, &.{ dir_path, "bad-policy.json" });
    defer alloc.free(bad_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bad-policy.json",
        .data = "{\"max_memory_bytes\":0}",
    });
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadPolicyFile(std.testing.io, alloc, bad_path));
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadPolicyFile(std.testing.io, alloc, "/nonexistent/zigpod-policy.json"));
}
