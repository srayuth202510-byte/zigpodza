//! Fail-closed sandbox security profiles and pre-flight `zigpod-policy.json` enforcement.
const std = @import("std");
const cli = @import("cli.zig");
const types = @import("podman_types.zig");

pub const ApiError = types.ApiError;

pub const default_sandbox_memory_bytes: i64 = 256 * 1024 * 1024;
pub const default_sandbox_pids_limit: i64 = 64;
pub const default_sandbox_tmpfs_opts = "rw,noexec,nosuid,nodev,size=67108864";

pub const default_allowed_networks = [_][]const u8{"none"};
pub const default_cap_drop_all = [_][]const u8{"ALL"};

pub const Policy = struct {
    profile: []const u8 = "sandbox",
    max_memory_bytes: i64 = default_sandbox_memory_bytes,
    max_pids_limit: i64 = default_sandbox_pids_limit,
    require_read_only: bool = true,
    require_no_new_privileges: bool = true,
    require_cap_drop_all: bool = true,
    forbid_cap_add: bool = true,
    forbid_rw_mounts: bool = true,
    forbid_published_ports: bool = false,
    allowed_networks: []const []const u8 = &default_allowed_networks,
    tmpfs_tmp_options: []const u8 = default_sandbox_tmpfs_opts,
};

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
    if (r.cap_drop.len == 0) r.cap_drop = &default_cap_drop_all;
}

/// Loads and validates a `zigpod-policy.json` file from disk.
pub fn loadPolicyFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Policy) {
    if (path.len == 0 or path.len > 4096) return ApiError.InvalidPolicyFile;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidPolicyFile;
    }

    const raw = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return ApiError.InvalidPolicyFile;
    defer allocator.free(raw);

    const parsed = std.json.parseFromSlice(Policy, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return ApiError.InvalidPolicyFile;
    errdefer parsed.deinit();

    try validatePolicySchema(parsed.value);
    return parsed;
}

pub fn validatePolicySchema(pol: Policy) ApiError!void {
    if (pol.max_memory_bytes <= 0) return ApiError.InvalidPolicyFile;
    if (pol.max_pids_limit <= 0) return ApiError.InvalidPolicyFile;
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

    const pids = r.pids_limit orelse return "policy.max_pids_limit";
    if (pids <= 0 or pids > pol.max_pids_limit) return "policy.max_pids_limit";

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

    const net = r.network orelse return "policy.allowed_networks";
    var net_allowed = false;
    for (pol.allowed_networks) |allowed| {
        if (std.mem.eql(u8, net, allowed)) {
            net_allowed = true;
            break;
        }
    }
    if (!net_allowed) return "policy.allowed_networks";

    return null;
}

pub fn enforceRunPolicy(r: cli.RunOpts, pol: Policy) ApiError!void {
    if (checkRunPolicy(r, pol) != null) return ApiError.PolicyViolation;
}

test "applySandboxDefaults locks down unset RunOpts and passes default policy" {
    var r = cli.RunOpts{ .image = "alpine:3.20", .profile = .sandbox };
    applySandboxDefaults(&r);

    try std.testing.expect(r.read_only);
    try std.testing.expect(r.no_new_privileges);
    try std.testing.expectEqualStrings("none", r.network.?);
    try std.testing.expectEqual(default_sandbox_memory_bytes, r.memory.?);
    try std.testing.expectEqual(default_sandbox_pids_limit, r.pids_limit.?);
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
}

test "loadPolicyFile parses valid zigpod-policy.json and rejects malformed files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    const ok_path = try std.fs.path.join(alloc, &.{ dir_path, "ok-policy.json" });
    defer alloc.free(ok_path);
    try tmp.dir.writeFile(.{
        .sub_path = "ok-policy.json",
        .data =
        \\{"max_memory_bytes":134217728,"max_pids_limit":32,"allowed_networks":["none","pasta"]}
        ,
    });

    const parsed = try loadPolicyFile(alloc, ok_path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 134_217_728), parsed.value.max_memory_bytes);
    try std.testing.expectEqual(@as(i64, 32), parsed.value.max_pids_limit);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.allowed_networks.len);

    const bad_path = try std.fs.path.join(alloc, &.{ dir_path, "bad-policy.json" });
    defer alloc.free(bad_path);
    try tmp.dir.writeFile(.{
        .sub_path = "bad-policy.json",
        .data = "{\"max_memory_bytes\":0}",
    });
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadPolicyFile(alloc, bad_path));
    try std.testing.expectError(ApiError.InvalidPolicyFile, loadPolicyFile(alloc, "/nonexistent/zigpod-policy.json"));
}
