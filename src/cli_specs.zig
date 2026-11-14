//! Value and spec parsers (memory limits, volumes, ports, network, user, capabilities, signals).
const std = @import("std");
const t = @import("cli_types.zig");

const Volume = t.Volume;
const PortMapping = t.PortMapping;
const Profile = t.Profile;
const ParseError = t.ParseError;
const eql = t.eql;

pub fn parseProfile(s: []const u8) ParseError!Profile {
    if (eql(s, "default")) return .default;
    if (eql(s, "sandbox")) return .sandbox;
    return error.InvalidValue;
}

pub fn parsePolicyPath(s: []const u8) ParseError![]const u8 {
    if (s.len == 0 or s.len > 4096) return error.InvalidValue;
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidValue;
    }
    return s;
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

pub fn parsePidsLimit(s: []const u8) ParseError!i64 {
    const limit = std.fmt.parseInt(i64, s, 10) catch return error.InvalidValue;
    if (limit <= 0) return error.InvalidValue;
    return limit;
}

/// Parses a `SRC:DST[:ro|rw]` volume specification. Only syntax is checked
/// here; the host-path security policy is enforced by `podman_api.makeMount`.
pub fn parseVolumeSpec(spec: []const u8) ParseError!Volume {
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

pub fn parsePortNumber(s: []const u8) ParseError!u16 {
    if (s.len == 0) return error.InvalidValue;
    const n = std.fmt.parseInt(u16, s, 10) catch return error.InvalidValue;
    if (n == 0) return error.InvalidValue;
    return n;
}

/// Parses `[IP:]HOST:CONTAINER[/proto]` or `CONTAINER[/proto]`. Only IPv4 host
/// addresses are accepted. The port policy is re-checked by `podman_api.makePortMapping`.
pub fn parsePortSpec(spec: []const u8) ParseError!PortMapping {
    if (spec.len == 0) return error.InvalidValue;

    var base = spec;
    var proto: []const u8 = "tcp";
    if (std.mem.lastIndexOfScalar(u8, spec, '/')) |slash| {
        proto = spec[slash + 1 ..];
        base = spec[0..slash];
        if (!(eql(proto, "tcp") or eql(proto, "udp") or eql(proto, "sctp"))) return error.InvalidValue;
    }

    var it = std.mem.splitScalar(u8, base, ':');
    const f0 = it.next() orelse return error.InvalidValue;
    const f1 = it.next();
    const f2 = it.next();
    if (it.next() != null) return error.InvalidValue; // more than three fields

    var mapping = PortMapping{ .container_port = 0, .proto = proto };
    if (f2) |container| {
        // IP:HOST:CONTAINER — host address must be a valid IPv4 literal.
        _ = std.net.Address.parseIp4(f0, 0) catch return error.InvalidValue;
        mapping.host_ip = f0;
        mapping.host_port = try parsePortNumber(f1.?);
        mapping.container_port = try parsePortNumber(container);
    } else if (f1) |container| {
        mapping.host_port = try parsePortNumber(f0);
        mapping.container_port = try parsePortNumber(container);
    } else {
        mapping.container_port = try parsePortNumber(f0);
    }
    return mapping;
}

/// Network modes accepted by `--network`. Re-checked by `podman_api.validateNetworkMode`.
const network_modes = [_][]const u8{ "none", "bridge", "host", "pasta", "slirp4netns" };

pub fn parseNetworkMode(s: []const u8) ParseError![]const u8 {
    for (network_modes) |m| {
        if (eql(s, m)) return s;
    }
    return error.InvalidValue;
}

/// Container working directory: only the absolute-path shape is checked here;
/// the full path policy is enforced by `podman_api.validateWorkdir`.
pub fn parseWorkdir(s: []const u8) ParseError![]const u8 {
    if (s.len == 0 or s[0] != '/') return error.InvalidValue;
    return s;
}

/// `USER[:GROUP]` where each field is alphanumeric plus `_`, `-`, `.`.
pub fn parseUserSpec(s: []const u8) ParseError![]const u8 {
    if (s.len == 0 or s.len > 128) return error.InvalidValue;
    var it = std.mem.splitScalar(u8, s, ':');
    var fields: usize = 0;
    while (it.next()) |field| {
        fields += 1;
        if (fields > 2) return error.InvalidValue;
        if (field.len == 0 or field.len > 64) return error.InvalidValue;
        for (field, 0..) |c, idx| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
                if (idx == 0 and (c == '-' or c == '.')) return error.InvalidValue;
                continue;
            }
            return error.InvalidValue;
        }
    }
    return s;
}

/// Linux capability name: `ALL` or an uppercase `[A-Z][A-Z0-9_]*` token.
pub fn parseCapName(s: []const u8) ParseError![]const u8 {
    if (s.len == 0 or s.len > 64) return error.InvalidValue;
    if (eql(s, "ALL")) return s;
    if (!std.ascii.isUpper(s[0])) return error.InvalidValue;
    for (s) |c| {
        if (std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_') continue;
        return error.InvalidValue;
    }
    return s;
}

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

pub fn parseSignal(s: []const u8) ParseError![]const u8 {
    for (allowed_signals) |allowed| {
        if (eql(s, allowed)) return s;
    }
    return error.InvalidValue;
}

// ---------------------------------------------------------------- tests

test "parseMemoryBytes and spec parsers handle valid and invalid inputs" {
    try std.testing.expectEqual(@as(i64, 512 * 1024 * 1024), try parseMemoryBytes("512m"));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes("0"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("0:80"));
    try std.testing.expectError(error.InvalidValue, parseNetworkMode("custom"));
    const dup = try std.testing.allocator.dupe(u8, "SIGTERM");
    defer std.testing.allocator.free(dup);
    try std.testing.expectEqualStrings("SIGTERM", try parseSignal(dup));
}
