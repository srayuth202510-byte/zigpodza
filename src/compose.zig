//! Pure-Zig Podman Compose-lite (`compose.yaml`) parser, topological planner,
//! and policy-guarded lifecycle executor (`zigpod compose up|down|ps`).
const std = @import("std");
const cli = @import("cli.zig");
const cli_specs = @import("cli_specs.zig");
const http = @import("http.zig");
const log = @import("log.zig");
const pod = @import("podman_api.zig");
const policy = @import("policy.zig");
const utils = @import("utils.zig");

pub const max_compose_bytes: usize = 256 * 1024;
pub const max_services: usize = 64;

pub const ComposeError = error{
    ComposeFileNotFound,
    InvalidComposePath,
    InvalidComposeSyntax,
    MissingServiceImage,
    DuplicateService,
    UnknownDependency,
    CyclicDependency,
    TooManyServices,
};

pub const ComposeNetwork = struct {
    name: []const u8,
    driver: []const u8,
    internal: bool = false,

    pub fn deinit(self: ComposeNetwork, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.driver);
    }
};

pub const ComposeService = struct {
    name: []const u8,
    image: []const u8,
    container_name: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    user: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    network_mode: ?[]const u8 = null,
    restart_name: ?[]const u8 = null,
    restart_max_retries: u32 = 0,
    read_only: bool = false,
    init: bool = false,
    mem_limit: ?i64 = null,
    shm_size: ?i64 = null,
    pids_limit: ?i64 = null,
    nano_cpus: ?i64 = null,
    entrypoint: [][]const u8 = &.{},
    cmd: [][]const u8 = &.{},
    env: [][]const u8 = &.{},
    env_files: [][]const u8 = &.{},
    cap_drop: [][]const u8 = &.{},
    cap_add: [][]const u8 = &.{},
    networks: [][]const u8 = &.{},
    depends_on: [][]const u8 = &.{},
    ports: []cli.PortMapping = &.{},
    volumes: []cli.Volume = &.{},
    labels: []cli.Label = &.{},

    fn freeStrList(alloc: std.mem.Allocator, list: [][]const u8) void {
        for (list) |s| alloc.free(s);
        if (list.len > 0) alloc.free(list);
    }

    pub fn deinit(self: *ComposeService, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        if (self.image.len > 0) alloc.free(self.image);
        if (self.container_name) |s| alloc.free(s);
        if (self.workdir) |s| alloc.free(s);
        if (self.user) |s| alloc.free(s);
        if (self.hostname) |s| alloc.free(s);
        if (self.network_mode) |s| alloc.free(s);
        if (self.restart_name) |s| alloc.free(s);
        freeStrList(alloc, self.entrypoint);
        freeStrList(alloc, self.cmd);
        freeStrList(alloc, self.env);
        freeStrList(alloc, self.env_files);
        freeStrList(alloc, self.cap_drop);
        freeStrList(alloc, self.cap_add);
        freeStrList(alloc, self.networks);
        freeStrList(alloc, self.depends_on);
        for (self.ports) |p| {
            if (p.host_ip) |ip| alloc.free(ip);
            alloc.free(p.proto);
        }
        if (self.ports.len > 0) alloc.free(self.ports);
        for (self.volumes) |v| {
            alloc.free(v.source);
            alloc.free(v.destination);
        }
        if (self.volumes.len > 0) alloc.free(self.volumes);
        for (self.labels) |l| {
            alloc.free(l.key);
            alloc.free(l.value);
        }
        if (self.labels.len > 0) alloc.free(self.labels);
    }

    pub fn resolvedContainerName(self: ComposeService, alloc: std.mem.Allocator, project: []const u8) ![]u8 {
        if (self.container_name) |cn| return alloc.dupe(u8, cn);
        return std.fmt.allocPrint(alloc, "{s}_{s}_1", .{ project, self.name });
    }
};

pub const ComposeFile = struct {
    project: []const u8,
    base_dir: []const u8,
    services: []ComposeService,
    networks: []ComposeNetwork,

    pub fn deinit(self: *ComposeFile, alloc: std.mem.Allocator) void {
        alloc.free(self.project);
        alloc.free(self.base_dir);
        for (self.services) |*s| s.deinit(alloc);
        if (self.services.len > 0) alloc.free(self.services);
        for (self.networks) |n| n.deinit(alloc);
        if (self.networks.len > 0) alloc.free(self.networks);
    }
};

fn sanitizeProjectName(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (raw) |c| {
        if (out.items.len >= 32) break;
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            try out.append(alloc, std.ascii.toLower(c));
        } else if (c == ' ' or c == '.') {
            try out.append(alloc, '-');
        }
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "zigpod");
    return out.toOwnedSlice(alloc);
}

fn verifyNonSymlinkRegularFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path.len > 4096) return ComposeError.InvalidComposePath;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f) return ComposeError.InvalidComposePath;
    }

    var link_buf: [utils.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().readLink(io, path, &link_buf)) |_| {
        return ComposeError.InvalidComposePath;
    } else |err| switch (err) {
        error.NotLink => {},
        error.FileNotFound => return ComposeError.ComposeFileNotFound,
        else => return ComposeError.InvalidComposePath,
    }

    const real = utils.realpathAlloc(io, std.Io.Dir.cwd(), path, alloc) catch |err| switch (err) {
        error.FileNotFound => return ComposeError.ComposeFileNotFound,
        else => return ComposeError.InvalidComposePath,
    };
    errdefer alloc.free(real);

    var f = std.Io.Dir.openFileAbsolute(io, real, .{}) catch return ComposeError.InvalidComposePath;
    defer f.close(io);
    const st = f.stat(io) catch return ComposeError.InvalidComposePath;
    if (st.kind != .file or st.size > max_compose_bytes) return ComposeError.InvalidComposePath;
    return real;
}

/// Resolves and reads a compose file (`-f` or `compose.yaml`/`compose.yml`/`docker-compose.yml`).
pub fn loadComposeFile(io: std.Io, alloc: std.mem.Allocator, explicit_path: ?[]const u8) !ComposeFile {
    const default_candidates = [_][]const u8{
        "compose.yaml",
        "compose.yml",
        "docker-compose.yml",
    };

    const real_path = if (explicit_path) |p|
        try verifyNonSymlinkRegularFile(io, alloc, p)
    else blk: {
        var found: ?[]u8 = null;
        for (default_candidates) |cand| {
            if (verifyNonSymlinkRegularFile(io, alloc, cand)) |rp| {
                found = rp;
                break;
            } else |err| switch (err) {
                ComposeError.ComposeFileNotFound => continue,
                else => return err,
            }
        }
        break :blk found orelse return ComposeError.ComposeFileNotFound;
    };
    defer alloc.free(real_path);

    const base_dir = std.fs.path.dirname(real_path) orelse "/";
    const proj_raw = std.fs.path.basename(base_dir);
    const project = try sanitizeProjectName(alloc, proj_raw);
    defer alloc.free(project);

    var f = try std.Io.Dir.openFileAbsolute(io, real_path, .{});
    defer f.close(io);
    const content = try utils.readFileToEndAlloc(io, f, alloc, max_compose_bytes);
    defer alloc.free(content);

    return parseComposeYaml(alloc, content, project, base_dir);
}

fn stripYamlComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    for (line, 0..) |c, idx| {
        if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '"' and !in_single) {
            in_double = !in_double;
        } else if (c == '#' and !in_single and !in_double) {
            if (idx == 0 or line[idx - 1] == ' ') return std.mem.trimEnd(u8, line[0..idx], " \t");
        }
    }
    return std.mem.trimEnd(u8, line, " \t");
}

fn unquoteScalar(raw: []const u8) []const u8 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn splitFlowList(alloc: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return ComposeError.InvalidComposeSyntax;
    }
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |it| alloc.free(it);
        list.deinit(alloc);
    }
    if (inner.len == 0) return list.toOwnedSlice(alloc);

    var start: usize = 0;
    var in_single = false;
    var in_double = false;
    for (inner, 0..) |c, idx| {
        if (c == '\'' and !in_double) in_single = !in_single else if (c == '"' and !in_single) in_double = !in_double else if (c == ',' and !in_single and !in_double) {
            const item = unquoteScalar(inner[start..idx]);
            if (item.len > 0) {
                try list.ensureUnusedCapacity(alloc, 1);
                list.appendAssumeCapacity(try alloc.dupe(u8, item));
            }
            start = idx + 1;
        }
    }
    const tail = unquoteScalar(inner[start..]);
    if (tail.len > 0) {
        try list.ensureUnusedCapacity(alloc, 1);
        list.appendAssumeCapacity(try alloc.dupe(u8, tail));
    }
    return list.toOwnedSlice(alloc);
}

fn splitCommandWords(alloc: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') return splitFlowList(alloc, s);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |it| alloc.free(it);
        out.deinit(alloc);
    }
    const clean = unquoteScalar(s);
    var it = std.mem.tokenizeAny(u8, clean, " \t");
    while (it.next()) |tok| {
        try out.ensureUnusedCapacity(alloc, 1);
        out.appendAssumeCapacity(try alloc.dupe(u8, tok));
    }
    return out.toOwnedSlice(alloc);
}

fn appendDupStr(alloc: std.mem.Allocator, dst: *[][]const u8, val: []const u8) !void {
    var list = std.ArrayList([]const u8).fromOwnedSlice(dst.*);
    errdefer {
        for (list.items) |s| alloc.free(s);
        list.deinit(alloc);
        dst.* = &.{};
    }
    try list.ensureUnusedCapacity(alloc, 1);
    list.appendAssumeCapacity(try alloc.dupe(u8, val));
    dst.* = try list.toOwnedSlice(alloc);
}

fn appendDupPort(alloc: std.mem.Allocator, dst: *[]cli.PortMapping, pm: cli.PortMapping) !void {
    var list = std.ArrayList(cli.PortMapping).fromOwnedSlice(dst.*);
    errdefer {
        for (list.items) |p| {
            if (p.host_ip) |ip| alloc.free(ip);
            alloc.free(p.proto);
        }
        list.deinit(alloc);
        dst.* = &.{};
    }
    const ip_dup: ?[]const u8 = if (pm.host_ip) |ip| try alloc.dupe(u8, ip) else null;
    const proto_dup = alloc.dupe(u8, pm.proto) catch |err| {
        if (ip_dup) |ip| alloc.free(ip);
        return err;
    };
    list.append(alloc, .{
        .host_ip = ip_dup,
        .host_port = pm.host_port,
        .container_port = pm.container_port,
        .proto = proto_dup,
    }) catch |err| {
        if (ip_dup) |ip| alloc.free(ip);
        alloc.free(proto_dup);
        return err;
    };
    dst.* = try list.toOwnedSlice(alloc);
}

fn appendDupVolume(alloc: std.mem.Allocator, dst: *[]cli.Volume, v: cli.Volume) !void {
    var list = std.ArrayList(cli.Volume).fromOwnedSlice(dst.*);
    errdefer {
        for (list.items) |item| {
            alloc.free(item.source);
            alloc.free(item.destination);
        }
        list.deinit(alloc);
        dst.* = &.{};
    }
    const src_dup = try alloc.dupe(u8, v.source);
    const dst_dup = alloc.dupe(u8, v.destination) catch |err| {
        alloc.free(src_dup);
        return err;
    };
    list.append(alloc, .{ .source = src_dup, .destination = dst_dup, .readonly = v.readonly }) catch |err| {
        alloc.free(src_dup);
        alloc.free(dst_dup);
        return err;
    };
    dst.* = try list.toOwnedSlice(alloc);
}

fn appendDupLabel(alloc: std.mem.Allocator, dst: *[]cli.Label, lbl: cli.Label) !void {
    var list = std.ArrayList(cli.Label).fromOwnedSlice(dst.*);
    errdefer {
        for (list.items) |l| {
            alloc.free(l.key);
            alloc.free(l.value);
        }
        list.deinit(alloc);
        dst.* = &.{};
    }
    const k_dup = try alloc.dupe(u8, lbl.key);
    const v_dup = alloc.dupe(u8, lbl.value) catch |err| {
        alloc.free(k_dup);
        return err;
    };
    list.append(alloc, .{ .key = k_dup, .value = v_dup }) catch |err| {
        alloc.free(k_dup);
        alloc.free(v_dup);
        return err;
    };
    dst.* = try list.toOwnedSlice(alloc);
}

fn parseBoolScalar(raw: []const u8) !bool {
    const v = unquoteScalar(raw);
    if (std.ascii.eqlIgnoreCase(v, "true") or std.mem.eql(u8, v, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(v, "false") or std.mem.eql(u8, v, "no")) return false;
    return ComposeError.InvalidComposeSyntax;
}

fn parseColonPair(line: []const u8) ?struct { key: []const u8, val: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (colon == 0) return null;
    const after = line[colon + 1 ..];
    if (after.len > 0 and after[0] != ' ' and after[0] != '\t') return null;
    return .{
        .key = unquoteScalar(line[0..colon]),
        .val = std.mem.trim(u8, after, " \t"),
    };
}

/// Parses a `compose.yaml` subset into owned `ComposeFile`. Caller retains ownership
/// of `project_in` and `base_dir_in`; `ComposeFile.deinit` frees internal copies.
pub fn parseComposeYaml(
    alloc: std.mem.Allocator,
    content: []const u8,
    project_in: []const u8,
    base_dir_in: []const u8,
) !ComposeFile {
    var project = try alloc.dupe(u8, project_in);
    errdefer alloc.free(project);
    const base_dir = try alloc.dupe(u8, base_dir_in);
    errdefer alloc.free(base_dir);

    var services: std.ArrayList(ComposeService) = .empty;
    errdefer {
        for (services.items) |*s| s.deinit(alloc);
        services.deinit(alloc);
    }
    var networks: std.ArrayList(ComposeNetwork) = .empty;
    errdefer {
        for (networks.items) |n| n.deinit(alloc);
        networks.deinit(alloc);
    }

    const Section = enum { none, services, networks };
    var top_sec: Section = .none;
    var svc_indent: ?usize = null;
    var net_indent: ?usize = null;
    var cur_subkey: ?[]const u8 = null;
    var cur_subkey_indent: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const no_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const clean = stripYamlComment(no_cr);
        if (clean.len == 0) continue;

        var indent: usize = 0;
        while (indent < clean.len) : (indent += 1) {
            if (clean[indent] == '\t') return ComposeError.InvalidComposeSyntax;
            if (clean[indent] != ' ') break;
        }
        const body = clean[indent..];
        if (body.len == 0) continue;

        if (indent == 0) {
            cur_subkey = null;
            const pair = parseColonPair(body) orelse return ComposeError.InvalidComposeSyntax;
            if (std.mem.eql(u8, pair.key, "services")) {
                top_sec = .services;
            } else if (std.mem.eql(u8, pair.key, "networks")) {
                top_sec = .networks;
            } else if (std.mem.eql(u8, pair.key, "name") and pair.val.len > 0) {
                const new_proj = try sanitizeProjectName(alloc, unquoteScalar(pair.val));
                alloc.free(project);
                project = new_proj;
                top_sec = .none;
            } else {
                top_sec = .none;
            }
            continue;
        }

        switch (top_sec) {
            .none => continue,
            .networks => {
                if (net_indent == null or indent <= net_indent.?) {
                    net_indent = indent;
                    const pair = parseColonPair(body) orelse return ComposeError.InvalidComposeSyntax;
                    try pod.validateIdentifier(pair.key);
                    const n_name = try alloc.dupe(u8, pair.key);
                    errdefer alloc.free(n_name);
                    const n_drv = try alloc.dupe(u8, "bridge");
                    errdefer alloc.free(n_drv);
                    try networks.append(alloc, .{ .name = n_name, .driver = n_drv });
                } else if (networks.items.len > 0) {
                    var cur_net = &networks.items[networks.items.len - 1];
                    const pair = parseColonPair(body) orelse return ComposeError.InvalidComposeSyntax;
                    if (std.mem.eql(u8, pair.key, "driver") and pair.val.len > 0) {
                        const drv = try cli_specs.parseNetworkDriver(unquoteScalar(pair.val));
                        const drv_dup = try alloc.dupe(u8, drv);
                        alloc.free(cur_net.driver);
                        cur_net.driver = drv_dup;
                    } else if (std.mem.eql(u8, pair.key, "internal") and pair.val.len > 0) {
                        cur_net.internal = try parseBoolScalar(pair.val);
                    } else {
                        return ComposeError.InvalidComposeSyntax;
                    }
                }
            },
            .services => {
                if (svc_indent == null or indent <= svc_indent.?) {
                    svc_indent = indent;
                    cur_subkey = null;
                    const pair = parseColonPair(body) orelse return ComposeError.InvalidComposeSyntax;
                    try pod.validateIdentifier(pair.key);
                    for (services.items) |existing| {
                        if (std.mem.eql(u8, existing.name, pair.key)) return ComposeError.DuplicateService;
                    }
                    if (services.items.len >= max_services) return ComposeError.TooManyServices;
                    const svc_name = try alloc.dupe(u8, pair.key);
                    errdefer alloc.free(svc_name);
                    try services.append(alloc, .{ .name = svc_name, .image = &.{} });
                    continue;
                }

                if (services.items.len == 0) return ComposeError.InvalidComposeSyntax;
                const svc = &services.items[services.items.len - 1];

                // Nested list/map item under an active service property.
                if (cur_subkey != null and indent > cur_subkey_indent) {
                    const sk = cur_subkey.?;
                    if (std.mem.startsWith(u8, body, "- ")) {
                        const raw_item = std.mem.trim(u8, body[2..], " \t");
                        // Reject YAML list-of-maps long syntax (e.g. `- type: bind`) fail-closed
                        // instead of coercing `key: val` into a single bogus item string (BUG-027).
                        if (!std.mem.eql(u8, sk, "command") and !std.mem.eql(u8, sk, "entrypoint") and
                            raw_item.len > 0 and raw_item[0] != '"' and raw_item[0] != '\'' and
                            parseColonPair(raw_item) != null)
                        {
                            return ComposeError.InvalidComposeSyntax;
                        }
                        const item = unquoteScalar(body[2..]);
                        try applyServiceListItem(alloc, svc, sk, item);
                        continue;
                    }
                    if (parseColonPair(body)) |kv| {
                        try applyServiceMapItem(alloc, svc, sk, kv.key, kv.val);
                        continue;
                    }
                    return ComposeError.InvalidComposeSyntax;
                }

                cur_subkey = null;
                const pair = parseColonPair(body) orelse return ComposeError.InvalidComposeSyntax;
                if (pair.val.len == 0) {
                    if (!isServiceListKey(pair.key)) return ComposeError.InvalidComposeSyntax;
                    cur_subkey = pair.key;
                    cur_subkey_indent = indent;
                    continue;
                }

                try applyServiceScalarOrFlow(alloc, svc, pair.key, pair.val);
            },
        }
    }

    if (services.items.len == 0) return ComposeError.InvalidComposeSyntax;
    for (services.items) |s| {
        if (s.image.len == 0) return ComposeError.MissingServiceImage;
        try pod.validateResourceRef(s.image);
        if (s.network_mode != null and s.networks.len > 0) return ComposeError.InvalidComposeSyntax;
        for (s.networks) |net_name| {
            var declared = false;
            for (networks.items) |n| {
                if (std.mem.eql(u8, n.name, net_name)) {
                    declared = true;
                    break;
                }
            }
            if (!declared) return ComposeError.InvalidComposeSyntax;
        }
    }

    const svc_slice = try services.toOwnedSlice(alloc);
    errdefer {
        for (svc_slice) |*s| s.deinit(alloc);
        alloc.free(svc_slice);
    }
    const net_slice = try networks.toOwnedSlice(alloc);
    return .{
        .project = project,
        .base_dir = base_dir,
        .services = svc_slice,
        .networks = net_slice,
    };
}

fn isServiceListKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "ports") or
        std.mem.eql(u8, key, "volumes") or
        std.mem.eql(u8, key, "environment") or
        std.mem.eql(u8, key, "env_file") or
        std.mem.eql(u8, key, "labels") or
        std.mem.eql(u8, key, "depends_on") or
        std.mem.eql(u8, key, "networks") or
        std.mem.eql(u8, key, "cap_drop") or
        std.mem.eql(u8, key, "cap_add") or
        std.mem.eql(u8, key, "command") or
        std.mem.eql(u8, key, "entrypoint");
}

fn applyServiceListItem(alloc: std.mem.Allocator, svc: *ComposeService, key: []const u8, item: []const u8) !void {
    if (std.mem.eql(u8, key, "ports")) {
        try appendDupPort(alloc, &svc.ports, try cli_specs.parsePortSpec(item));
    } else if (std.mem.eql(u8, key, "volumes")) {
        if (parseColonPair(item) != null) return ComposeError.InvalidComposeSyntax;
        try appendDupVolume(alloc, &svc.volumes, try cli_specs.parseVolumeSpec(item));
    } else if (std.mem.eql(u8, key, "environment")) {
        if (std.mem.indexOfScalar(u8, item, '=') == null) return ComposeError.InvalidComposeSyntax;
        try appendDupStr(alloc, &svc.env, item);
    } else if (std.mem.eql(u8, key, "env_file")) {
        try appendDupStr(alloc, &svc.env_files, try cli_specs.parseEnvFilePath(item));
    } else if (std.mem.eql(u8, key, "labels")) {
        try appendDupLabel(alloc, &svc.labels, try cli_specs.parseLabelSpec(item));
    } else if (std.mem.eql(u8, key, "depends_on")) {
        try pod.validateIdentifier(item);
        try appendDupStr(alloc, &svc.depends_on, item);
    } else if (std.mem.eql(u8, key, "networks")) {
        try pod.validateIdentifier(item);
        try appendDupStr(alloc, &svc.networks, item);
    } else if (std.mem.eql(u8, key, "cap_drop")) {
        try appendDupStr(alloc, &svc.cap_drop, try cli_specs.parseCapName(item));
    } else if (std.mem.eql(u8, key, "cap_add")) {
        try appendDupStr(alloc, &svc.cap_add, try cli_specs.parseCapName(item));
    } else if (std.mem.eql(u8, key, "command")) {
        try appendDupStr(alloc, &svc.cmd, item);
    } else if (std.mem.eql(u8, key, "entrypoint")) {
        try appendDupStr(alloc, &svc.entrypoint, try cli_specs.parseEntrypoint(item));
    } else {
        return ComposeError.InvalidComposeSyntax;
    }
}

fn applyServiceMapItem(
    alloc: std.mem.Allocator,
    svc: *ComposeService,
    key: []const u8,
    sub_key: []const u8,
    sub_val_raw: []const u8,
) !void {
    const sub_val = unquoteScalar(sub_val_raw);
    if (std.mem.eql(u8, key, "environment")) {
        const kv = try std.fmt.allocPrint(alloc, "{s}={s}", .{ sub_key, sub_val });
        defer alloc.free(kv);
        try appendDupStr(alloc, &svc.env, kv);
    } else if (std.mem.eql(u8, key, "labels")) {
        try pod.validateLabel(.{ .key = sub_key, .value = sub_val });
        try appendDupLabel(alloc, &svc.labels, .{ .key = sub_key, .value = sub_val });
    } else if (std.mem.eql(u8, key, "depends_on")) {
        if (std.mem.eql(u8, sub_key, "condition")) {
            // Support long-syntax depends_on condition checks fail-closed.
            if (!std.mem.eql(u8, sub_val, "service_healthy") and
                !std.mem.eql(u8, sub_val, "service_started") and
                !std.mem.eql(u8, sub_val, "service_completed_successfully"))
            {
                return ComposeError.InvalidComposeSyntax;
            }
            return;
        }
        try pod.validateIdentifier(sub_key);
        for (svc.depends_on) |existing| {
            if (std.mem.eql(u8, existing, sub_key)) return;
        }
        try appendDupStr(alloc, &svc.depends_on, sub_key);
    } else if (std.mem.eql(u8, key, "networks")) {
        try pod.validateIdentifier(sub_key);
        try appendDupStr(alloc, &svc.networks, sub_key);
    } else {
        return ComposeError.InvalidComposeSyntax;
    }
}

fn applyServiceScalarOrFlow(alloc: std.mem.Allocator, svc: *ComposeService, key: []const u8, val_raw: []const u8) !void {
    const trimmed = std.mem.trim(u8, val_raw, " \t");
    if (trimmed.len > 0 and trimmed[0] == '{') return ComposeError.InvalidComposeSyntax;
    const val = unquoteScalar(val_raw);
    if (std.mem.eql(u8, key, "image")) {
        try pod.validateResourceRef(val);
        const img = try alloc.dupe(u8, val);
        if (svc.image.len > 0) alloc.free(svc.image);
        svc.image = img;
    } else if (std.mem.eql(u8, key, "container_name")) {
        try pod.validateIdentifier(val);
        const cn = try alloc.dupe(u8, val);
        if (svc.container_name) |old| alloc.free(old);
        svc.container_name = cn;
    } else if (std.mem.eql(u8, key, "working_dir")) {
        _ = try cli_specs.parseWorkdir(val);
        const wd = try alloc.dupe(u8, val);
        if (svc.workdir) |old| alloc.free(old);
        svc.workdir = wd;
    } else if (std.mem.eql(u8, key, "user")) {
        _ = try cli_specs.parseUserSpec(val);
        const u = try alloc.dupe(u8, val);
        if (svc.user) |old| alloc.free(old);
        svc.user = u;
    } else if (std.mem.eql(u8, key, "hostname")) {
        _ = try cli_specs.parseHostname(val);
        const h = try alloc.dupe(u8, val);
        if (svc.hostname) |old| alloc.free(old);
        svc.hostname = h;
    } else if (std.mem.eql(u8, key, "restart")) {
        const rp = try cli_specs.parseRestartPolicy(val);
        const rname = try alloc.dupe(u8, rp.name);
        if (svc.restart_name) |old| alloc.free(old);
        svc.restart_name = rname;
        svc.restart_max_retries = rp.max_retry_count;
    } else if (std.mem.eql(u8, key, "network_mode")) {
        _ = try cli_specs.parseNetworkMode(val);
        const nm = try alloc.dupe(u8, val);
        if (svc.network_mode) |old| alloc.free(old);
        svc.network_mode = nm;
    } else if (std.mem.eql(u8, key, "read_only")) {
        svc.read_only = try parseBoolScalar(val_raw);
    } else if (std.mem.eql(u8, key, "init")) {
        svc.init = try parseBoolScalar(val_raw);
    } else if (std.mem.eql(u8, key, "mem_limit")) {
        svc.mem_limit = try cli_specs.parseMemoryBytes(val);
    } else if (std.mem.eql(u8, key, "shm_size")) {
        svc.shm_size = try cli_specs.parseShmSizeBytes(val);
    } else if (std.mem.eql(u8, key, "pids_limit")) {
        svc.pids_limit = try cli_specs.parsePidsLimit(val);
    } else if (std.mem.eql(u8, key, "cpus")) {
        svc.nano_cpus = try cli_specs.parseCpuNanos(val);
    } else if (std.mem.eql(u8, key, "command")) {
        const words = try splitCommandWords(alloc, val_raw);
        ComposeService.freeStrList(alloc, svc.cmd);
        svc.cmd = words;
    } else if (std.mem.eql(u8, key, "entrypoint")) {
        const words = try splitCommandWords(alloc, val_raw);
        ComposeService.freeStrList(alloc, svc.entrypoint);
        svc.entrypoint = words;
    } else if (isServiceListKey(key)) {
        if (trimmed.len >= 2 and trimmed[0] == '[') {
            const items = try splitFlowList(alloc, val_raw);
            defer {
                for (items) |it| alloc.free(it);
                alloc.free(items);
            }
            for (items) |it| try applyServiceListItem(alloc, svc, key, it);
        } else {
            // Support single scalar values for list keys instead of dropping them silently (BUG-027).
            try applyServiceListItem(alloc, svc, key, val);
        }
    } else {
        return ComposeError.InvalidComposeSyntax;
    }
}

/// Returns service indices sorted so dependencies precede dependents.
pub fn topoSortServices(alloc: std.mem.Allocator, services: []const ComposeService) ![]usize {
    const State = enum { unvisited, visiting, visited };
    const state = try alloc.alloc(State, services.len);
    defer alloc.free(state);
    @memset(state, .unvisited);

    var order: std.ArrayList(usize) = .empty;
    errdefer order.deinit(alloc);

    const Helper = struct {
        fn visit(
            a: std.mem.Allocator,
            svcs: []const ComposeService,
            st: []State,
            ord: *std.ArrayList(usize),
            idx: usize,
        ) ComposeError!void {
            switch (st[idx]) {
                .visited => return,
                .visiting => return ComposeError.CyclicDependency,
                .unvisited => {},
            }
            st[idx] = .visiting;
            for (svcs[idx].depends_on) |dep_name| {
                var dep_idx: ?usize = null;
                for (svcs, 0..) |cand, j| {
                    if (std.mem.eql(u8, cand.name, dep_name)) {
                        dep_idx = j;
                        break;
                    }
                }
                const resolved = dep_idx orelse return ComposeError.UnknownDependency;
                try visit(a, svcs, st, ord, resolved);
            }
            st[idx] = .visited;
            ord.append(a, idx) catch return ComposeError.TooManyServices;
        }
    };

    for (0..services.len) |i| {
        try Helper.visit(alloc, services, state, &order, i);
    }
    return order.toOwnedSlice(alloc);
}

fn resolveComposeHostPath(alloc: std.mem.Allocator, base_dir: []const u8, src: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, src, "/")) return alloc.dupe(u8, src);
    if (std.mem.startsWith(u8, src, "./") or std.mem.startsWith(u8, src, "../")) {
        const joined = try std.fs.path.join(alloc, &.{ base_dir, src });
        defer alloc.free(joined);
        return std.fs.path.resolve(alloc, &.{joined});
    }
    return alloc.dupe(u8, src);
}

/// `env_file` entries are always host files: resolve any relative path against the compose dir.
fn resolveEnvFilePath(alloc: std.mem.Allocator, base_dir: []const u8, src: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, src, "/")) return alloc.dupe(u8, src);
    const joined = try std.fs.path.join(alloc, &.{ base_dir, src });
    defer alloc.free(joined);
    return std.fs.path.resolve(alloc, &.{joined});
}

fn freeResolvedVolumes(alloc: std.mem.Allocator, vols: []cli.Volume) void {
    for (vols) |v| alloc.free(v.source);
    alloc.free(vols);
}

/// Returns an owned copy of `specs` with bind-mount sources resolved against `base_dir`.
fn resolveVolumes(alloc: std.mem.Allocator, base_dir: []const u8, specs: []const cli.Volume) ![]cli.Volume {
    const out = try alloc.alloc(cli.Volume, specs.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |v| alloc.free(v.source);
        alloc.free(out);
    }
    for (specs) |v| {
        out[n] = .{
            .source = try resolveComposeHostPath(alloc, base_dir, v.source),
            .destination = v.destination,
            .readonly = v.readonly,
        };
        n += 1;
    }
    return out;
}

/// Creates a compose network; returns false if it already exists (HTTP 409).
fn ensureNetwork(client: *const http.Client, logger: *log.Logger, net: ComposeNetwork) !bool {
    try pod.validateIdentifier(net.name);
    try pod.validateNetworkDriver(net.driver);
    const body = try std.json.Stringify.valueAlloc(client.allocator, pod.NetworkCreateRequest{
        .Name = net.name,
        .Driver = net.driver,
        .Internal = net.internal,
    }, .{});
    defer client.allocator.free(body);

    const path = pod.api_prefix ++ "/networks/create";
    logger.debug("POST {s} (network={s}, body_len={d})", .{ path, net.name, body.len });
    const resp = try client.request("POST", path, body);
    defer resp.deinit();
    if (resp.status == 409) return false;
    if (!resp.ok()) return pod.validate.logApiFailure(logger, "POST", path, resp);
    return true;
}

/// Force-deletes `/{kind}/{name}`; returns false if the daemon reports HTTP 404.
fn deleteIfExists(client: *const http.Client, logger: *log.Logger, kind: []const u8, name: []const u8) !bool {
    try pod.validateIdentifier(name);
    const path = try std.fmt.allocPrint(client.allocator, "{s}/{s}/{s}?force=true", .{ pod.api_prefix, kind, name });
    defer client.allocator.free(path);
    logger.debug("DELETE {s}", .{path});
    const resp = try client.request("DELETE", path, null);
    defer resp.deinit();
    if (resp.status == 404) return false;
    if (!resp.ok()) return pod.validate.logApiFailure(logger, "DELETE", path, resp);
    return true;
}

/// Best-effort rollback of containers and newly created networks when `compose up`
/// fails midway so daemon state never stays half-applied (BUG-029).
fn rollbackComposeUp(
    client: *const http.Client,
    logger: *log.Logger,
    created_cnames: []const []const u8,
    created_nets: []const []const u8,
) void {
    var ci = created_cnames.len;
    while (ci > 0) {
        ci -= 1;
        _ = deleteIfExists(client, logger, "containers", created_cnames[ci]) catch |err| {
            logger.warn("compose rollback failed to remove container {s}: {s}", .{ created_cnames[ci], @errorName(err) });
        };
    }
    var ni = created_nets.len;
    while (ni > 0) {
        ni -= 1;
        _ = deleteIfExists(client, logger, "networks", created_nets[ni]) catch |err| {
            logger.warn("compose rollback failed to remove network {s}: {s}", .{ created_nets[ni], @errorName(err) });
        };
    }
}

/// Lists only containers labelled with this compose project.
fn listProjectContainers(
    client: *const http.Client,
    logger: *log.Logger,
    project: []const u8,
    json_mode: bool,
    stdout: anytype,
) !void {
    const alloc = client.allocator;
    const filter = try std.fmt.allocPrint(alloc, "{{\"label\":[\"com.docker.compose.project={s}\"]}}", .{project});
    defer alloc.free(filter);

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(alloc);
    try path.appendSlice(alloc, pod.api_prefix ++ "/containers/json?all=true&filters=");
    try pod.validate.appendQueryEncoded(alloc, &path, filter);

    logger.debug("GET {s}", .{path.items});
    const resp = try client.request("GET", path.items, null);
    defer resp.deinit();
    if (!resp.ok()) return pod.validate.logApiFailure(logger, "GET", path.items, resp);

    if (json_mode) {
        try stdout.print("{s}\n", .{std.mem.trim(u8, resp.body, " \r\n\t")});
        return;
    }

    const parsed = try std.json.parseFromSlice([]pod.ContainerSummary, alloc, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try stdout.print("{s:<32} {s:<28} {s}\n", .{ "NAME", "IMAGE", "STATUS" });
    for (parsed.value) |c| {
        var name: []const u8 = utils.shortId(c.Id);
        if (c.Names) |names| {
            if (names.len > 0) name = std.mem.trimStart(u8, names[0], "/");
        }
        try stdout.print("{s:<32} {s:<28} {s}\n", .{ name, c.Image, c.Status });
    }
}

pub fn executeCompose(
    client: *const http.Client,
    logger: *log.Logger,
    opts: cli.ComposeOpts,
    stdout: anytype,
) !void {
    const io = client.io;
    const alloc = client.allocator;
    var cf = try loadComposeFile(io, alloc, opts.file);
    defer cf.deinit(alloc);

    const order = try topoSortServices(alloc, cf.services);
    defer alloc.free(order);

    switch (opts.action) {
        .up => {
            var loaded_pol: ?std.json.Parsed(policy.Policy) = null;
            defer if (loaded_pol) |*lp| lp.deinit();
            const pol_opt: ?policy.Policy = if (opts.policy_path) |pp| blk: {
                loaded_pol = try policy.loadPolicyFile(io, alloc, pp);
                break :blk loaded_pol.?.value;
            } else if (opts.profile == .sandbox)
                policy.default_sandbox_policy
            else
                null;

            // Pre-flight all services before mutating daemon state.
            // Use optional slots because topological `order` populates indices out of order.
            var resolved_envs = try alloc.alloc(?pod.validate.MergedEnv, cf.services.len);
            @memset(resolved_envs, null);
            defer {
                for (resolved_envs) |*slot| {
                    if (slot.*) |*re| re.deinit();
                }
                alloc.free(resolved_envs);
            }

            var resolved_vols = try alloc.alloc(?[]cli.Volume, cf.services.len);
            @memset(resolved_vols, null);
            defer {
                for (resolved_vols) |slot| {
                    if (slot) |vols| freeResolvedVolumes(alloc, vols);
                }
                alloc.free(resolved_vols);
            }

            for (order) |idx| {
                const svc = cf.services[idx];
                var env_file_paths = try alloc.alloc([]const u8, svc.env_files.len);
                var ef_count: usize = 0;
                defer {
                    for (env_file_paths[0..ef_count]) |p| alloc.free(p);
                    alloc.free(env_file_paths);
                }
                for (svc.env_files) |ef| {
                    env_file_paths[ef_count] = try resolveEnvFilePath(alloc, cf.base_dir, ef);
                    ef_count += 1;
                }
                resolved_envs[idx] = try pod.loadAndMergeEnv(io, alloc, env_file_paths, svc.env);

                const vols = try resolveVolumes(alloc, cf.base_dir, svc.volumes);
                resolved_vols[idx] = vols;

                var run_opts = cli.RunOpts{
                    .image = svc.image,
                    .cmd = svc.cmd,
                    .env = resolved_envs[idx].?.items,
                    .volumes = vols,
                    .ports = svc.ports,
                    .labels = svc.labels,
                    .cap_drop = svc.cap_drop,
                    .cap_add = svc.cap_add,
                    .network = svc.network_mode,
                    .workdir = svc.workdir,
                    .user = svc.user,
                    .hostname = svc.hostname,
                    .restart_policy = if (svc.restart_name) |rn| .{ .name = rn, .max_retry_count = svc.restart_max_retries } else null,
                    .profile = opts.profile,
                    .read_only = svc.read_only,
                    .init = svc.init,
                    .memory = svc.mem_limit,
                    .shm_size = svc.shm_size,
                    .pids_limit = svc.pids_limit,
                    .nano_cpus = svc.nano_cpus,
                };
                if (pol_opt) |pol| {
                    if (opts.profile == .sandbox) policy.applySandboxDefaults(&run_opts);
                    if (svc.networks.len > 0) {
                        for (svc.networks) |net_name| {
                            if (!policy.isNetworkAllowed(pol, net_name)) {
                                logger.deny("policy.allowed_networks", "compose service network blocked by pre-flight policy");
                                return pod.ApiError.PolicyViolation;
                            }
                        }
                        run_opts.network = svc.networks[0];
                    }
                    if (policy.checkRunPolicy(run_opts, pol)) |rule| {
                        logger.deny(rule, "compose service blocked by pre-flight policy");
                        return pod.ApiError.PolicyViolation;
                    }
                }
            }

            var created_nets: std.ArrayList([]const u8) = .empty;
            defer created_nets.deinit(alloc);

            var created_cnames: std.ArrayList([]const u8) = .empty;
            defer {
                for (created_cnames.items) |cn| alloc.free(cn);
                created_cnames.deinit(alloc);
            }

            // Registered after buffer defers so Zig LIFO errdefer cleans daemon state first.
            errdefer rollbackComposeUp(client, logger, created_cnames.items, created_nets.items);

            for (cf.networks) |net| {
                if (try ensureNetwork(client, logger, net)) {
                    try created_nets.append(alloc, net.name);
                }
            }

            for (order) |idx| {
                const svc = cf.services[idx];
                const cname = try svc.resolvedContainerName(alloc, cf.project);
                defer alloc.free(cname);

                var mounts: std.ArrayList(pod.Mount) = .empty;
                defer mounts.deinit(alloc);
                for (resolved_vols[idx].?) |v| {
                    try mounts.append(alloc, try pod.makeMount(io, v.source, v.destination, v.readonly));
                }

                var port_list: std.ArrayList(pod.PortMapping) = .empty;
                defer port_list.deinit(alloc);
                for (svc.ports) |p| {
                    try port_list.append(alloc, try pod.makePortMapping(p.host_ip, p.host_port, p.container_port, p.proto));
                }

                var lbl_list: std.ArrayList(pod.LabelEntry) = .empty;
                defer lbl_list.deinit(alloc);
                try lbl_list.append(alloc, .{ .key = "com.docker.compose.project", .value = cf.project });
                try lbl_list.append(alloc, .{ .key = "com.docker.compose.service", .value = svc.name });
                var net_label_owned: ?[]u8 = null;
                defer if (net_label_owned) |nl| alloc.free(nl);
                if (svc.networks.len == 1) {
                    try lbl_list.append(alloc, .{ .key = "com.docker.compose.network", .value = svc.networks[0] });
                } else if (svc.networks.len > 1) {
                    net_label_owned = try std.mem.join(alloc, ",", svc.networks);
                    try lbl_list.append(alloc, .{ .key = "com.docker.compose.network", .value = net_label_owned.? });
                }
                for (svc.labels) |l| try lbl_list.append(alloc, .{ .key = l.key, .value = l.value });

                var run_opts = cli.RunOpts{
                    .image = svc.image,
                    .network = svc.network_mode,
                    .read_only = svc.read_only,
                    .init = svc.init,
                    .memory = svc.mem_limit,
                    .shm_size = svc.shm_size,
                    .pids_limit = svc.pids_limit,
                    .nano_cpus = svc.nano_cpus,
                    .cap_drop = svc.cap_drop,
                    .cap_add = svc.cap_add,
                };
                if (opts.profile == .sandbox) policy.applySandboxDefaults(&run_opts);

                const tmpfs_bounds: ?pod.TmpfsBounds = if (pol_opt) |pol| .{ .tmp_options = pol.tmpfs_tmp_options } else null;
                const env_items = resolved_envs[idx].?.items;
                const req = pod.ContainerCreateRequest{
                    .Image = svc.image,
                    .Hostname = svc.hostname,
                    .Entrypoint = if (svc.entrypoint.len > 0) svc.entrypoint else null,
                    .Cmd = if (svc.cmd.len > 0) svc.cmd else null,
                    .Env = if (env_items.len > 0) env_items else null,
                    .Labels = .{ .entries = lbl_list.items },
                    .ExposedPorts = if (port_list.items.len > 0) .{ .ports = port_list.items } else null,
                    .WorkingDir = svc.workdir,
                    .User = svc.user,
                    .Mounts = if (mounts.items.len > 0) mounts.items else null,
                    .HostConfig = .{
                        .ReadonlyRootfs = run_opts.read_only,
                        .Init = if (run_opts.init) true else null,
                        .Memory = run_opts.memory,
                        .ShmSize = run_opts.shm_size,
                        .NanoCpus = run_opts.nano_cpus,
                        .PidsLimit = run_opts.pids_limit,
                        .RestartPolicy = if (svc.restart_name) |rn| .{ .Name = rn, .MaximumRetryCount = svc.restart_max_retries } else null,
                        .SecurityOpt = if (run_opts.no_new_privileges) &.{"no-new-privileges"} else null,
                        .PortBindings = if (port_list.items.len > 0) .{ .ports = port_list.items } else null,
                        .NetworkMode = if (svc.networks.len > 0) null else run_opts.network,
                        .CapDrop = if (run_opts.cap_drop.len > 0) run_opts.cap_drop else null,
                        .CapAdd = if (run_opts.cap_add.len > 0) run_opts.cap_add else null,
                        .Tmpfs = tmpfs_bounds,
                    },
                    .NetworkingConfig = if (svc.networks.len > 0) .{
                        .EndpointsConfig = .{ .networks = svc.networks },
                    } else null,
                };

                try created_cnames.ensureUnusedCapacity(alloc, 1);
                const cname_dup = try alloc.dupe(u8, cname);
                const cid = pod.createContainer(client, logger, req, cname) catch |err| {
                    alloc.free(cname_dup);
                    return err;
                };
                defer alloc.free(cid);
                created_cnames.appendAssumeCapacity(cname_dup);
                try pod.startContainer(client, logger, cid);
                try stdout.print("{s} ({s}) started\n", .{ cname, utils.shortId(cid) });
            }
        },
        .down => {
            var rev = order.len;
            while (rev > 0) {
                rev -= 1;
                const svc = cf.services[order[rev]];
                const cname = try svc.resolvedContainerName(alloc, cf.project);
                defer alloc.free(cname);
                if (try deleteIfExists(client, logger, "containers", cname)) {
                    try stdout.print("{s} removed\n", .{cname});
                } else {
                    try stdout.print("{s} absent\n", .{cname});
                }
            }
            for (cf.networks) |net| {
                _ = try deleteIfExists(client, logger, "networks", net.name);
            }
        },
        .ps => {
            try listProjectContainers(client, logger, cf.project, opts.json, stdout);
        },
    }
}

// ---------------------------------------------------------------- tests

test "parseComposeYaml parses services, networks, maps/lists, and topoSortServices orders dependencies" {
    const alloc = std.testing.allocator;
    const yaml =
        \\name: MyApp
        \\networks:
        \\  backend:
        \\    driver: bridge
        \\    internal: true
        \\services:
        \\  api:
        \\    image: alpine:3.20
        \\    depends_on:
        \\      - db
        \\    ports:
        \\      - "8080:80"
        \\    environment:
        \\      PORT: "8080"
        \\    labels:
        \\      tier: web
        \\    cpus: "0.5"
        \\    mem_limit: 128m
        \\    shm_size: 32m
        \\    pids_limit: 32
        \\    read_only: true
        \\    init: true
        \\    restart: on-failure:2
        \\    command: ["sh", "-c", "echo ok"]
        \\  db:
        \\    image: postgres:16-alpine
        \\    volumes:
        \\      - ./pgdata:/var/lib/postgresql/data:rw
        \\
    ;
    var cf = try parseComposeYaml(alloc, yaml, "fallback", "/srv/myapp");
    defer cf.deinit(alloc);

    try std.testing.expectEqualStrings("myapp", cf.project);
    try std.testing.expectEqual(@as(usize, 1), cf.networks.len);
    try std.testing.expect(cf.networks[0].internal);
    try std.testing.expectEqual(@as(usize, 2), cf.services.len);
    try std.testing.expectEqual(@as(i64, 500_000_000), cf.services[0].nano_cpus.?);
    try std.testing.expectEqual(@as(i64, 32 * 1024 * 1024), cf.services[0].shm_size.?);
    try std.testing.expect(cf.services[0].init);
    try std.testing.expect(cf.services[0].read_only);
    try std.testing.expectEqualStrings("PORT=8080", cf.services[0].env[0]);

    const order = try topoSortServices(alloc, cf.services);
    defer alloc.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, order);
}

test "topoSortServices rejects cycles and unknown dependencies without leaking" {
    const alloc = std.testing.allocator;
    const cyclic_yaml =
        \\services:
        \\  a:
        \\    image: alpine:3.20
        \\    depends_on: [b]
        \\  b:
        \\    image: alpine:3.20
        \\    depends_on: [a]
        \\
    ;
    var cyc = try parseComposeYaml(alloc, cyclic_yaml, "p", "/tmp");
    defer cyc.deinit(alloc);
    try std.testing.expectError(ComposeError.CyclicDependency, topoSortServices(alloc, cyc.services));

    const unknown_yaml =
        \\services:
        \\  a:
        \\    image: alpine:3.20
        \\    depends_on: [missing]
        \\
    ;
    var unk = try parseComposeYaml(alloc, unknown_yaml, "p", "/tmp");
    defer unk.deinit(alloc);
    try std.testing.expectError(ComposeError.UnknownDependency, topoSortServices(alloc, unk.services));

    try std.testing.expectError(
        ComposeError.InvalidComposeSyntax,
        parseComposeYaml(alloc, "services:\n\tbad: 1\n", "p", "/tmp"),
    );
    try std.testing.expectError(
        ComposeError.MissingServiceImage,
        parseComposeYaml(alloc, "services:\n  web:\n    init: true\n", "p", "/tmp"),
    );
}

test "executeCompose up, ps, down, and sandbox pre-flight denial over mock socket" {
    const th = @import("podman_test_helpers.zig");
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "data", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "db.env", .data = "DB_PASS=secret\n" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "blocked.yaml",
        .data =
        \\name: demo
        \\services:
        \\  api:
        \\    image: alpine:3.20
        \\    depends_on: [db]
        \\    mem_limit: 512m
        \\  db:
        \\    image: postgres:16-alpine
        \\    env_file: db.env
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "compose.yaml",
        .data =
        \\name: demo
        \\networks:
        \\  back:
        \\    driver: bridge
        \\    internal: true
        \\services:
        \\  api:
        \\    image: alpine:3.20
        \\    depends_on: [db]
        \\    mem_limit: 128m
        \\  db:
        \\    image: postgres:16-alpine
        \\    env_file: db.env
        \\    volumes: ["./data:/var/lib/data:ro"]
        \\
        ,
    });

    const blocked_path = try tmp.dir.realPathFileAlloc(std.testing.io, "blocked.yaml", alloc);
    defer alloc.free(blocked_path);
    const compose_path = try tmp.dir.realPathFileAlloc(std.testing.io, "compose.yaml", alloc);
    defer alloc.free(compose_path);

    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    // 1) Pre-flight sandbox violation with out-of-order topological indices ([1, 0])
    //    must fail before touching any daemon socket and free slot 1 without crashing or leaking.
    {
        const unused_client = http.Client{ .allocator = alloc, .socket_path = "/tmp/zp-compose-unused.sock", .io = std.testing.io };
        var sink: std.Io.Writer.Allocating = .init(alloc);
        defer sink.deinit();
        try std.testing.expectError(pod.ApiError.PolicyViolation, executeCompose(&unused_client, &logger, .{
            .action = .up,
            .file = blocked_path,
            .profile = .sandbox,
        }, &sink.writer));
    }

    // 2) Full up -> ps -> down lifecycle over mock Unix socket.
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-compose-{d}.sock", .{std.Io.Clock.awake.now(std.testing.io).nanoseconds});
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const net_resp = "{\"Id\":\"net1234567890\",\"Warning\":\"\"}";
    const db_resp = "{\"Id\":\"db1234567890abcd\"}";
    const api_resp = "{\"Id\":\"api1234567890abc\"}";
    const ps_resp = "[{\"Id\":\"db1234567890abcd\",\"Names\":[\"/demo_db_1\"],\"Image\":\"postgres:16-alpine\",\"Status\":\"Up 2s\"}]";
    const err404 = "{\"message\":\"no such\"}";

    const replies = [_]th.ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/networks/create HTTP/1.1\r\n",
            .expected_substring = "\"Name\":\"back\"",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ net_resp.len, net_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo_db_1 HTTP/1.1\r\n",
            .expected_substring = "DB_PASS=secret",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ db_resp.len, db_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/db1234567890abcd/start HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo_api_1 HTTP/1.1\r\n",
            .expected_substring = "\"com.docker.compose.service\":\"api\"",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ api_resp.len, api_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/api1234567890abc/start HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "GET /v1.40/containers/json?all=true&filters=",
            .expected_substring = "com.docker.compose.project%3Ddemo",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ ps_resp.len, ps_resp },
            ),
        },
        .{
            .expected_prefix = "DELETE /v1.40/containers/demo_api_1?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "DELETE /v1.40/containers/demo_db_1?force=true HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 404 Not Found\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ err404.len, err404 },
            ),
        },
        .{
            .expected_prefix = "DELETE /v1.40/networks/back?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
    };

    var ctx = th.MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, th.runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try executeCompose(&client, &logger, .{ .action = .up, .file = compose_path }, &out.writer);
    try executeCompose(&client, &logger, .{ .action = .ps, .file = compose_path }, &out.writer);
    try executeCompose(&client, &logger, .{ .action = .down, .file = compose_path }, &out.writer);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "demo_db_1 (db1234567890) started") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "demo_api_1 (api123456789) started") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "postgres:16-alpine") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "demo_api_1 removed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "demo_db_1 absent") != null);
}

test "BUG-027: scalar list values parsed and long-syntax or unknown keys rejected" {
    const alloc = std.testing.allocator;
    const yaml =
        \\networks:
        \\  back:
        \\    driver: bridge
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    environment: FOO=bar
        \\    depends_on: db
        \\    volumes: ./data:/data:ro
        \\    networks: back
        \\    ports: 8080:80
        \\    labels: app=web
        \\    cap_drop: ALL
        \\  db:
        \\    image: postgres:16-alpine
    ;
    var cf = try parseComposeYaml(alloc, yaml, "demo", "/tmp");
    defer cf.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cf.services[0].env.len);
    try std.testing.expectEqualStrings("FOO=bar", cf.services[0].env[0]);
    try std.testing.expectEqual(@as(usize, 1), cf.services[0].depends_on.len);
    try std.testing.expectEqualStrings("db", cf.services[0].depends_on[0]);
    try std.testing.expectEqual(@as(usize, 1), cf.services[0].volumes.len);
    try std.testing.expectEqualStrings("./data", cf.services[0].volumes[0].source);
    try std.testing.expectEqualStrings("/data", cf.services[0].volumes[0].destination);
    try std.testing.expect(cf.services[0].volumes[0].readonly);
    try std.testing.expectEqual(@as(usize, 1), cf.services[0].networks.len);
    try std.testing.expectEqualStrings("back", cf.services[0].networks[0]);
    try std.testing.expectEqual(@as(usize, 1), cf.services[0].ports.len);
    try std.testing.expectEqual(@as(u16, 80), cf.services[0].ports[0].container_port);
    try std.testing.expectEqual(@as(usize, 1), cf.services[0].labels.len);
    try std.testing.expectEqualStrings("app", cf.services[0].labels[0].key);
    try std.testing.expectEqual(@as(usize, 1), cf.services[0].cap_drop.len);
    try std.testing.expectEqualStrings("ALL", cf.services[0].cap_drop[0]);

    const invalid_cases = [_][]const u8{
        // Long-syntax list-of-maps under volumes
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    volumes:
        \\      - type: bind
        \\        source: ./data
        \\        target: /data
        ,
        // Indented map keys directly under volumes
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    volumes:
        \\      source: ./data
        \\      target: /data
        ,
        // Inline flow map
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    volumes: { type: bind }
        ,
        // Unknown scalar property
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    privileged: true
        ,
        // Unknown empty block property
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    build:
        ,
        // Unknown top-level network subkey
        \\networks:
        \\  back:
        \\    ipam: custom
        \\services:
        \\  app:
        \\    image: alpine:3.20
        ,
    };
    for (invalid_cases) |bad_yaml| {
        try std.testing.expectError(ComposeError.InvalidComposeSyntax, parseComposeYaml(alloc, bad_yaml, "demo", "/tmp"));
    }
}

test "parseComposeYaml supports depends_on map syntax with conditions" {
    const alloc = std.testing.allocator;
    const yaml =
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    depends_on:
        \\      db:
        \\        condition: service_healthy
        \\  db:
        \\    image: postgres:16-alpine
    ;
    var cf = try parseComposeYaml(alloc, yaml, "demo", "/tmp");
    defer cf.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cf.services[0].depends_on.len);
    try std.testing.expectEqualStrings("db", cf.services[0].depends_on[0]);

    const order = try topoSortServices(alloc, cf.services);
    defer alloc.free(order);
    try std.testing.expectEqual(@as(usize, 1), order[0]); // db (index 1) must precede app (index 0)
    try std.testing.expectEqual(@as(usize, 0), order[1]);

    const invalid_cond_yaml =
        \\services:
        \\  app:
        \\    image: alpine:3.20
        \\    depends_on:
        \\      db:
        \\        condition: invalid_condition
        \\  db:
        \\    image: postgres:16-alpine
    ;
    try std.testing.expectError(ComposeError.InvalidComposeSyntax, parseComposeYaml(alloc, invalid_cond_yaml, "demo", "/tmp"));
}

test "BUG-028: compose service networks attach container, label network, and enforce policy" {
    const th = @import("podman_test_helpers.zig");
    const alloc = std.testing.allocator;

    // 1) Undeclared network reference & conflicting network_mode + networks must fail closed.
    const undeclared_yaml =
        \\networks:
        \\  back:
        \\    driver: bridge
        \\services:
        \\  api:
        \\    image: alpine:3.20
        \\    networks: [missing]
    ;
    try std.testing.expectError(ComposeError.InvalidComposeSyntax, parseComposeYaml(alloc, undeclared_yaml, "demo", "/tmp"));

    const conflict_yaml =
        \\networks:
        \\  back:
        \\    driver: bridge
        \\services:
        \\  api:
        \\    image: alpine:3.20
        \\    network_mode: none
        \\    networks: [back]
    ;
    try std.testing.expectError(ComposeError.InvalidComposeSyntax, parseComposeYaml(alloc, conflict_yaml, "demo", "/tmp"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "compose.yaml", .data =
        \\name: demo
        \\networks:
        \\  back:
        \\    driver: bridge
        \\services:
        \\  api:
        \\    image: alpine:3.20
        \\    networks: [back]
        \\  worker:
        \\    image: alpine:3.20
        \\    depends_on: [api]
        \\    networks: [back]
    });
    const compose_path = try std.fs.path.join(alloc, &.{ dir_path, "compose.yaml" });
    defer alloc.free(compose_path);

    var logger = log.Logger.init(std.testing.io, dir_path, false);
    defer logger.deinit();
    logger.echo_stderr = false;

    // 2) Under sandbox profile, non-allow-listed compose networks fail pre-flight before socket I/O.
    const unused_sock = try std.fs.path.join(alloc, &.{ dir_path, "unused.sock" });
    defer alloc.free(unused_sock);
    const sandbox_client = http.Client{ .allocator = alloc, .socket_path = unused_sock, .io = std.testing.io };
    var deny_out: std.Io.Writer.Allocating = .init(alloc);
    defer deny_out.deinit();
    try std.testing.expectError(
        pod.ApiError.PolicyViolation,
        executeCompose(&sandbox_client, &logger, .{ .action = .up, .file = compose_path, .profile = .sandbox }, &deny_out.writer),
    );

    // 3) In standard profile, containers receive both compose network label and NetworkingConfig.EndpointsConfig.
    const sock_path = try std.fs.path.join(alloc, &.{ dir_path, "podman.sock" });
    defer alloc.free(sock_path);
    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const net_resp = "{\"Id\":\"net123456\"}";
    const api_resp = "{\"Id\":\"api123456789000\"}";
    const wrk_resp = "{\"Id\":\"wrk123456789000\"}";
    const replies = [_]th.ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/networks/create HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ net_resp.len, net_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo_api_1 HTTP/1.1\r\n",
            .expected_substring = "\"com.docker.compose.network\":\"back\"",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ api_resp.len, api_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/api123456789000/start HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo_worker_1 HTTP/1.1\r\n",
            .expected_substring = "\"NetworkingConfig\":{\"EndpointsConfig\":{\"back\":{}}}",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ wrk_resp.len, wrk_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/wrk123456789000/start HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
    };

    var ctx = th.MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, th.runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try executeCompose(&client, &logger, .{ .action = .up, .file = compose_path }, &out.writer);
    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "BUG-029: compose up rolls back created containers and newly created networks on partial failure" {
    const th = @import("podman_test_helpers.zig");
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "compose.yaml", .data =
        \\name: demo
        \\networks:
        \\  back:
        \\    driver: bridge
        \\services:
        \\  api:
        \\    image: alpine:3.20
        \\    depends_on: [db]
        \\  db:
        \\    image: postgres:16-alpine
    });
    const compose_path = try std.fs.path.join(alloc, &.{ dir_path, "compose.yaml" });
    defer alloc.free(compose_path);

    const sock_path = try std.fs.path.join(alloc, &.{ dir_path, "podman.sock" });
    defer alloc.free(sock_path);
    const addr = try std.Io.net.UnixAddress.init(sock_path);
    var server = try addr.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    var logger = log.Logger.init(std.testing.io, dir_path, false);
    defer logger.deinit();
    logger.echo_stderr = false;

    const net_resp = "{\"Id\":\"net123456\"}";
    const db_resp = "{\"Id\":\"db123456789000\"}";
    const err_resp = "{\"message\":\"failed\"}";
    const conflict_resp = "{\"message\":\"already exists\"}";
    // Case A: service 2 fails in createContainer -> rolls back demo_db_1 and newly created `back`.
    // Case B: pre-existing network returns 409; service 1 fails in startContainer -> rolls back demo_db_1, leaves `back`.
    const replies = [_]th.ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/networks/create HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ net_resp.len, net_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo_db_1 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ db_resp.len, db_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/db123456789000/start HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo_api_1 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ err_resp.len, err_resp },
            ),
        },
        .{
            .expected_prefix = "DELETE /v1.40/containers/demo_db_1?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "DELETE /v1.40/networks/back?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
        .{
            .expected_prefix = "POST /v1.40/networks/create HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 409 Conflict\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ conflict_resp.len, conflict_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/create?name=demo_db_1 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ db_resp.len, db_resp },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/containers/db123456789000/start HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ err_resp.len, err_resp },
            ),
        },
        .{
            .expected_prefix = "DELETE /v1.40/containers/demo_db_1?force=true HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 204 No Content\r\n\r\n",
        },
    };

    var ctx = th.MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, th.runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try std.testing.expectError(
        pod.ApiError.PodmanApiError,
        executeCompose(&client, &logger, .{ .action = .up, .file = compose_path }, &out.writer),
    );
    try std.testing.expectError(
        pod.ApiError.PodmanApiError,
        executeCompose(&client, &logger, .{ .action = .up, .file = compose_path }, &out.writer),
    );
    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "BUG-043: parseComposeYaml rejects invalid image references" {
    const alloc = std.testing.allocator;
    const bad_yaml1 =
        \\services:
        \\  app:
        \\    image: "alpine;rm -rf /"
    ;
    try std.testing.expectError(pod.ApiError.InvalidIdentifier, parseComposeYaml(alloc, bad_yaml1, "demo", "/tmp"));

    const bad_yaml2 =
        \\services:
        \\  app:
        \\    image: "web/../../etc/shadow"
    ;
    try std.testing.expectError(pod.ApiError.InvalidIdentifier, parseComposeYaml(alloc, bad_yaml2, "demo", "/tmp"));
}

test "BUG-044: appendDupPort, appendDupVolume, appendDupLabel OOM handling does not double free" {
    const port_template = cli.PortMapping{
        .host_ip = "127.0.0.1",
        .host_port = 8080,
        .container_port = 80,
        .proto = "tcp",
    };
    var fail_idx: usize = 0;
    while (fail_idx < 6) : (fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_idx });
        const alloc = fa.allocator();
        var ports: []cli.PortMapping = &.{};

        appendDupPort(alloc, &ports, port_template) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        for (ports) |p| {
            if (p.host_ip) |ip| alloc.free(ip);
            alloc.free(p.proto);
        }
        alloc.free(ports);
    }

    const vol_template = cli.Volume{
        .source = "/tmp/data",
        .destination = "/data",
        .readonly = true,
    };
    fail_idx = 0;
    while (fail_idx < 6) : (fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_idx });
        const alloc = fa.allocator();
        var vols: []cli.Volume = &.{};

        appendDupVolume(alloc, &vols, vol_template) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        for (vols) |v| {
            alloc.free(v.source);
            alloc.free(v.destination);
        }
        alloc.free(vols);
    }

    const label_template = cli.Label{
        .key = "app",
        .value = "web",
    };
    fail_idx = 0;
    while (fail_idx < 6) : (fail_idx += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_idx });
        const alloc = fa.allocator();
        var labels: []cli.Label = &.{};

        appendDupLabel(alloc, &labels, label_template) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        for (labels) |l| {
            alloc.free(l.key);
            alloc.free(l.value);
        }
        alloc.free(labels);
    }
}
