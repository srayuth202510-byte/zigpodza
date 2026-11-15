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

test "parseProfile accepts only default and sandbox" {
    try std.testing.expectEqual(Profile.default, try parseProfile("default"));
    try std.testing.expectEqual(Profile.sandbox, try parseProfile("sandbox"));
    try std.testing.expectError(error.InvalidValue, parseProfile(""));
    try std.testing.expectError(error.InvalidValue, parseProfile("Default"));
    try std.testing.expectError(error.InvalidValue, parseProfile("paranoid"));
}

test "parsePolicyPath rejects empty, oversized, and control characters" {
    try std.testing.expectEqualStrings("/etc/zigpod-policy.json", try parsePolicyPath("/etc/zigpod-policy.json"));
    try std.testing.expectError(error.InvalidValue, parsePolicyPath(""));
    try std.testing.expectError(error.InvalidValue, parsePolicyPath("a" ** 4097));
    try std.testing.expectEqualStrings("p" ** 4096, try parsePolicyPath("p" ** 4096));
    try std.testing.expectError(error.InvalidValue, parsePolicyPath("a\x00b"));
    try std.testing.expectError(error.InvalidValue, parsePolicyPath("a\tb"));
    try std.testing.expectError(error.InvalidValue, parsePolicyPath("a\nb"));
}

test "parseMemoryBytes parses unit suffixes case-insensitively with overflow guard" {
    try std.testing.expectEqual(@as(i64, 1), try parseMemoryBytes("1"));
    try std.testing.expectEqual(@as(i64, 1024), try parseMemoryBytes("1k"));
    try std.testing.expectEqual(@as(i64, 1024), try parseMemoryBytes("1KB"));
    try std.testing.expectEqual(@as(i64, 1024), try parseMemoryBytes("1kb"));
    try std.testing.expectEqual(@as(i64, 512 * 1024 * 1024), try parseMemoryBytes("512MB"));
    try std.testing.expectEqual(@as(i64, 2 * 1024 * 1024 * 1024), try parseMemoryBytes("2G"));
    try std.testing.expectEqual(@as(i64, 4096), try parseMemoryBytes("4096b"));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes(""));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes("m"));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes("0b"));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes("-5m"));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes("abc"));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes("99999999999999999999g"));
    try std.testing.expectError(error.InvalidValue, parseMemoryBytes("9999999999999999g"));
}

test "parsePidsLimit requires a positive integer" {
    try std.testing.expectEqual(@as(i64, 64), try parsePidsLimit("64"));
    try std.testing.expectEqual(@as(i64, 1), try parsePidsLimit("1"));
    try std.testing.expectError(error.InvalidValue, parsePidsLimit("0"));
    try std.testing.expectError(error.InvalidValue, parsePidsLimit("-1"));
    try std.testing.expectError(error.InvalidValue, parsePidsLimit(""));
    try std.testing.expectError(error.InvalidValue, parsePidsLimit("many"));
}

test "parseVolumeSpec splits source, destination, and ro/rw option" {
    const v1 = try parseVolumeSpec("/src:/data");
    try std.testing.expectEqualStrings("/src", v1.source);
    try std.testing.expectEqualStrings("/data", v1.destination);
    try std.testing.expect(v1.readonly);

    const v2 = try parseVolumeSpec("/src:/data:rw");
    try std.testing.expect(!v2.readonly);
    try std.testing.expectEqualStrings("/data", v2.destination);

    const v3 = try parseVolumeSpec("/src:/data:ro");
    try std.testing.expect(v3.readonly);

    try std.testing.expectError(error.InvalidValue, parseVolumeSpec("/src"));
    try std.testing.expectError(error.InvalidValue, parseVolumeSpec(":data"));
    try std.testing.expectError(error.InvalidValue, parseVolumeSpec("/src:"));
    try std.testing.expectError(error.InvalidValue, parseVolumeSpec("/src:/data:tx"));
    try std.testing.expectError(error.InvalidValue, parseVolumeSpec("/src:/data:ro:rw"));
}

test "parsePortNumber bounds the range to 1..65535" {
    try std.testing.expectEqual(@as(u16, 1), try parsePortNumber("1"));
    try std.testing.expectEqual(@as(u16, 80), try parsePortNumber("80"));
    try std.testing.expectEqual(@as(u16, 65535), try parsePortNumber("65535"));
    try std.testing.expectError(error.InvalidValue, parsePortNumber(""));
    try std.testing.expectError(error.InvalidValue, parsePortNumber("0"));
    try std.testing.expectError(error.InvalidValue, parsePortNumber("65536"));
    try std.testing.expectError(error.InvalidValue, parsePortNumber("-1"));
    try std.testing.expectError(error.InvalidValue, parsePortNumber("http"));
}

test "parsePortSpec accepts all documented shapes and rejects malformed ones" {
    const p1 = try parsePortSpec("8080");
    try std.testing.expectEqual(@as(u16, 8080), p1.container_port);
    try std.testing.expect(p1.host_port == null);
    try std.testing.expectEqualStrings("tcp", p1.proto);

    const p2 = try parsePortSpec("8080:80");
    try std.testing.expectEqual(@as(u16, 8080), p2.host_port.?);
    try std.testing.expectEqual(@as(u16, 80), p2.container_port);

    const p3 = try parsePortSpec("8080:80/udp");
    try std.testing.expectEqualStrings("udp", p3.proto);

    const p4 = try parsePortSpec("127.0.0.1:8080:80/sctp");
    try std.testing.expectEqualStrings("127.0.0.1", p4.host_ip.?);
    try std.testing.expectEqual(@as(u16, 8080), p4.host_port.?);
    try std.testing.expectEqual(@as(u16, 80), p4.container_port);
    try std.testing.expectEqualStrings("sctp", p4.proto);

    try std.testing.expectError(error.InvalidValue, parsePortSpec(""));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("8080:80:90:100"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("999.1.1.1:8080:80"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("host.example:8080:80"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("8080:80/icmp"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("8080:0"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("0:80"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("a:80"));
    try std.testing.expectError(error.InvalidValue, parsePortSpec("8080:/udp"));
}

test "parseNetworkMode allows exactly the five known modes" {
    for ([_][]const u8{ "none", "bridge", "host", "pasta", "slirp4netns" }) |m| {
        try std.testing.expectEqualStrings(m, try parseNetworkMode(m));
    }
    try std.testing.expectError(error.InvalidValue, parseNetworkMode(""));
    try std.testing.expectError(error.InvalidValue, parseNetworkMode("Host"));
    try std.testing.expectError(error.InvalidValue, parseNetworkMode("slirp"));
}

test "parseWorkdir requires an absolute path" {
    try std.testing.expectEqualStrings("/work", try parseWorkdir("/work"));
    try std.testing.expectEqualStrings("/", try parseWorkdir("/"));
    try std.testing.expectError(error.InvalidValue, parseWorkdir(""));
    try std.testing.expectError(error.InvalidValue, parseWorkdir("work"));
    try std.testing.expectError(error.InvalidValue, parseWorkdir("./work"));
}

test "parseUserSpec validates USER and USER:GROUP shapes" {
    try std.testing.expectEqualStrings("root", try parseUserSpec("root"));
    try std.testing.expectEqualStrings("1000:1000", try parseUserSpec("1000:1000"));
    try std.testing.expectEqualStrings("alice.doe-x_1:grp-2", try parseUserSpec("alice.doe-x_1:grp-2"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec(""));
    try std.testing.expectError(error.InvalidValue, parseUserSpec("root:"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec(":root"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec("a:b:c"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec("-root"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec(".root"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec("ro ot"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec("user:gr oup"));
    try std.testing.expectError(error.InvalidValue, parseUserSpec("u" ** 129));
    try std.testing.expectEqualStrings("u" ** 64, try parseUserSpec("u" ** 64));
    try std.testing.expectError(error.InvalidValue, parseUserSpec("u" ** 65));
}

test "parseCapName requires ALL or an uppercase token" {
    try std.testing.expectEqualStrings("ALL", try parseCapName("ALL"));
    try std.testing.expectEqualStrings("NET_BIND_SERVICE", try parseCapName("NET_BIND_SERVICE"));
    try std.testing.expectEqualStrings("CAP1_X", try parseCapName("CAP1_X"));
    try std.testing.expectError(error.InvalidValue, parseCapName(""));
    try std.testing.expectError(error.InvalidValue, parseCapName("all"));
    try std.testing.expectError(error.InvalidValue, parseCapName("NET_BIND_SERVICE "));
    try std.testing.expectError(error.InvalidValue, parseCapName("1ABC"));
    try std.testing.expectError(error.InvalidValue, parseCapName("-X"));
    try std.testing.expectError(error.InvalidValue, parseCapName("X" ** 65));
}

test "parseSignal accepts full names and short aliases only" {
    for ([_][]const u8{ "SIGTERM", "SIGKILL", "SIGINT", "SIGHUP", "SIGQUIT", "SIGUSR1", "SIGUSR2", "TERM", "KILL", "INT", "HUP", "QUIT", "USR1", "USR2" }) |sig| {
        try std.testing.expectEqualStrings(sig, try parseSignal(sig));
    }
    try std.testing.expectError(error.InvalidValue, parseSignal(""));
    try std.testing.expectError(error.InvalidValue, parseSignal("SIGFAKE"));
    try std.testing.expectError(error.InvalidValue, parseSignal("sigterm"));
    try std.testing.expectError(error.InvalidValue, parseSignal("9"));
}
