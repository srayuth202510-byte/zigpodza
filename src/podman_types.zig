//! Podman / Docker-compatible REST API (v1.40) request/response schemas and errors.
const std = @import("std");

pub const ApiError = error{
    PodmanApiError,
    NotFound,
    InvalidIdentifier,
    InvalidHostPath,
    InvalidMountTarget,
    InvalidPort,
    InvalidNetwork,
    InvalidWorkdir,
    InvalidUser,
    InvalidCapability,
    InvalidSignal,
    InvalidCpuLimit,
    InvalidHostname,
    InvalidRestartPolicy,
    InvalidLabel,
    InvalidNetworkDriver,
    InvalidEnvFile,
    InvalidShmSize,
    InvalidUlimit,
    InvalidHealthcheck,
    InvalidTimeout,
    InvalidFilter,
    InvalidFormat,
    InvalidBuildArg,
    InvalidDockerfilePath,
    InvalidBuildTarget,
    InvalidDns,
    InvalidExtraHost,
    InvalidPlatform,
    PolicyViolation,
    InvalidPolicyFile,
    BuildFailed,
    BuildContextTooLarge,
    MissingDockerfile,
};

/// Serializes Docker `HostConfig.Tmpfs` mapping `/tmp` to bounded mount options:
/// `{"/tmp":"rw,noexec,nosuid,nodev,size=67108864"}`.
pub const TmpfsBounds = struct {
    tmp_options: []const u8,

    pub fn jsonStringify(self: TmpfsBounds, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("/tmp");
        try jw.write(self.tmp_options);
        try jw.endObject();
    }
};

pub const RestartPolicy = struct {
    Name: []const u8,
    MaximumRetryCount: u32 = 0,
};

pub const Ulimit = struct {
    Name: []const u8,
    Soft: i64,
    Hard: i64,
};

pub const HealthConfig = struct {
    Test: []const []const u8,
    Interval: ?i64 = null,
};

pub const HostConfig = struct {
    AutoRemove: bool = false,
    ReadonlyRootfs: bool = false,
    Init: ?bool = null,
    Memory: ?i64 = null,
    ShmSize: ?i64 = null,
    NanoCpus: ?i64 = null,
    PidsLimit: ?i64 = null,
    RestartPolicy: ?RestartPolicy = null,
    Ulimits: ?[]const Ulimit = null,
    SecurityOpt: ?[]const []const u8 = null,
    PortBindings: ?PortBindings = null,
    NetworkMode: ?[]const u8 = null,
    CapDrop: ?[]const []const u8 = null,
    CapAdd: ?[]const []const u8 = null,
    Tmpfs: ?TmpfsBounds = null,
    /// `--dns`: IP literals only.
    Dns: ?[]const []const u8 = null,
    /// `--add-host`: `host:ip` entries for /etc/hosts.
    ExtraHosts: ?[]const []const u8 = null,
};

/// A bind mount or named-volume mount, serialized into the container-create
/// request. `Type` is `"bind"` or `"volume"`; `Target` is the in-container path.
pub const Mount = struct {
    Type: []const u8,
    Source: []const u8,
    Target: []const u8,
    ReadOnly: bool = true,
};

/// A validated port mapping. `host_ip`/`host_port` are null when only a
/// container port is exposed.
pub const PortMapping = struct {
    host_ip: ?[]const u8 = null,
    host_port: ?u16 = null,
    container_port: u16,
    proto: []const u8 = "tcp",
};

/// Validates port protocol allow-list shared with `podman_validate.validatePortMapping`.
pub fn isValidPortProto(proto: []const u8) bool {
    return std.mem.eql(u8, proto, "tcp") or std.mem.eql(u8, proto, "udp") or std.mem.eql(u8, proto, "sctp");
}

fn writePortObjectField(jw: anytype, p: PortMapping) !void {
    // BUG-034: port keys can exceed any fixed buffer, so stream the
    // JSON-escaped key directly through the raw field writer (arbitrary
    // lengths are safe and no allocator is required).
    try jw.beginObjectFieldRaw();
    try jw.writer.writeAll("\"");
    try jw.writer.print("{d}/", .{p.container_port});
    for (p.proto) |c| {
        switch (c) {
            '"', '\\' => {
                try jw.writer.writeAll("\\");
                try jw.writer.writeAll(&.{c});
            },
            else => try jw.writer.writeAll(&.{c}),
        }
    }
    try jw.writer.writeAll("\"");
    jw.endObjectFieldRaw();
}

/// Serializes the Docker `ExposedPorts` object: `{"80/tcp":{},...}`.
pub const ExposedPorts = struct {
    ports: []const PortMapping,

    pub fn jsonStringify(self: ExposedPorts, jw: anytype) !void {
        try jw.beginObject();
        for (self.ports) |p| {
            try writePortObjectField(jw, p);
            try jw.beginObject();
            try jw.endObject();
        }
        try jw.endObject();
    }
};

/// Serializes the Docker `HostConfig.PortBindings` object, skipping entries
/// without an explicit host port: `{"80/tcp":[{"HostPort":"8080"}],...}`.
pub const PortBindings = struct {
    ports: []const PortMapping,

    pub fn jsonStringify(self: PortBindings, jw: anytype) !void {
        try jw.beginObject();
        for (self.ports) |p| {
            const host_port = p.host_port orelse continue;
            try writePortObjectField(jw, p);
            try jw.beginArray();
            try jw.beginObject();
            if (p.host_ip) |ip| {
                try jw.objectField("HostIp");
                try jw.write(ip);
            }
            try jw.objectField("HostPort");
            try jw.print("\"{d}\"", .{host_port});
            try jw.endObject();
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const LabelEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Serializes Docker `ContainerCreateRequest.Labels` object: `{"k":"v",...}`.
pub const LabelsMap = struct {
    entries: []const LabelEntry,

    pub fn jsonStringify(self: LabelsMap, jw: anytype) !void {
        try jw.beginObject();
        for (self.entries) |entry| {
            try jw.objectField(entry.key);
            try jw.write(entry.value);
        }
        try jw.endObject();
    }
};

/// Serializes Docker/Podman `NetworkingConfig.EndpointsConfig` mapping each
/// attached network name to `{}` so containers join user-defined compose
/// networks without weakening `HostConfig.NetworkMode`.
pub const NetworkEndpointsMap = struct {
    networks: []const []const u8,

    pub fn jsonStringify(self: NetworkEndpointsMap, jw: anytype) !void {
        try jw.beginObject();
        for (self.networks) |net_name| {
            try jw.objectField(net_name);
            try jw.beginObject();
            try jw.endObject();
        }
        try jw.endObject();
    }
};

pub const NetworkingConfig = struct {
    EndpointsConfig: NetworkEndpointsMap,
};

pub const ContainerCreateRequest = struct {
    Image: []const u8,
    Hostname: ?[]const u8 = null,
    Entrypoint: ?[]const []const u8 = null,
    Cmd: ?[]const []const u8 = null,
    Env: ?[]const []const u8 = null,
    Labels: ?LabelsMap = null,
    ExposedPorts: ?ExposedPorts = null,
    WorkingDir: ?[]const u8 = null,
    User: ?[]const u8 = null,
    Healthcheck: ?HealthConfig = null,
    AttachStdin: bool = false,
    AttachStdout: bool = false,
    AttachStderr: bool = false,
    OpenStdin: bool = false,
    Tty: bool = false,
    Mounts: ?[]const Mount = null,
    /// `--stop-timeout` seconds (0..3600).
    StopTimeout: ?i64 = null,
    HostConfig: ?HostConfig = null,
    NetworkingConfig: ?NetworkingConfig = null,
};

pub const CreateResponse = struct {
    Id: []const u8,
    Warnings: ?[]const []const u8 = null,
};

pub const ContainerSummary = struct {
    Id: []const u8,
    Image: []const u8 = "",
    Command: []const u8 = "",
    Status: []const u8 = "",
    State: []const u8 = "",
    Names: ?[]const []const u8 = null,
};

pub const ImageSummary = struct {
    Id: []const u8,
    RepoTags: ?[]const []const u8 = null,
    Size: i64 = 0,
    Created: i64 = 0,
};

/// One entry of `GET /images/search?term=...`.
pub const ImageSearchItem = struct {
    Description: []const u8 = "",
    IsOfficial: bool = false,
    Name: []const u8 = "",
    StarCount: i64 = 0,
};

pub const WaitResponse = struct {
    StatusCode: i64 = 0,
};

pub const VersionInfo = struct {
    Version: []const u8 = "unknown",
    ApiVersion: []const u8 = "unknown",
    Os: []const u8 = "unknown",
    Arch: []const u8 = "unknown",
};

/// Subset of `GET /containers/{id}/json` rendered by `zigpod inspect`.
pub const ContainerInspect = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Image: []const u8 = "",
    Created: []const u8 = "",
    State: ?ContainerInspectState = null,
    Config: ?ContainerInspectConfig = null,
    HostConfig: ?HostConfigView = null,
    NetworkSettings: ?ContainerInspectNetworkSettings = null,
    Mounts: ?[]const MountView = null,

    pub const ContainerInspectState = struct {
        Status: []const u8 = "",
        Running: bool = false,
        ExitCode: i64 = 0,
        StartedAt: []const u8 = "",
        FinishedAt: []const u8 = "",
    };

    pub const ContainerInspectConfig = struct {
        Image: []const u8 = "",
        WorkingDir: []const u8 = "",
        User: []const u8 = "",
    };

    pub const HostConfigView = struct {
        AutoRemove: bool = false,
        ReadonlyRootfs: bool = false,
        Memory: i64 = 0,
        PidsLimit: i64 = 0,
        NetworkMode: []const u8 = "",
        SecurityOpt: ?[]const []const u8 = null,
        CapAdd: ?[]const []const u8 = null,
        CapDrop: ?[]const []const u8 = null,
    };

    pub const ContainerInspectNetworkSettings = struct {
        IPAddress: []const u8 = "",
        Networks: ?std.json.Value = null,
        Ports: ?std.json.Value = null,
    };

    pub const MountView = struct {
        Type: []const u8 = "",
        Source: []const u8 = "",
        Destination: []const u8 = "",
        RW: bool = false,
    };
};

/// Subset of `GET /images/{name}/json` rendered by `zigpod inspect`.
pub const ImageInspect = struct {
    Id: []const u8 = "",
    RepoTags: ?[]const []const u8 = null,
    Size: i64 = 0,
    Created: []const u8 = "",
    Os: []const u8 = "",
    Architecture: []const u8 = "",
};

/// Body for `POST /containers/{id}/exec`.
pub const ExecCreateRequest = struct {
    AttachStdin: bool = false,
    AttachStdout: bool = true,
    AttachStderr: bool = true,
    Tty: bool = false,
    Cmd: []const []const u8,
    Env: ?[]const []const u8 = null,
    WorkingDir: ?[]const u8 = null,
    User: ?[]const u8 = null,
};

pub const ExecCreateResponse = struct {
    Id: []const u8 = "",
    Warnings: ?[]const []const u8 = null,
};

pub const ExecStartRequest = struct {
    Detach: bool = false,
    Tty: bool = false,
};

pub const ExecInspect = struct {
    Running: bool = false,
    ExitCode: i64 = 0,
};

pub const PullStatusLine = struct {
    status: ?[]const u8 = null,
    id: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Subset of `GET /containers/{id}/stats?stream=false` rendered by `zigpod stats`.
pub const ContainerStats = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    cpu_stats: ?CpuStats = null,
    precpu_stats: ?CpuStats = null,
    memory_stats: ?MemoryStats = null,
    pids_stats: ?PidsStats = null,

    pub const CpuStats = struct {
        cpu_usage: ?CpuUsage = null,
        system_cpu_usage: ?u64 = null,
        online_cpus: ?u32 = null,
    };

    pub const CpuUsage = struct {
        total_usage: ?u64 = null,
        percpu_usage: ?[]const u64 = null,
    };

    pub const MemoryStats = struct {
        usage: ?u64 = null,
        limit: ?u64 = null,
        stats: ?MemoryDetail = null,
    };

    pub const MemoryDetail = struct {
        cache: ?u64 = null,
        inactive_file: ?u64 = null,
    };

    pub const PidsStats = struct {
        current: ?u64 = null,
    };
};

/// Response from `GET /containers/{id}/top`.
pub const ContainerTop = struct {
    Titles: ?[]const []const u8 = null,
    Processes: ?[]const []const []const u8 = null,
};

/// Request body for `POST /volumes/create`.
pub const VolumeCreateRequest = struct {
    Name: []const u8,
    Driver: []const u8 = "local",
};

/// Volume metadata returned by `/volumes/create`, `/volumes/{name}`, and `/volumes`.
pub const VolumeInfo = struct {
    Name: []const u8 = "",
    Driver: []const u8 = "local",
    Mountpoint: []const u8 = "",
    CreatedAt: []const u8 = "",
};

/// Response wrapper for `GET /volumes` (`{"Volumes":[...]}`).
pub const VolumeListResponse = struct {
    Volumes: ?[]const VolumeInfo = null,
};

/// Network metadata returned by `GET /networks` and `GET /networks/{name}`.
pub const NetworkInfo = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Driver: []const u8 = "",
    Scope: []const u8 = "local",
    Internal: bool = false,
};

/// Request body for `POST /networks/create`.
pub const NetworkCreateRequest = struct {
    Name: []const u8,
    Driver: []const u8 = "bridge",
    Internal: bool = false,
    CheckDuplicate: bool = true,
};

/// Response body from `POST /networks/create`.
pub const NetworkCreateResponse = struct {
    Id: []const u8 = "",
    Warning: []const u8 = "",
};

/// Response from `GET /system/df`.
pub const SystemDfResponse = struct {
    LayersSize: i64 = 0,
    Images: ?[]const ImageSummary = null,
    Containers: ?[]const DfContainer = null,
    Volumes: ?[]const DfVolume = null,

    pub const DfContainer = struct {
        Id: []const u8 = "",
        State: []const u8 = "",
        SizeRw: i64 = 0,
        SizeRootFs: i64 = 0,
    };

    pub const DfVolume = struct {
        Name: []const u8 = "",
        UsageData: ?UsageData = null,
    };

    pub const UsageData = struct {
        Size: i64 = 0,
        RefCount: i64 = 0,
    };
};

/// Response from `POST /containers/prune`.
pub const ContainerPruneResponse = struct {
    ContainersDeleted: ?[]const []const u8 = null,
    SpaceReclaimed: u64 = 0,
};

pub const ImagePruneItem = struct {
    Untagged: ?[]const u8 = null,
    Deleted: ?[]const u8 = null,
};

/// Response from `POST /images/prune`.
pub const ImagePruneResponse = struct {
    ImagesDeleted: ?[]const ImagePruneItem = null,
    SpaceReclaimed: u64 = 0,
};

/// Response from `POST /volumes/prune`.
pub const VolumePruneResponse = struct {
    VolumesDeleted: ?[]const []const u8 = null,
    SpaceReclaimed: u64 = 0,
};

/// Response from `POST /networks/prune`.
pub const NetworkPruneResponse = struct {
    NetworksDeleted: ?[]const []const u8 = null,
};

/// Normalized JSON telemetry entry emitted by `zigpod stats --json`.
pub const StatsJsonEntry = struct {
    id: []const u8,
    name: []const u8,
    cpu_percent: f64,
    mem_used_bytes: u64,
    mem_limit_bytes: u64,
    mem_percent: f64,
    pids: u64,
};

/// Single entry from `GET /containers/{id}/changes` (`zigpod diff`).
/// Kind: 0 = Modified (C), 1 = Added (A), 2 = Deleted (D).
pub const ContainerDiffItem = struct {
    Path: []const u8 = "",
    Kind: u8 = 0,
};

/// Subset of a Podman/Docker daemon event JSON line from `GET /events`.
pub const DaemonEvent = struct {
    Type: []const u8 = "",
    Action: []const u8 = "",
    status: []const u8 = "",
    id: []const u8 = "",
    time: i64 = 0,
    Actor: ?DaemonEventActor = null,

    pub const DaemonEventActor = struct {
        ID: []const u8 = "",
    };
};

/// Single layer entry from `GET /images/{name}/history`.
pub const ImageHistoryItem = struct {
    Id: []const u8 = "",
    Created: i64 = 0,
    CreatedBy: []const u8 = "",
    Size: i64 = 0,
    Tags: ?[]const []const u8 = null,
    Comment: []const u8 = "",
};

/// Response from `POST /commit`.
pub const CommitResponse = struct {
    Id: []const u8 = "",
};

pub const PodCreateRequest = struct {
    name: []const u8 = "",
};

pub const PodSummary = struct {
    Id: []const u8 = "",
    Name: []const u8 = "",
    Status: []const u8 = "",
    Created: []const u8 = "",
};

/// One JSON line emitted by `POST /build` (docker stream protocol).
pub const BuildStreamEvent = struct {
    stream: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    errorDetail: ?BuildErrorDetail = null,
    aux: ?BuildAux = null,
};

pub const BuildErrorDetail = struct {
    message: []const u8 = "",
};

pub const BuildAux = struct {
    ID: []const u8 = "",
};

// ---------------------------------------------------------------- tests

fn rep(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

test "TmpfsBounds serializes via std.json.stringifyAlloc" {
    const alloc = std.testing.allocator;
    const t = TmpfsBounds{ .tmp_options = "rw,noexec,nosuid,nodev,size=67108864" };
    const json = try std.json.Stringify.valueAlloc(alloc, t, .{});
    defer alloc.free(json);
    try std.testing.expectEqualSlices(u8, "{\"/tmp\":\"rw,noexec,nosuid,nodev,size=67108864\"}", json);
}

test "ExposedPorts serializes via std.json.stringifyAlloc" {
    const alloc = std.testing.allocator;
    const ports = [_]PortMapping{
        .{ .container_port = 80, .proto = "tcp" },
        .{ .container_port = 53, .proto = "udp" },
    };
    const ep = ExposedPorts{ .ports = &ports };
    const json = try std.json.Stringify.valueAlloc(alloc, ep, .{});
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"80/tcp\":{},\"53/udp\":{}}") != null);
}

test "PortBindings serializes via std.json.stringifyAlloc and skips entries without host port" {
    const alloc = std.testing.allocator;
    const ports = [_]PortMapping{
        .{ .container_port = 3000 }, // no host port -> skipped
        .{ .host_ip = "127.0.0.1", .host_port = 9000, .container_port = 9000, .proto = "tcp" },
    };
    const pb = PortBindings{ .ports = &ports };
    const json = try std.json.Stringify.valueAlloc(alloc, pb, .{});
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"9000/tcp\":[{\"HostIp\":\"127.0.0.1\",\"HostPort\":\"9000\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "3000") == null);
}

test "ContainerCreateRequest serializes with omit-null optionals" {
    const alloc = std.testing.allocator;
    const req = ContainerCreateRequest{ .Image = "alpine:3.20" };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Image\":\"alpine:3.20\"") != null);
    // Null optionals are omitted entirely when emit_null_optional_fields is false.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Mounts\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"HostConfig\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ExposedPorts\"") == null);
}

test "ContainerCreateRequest serializes full HostConfig with all fields" {
    const alloc = std.testing.allocator;
    const cap_drop = [_][]const u8{"ALL"};
    const cap_add = [_][]const u8{"NET_ADMIN"};
    const sec_opt = [_][]const u8{"no-new-privileges"};
    const mounts = [_]Mount{
        .{ .Type = "bind", .Source = "/srv/data", .Target = "/data", .ReadOnly = true },
    };
    const ports = [_]PortMapping{
        .{ .host_port = 8080, .container_port = 80, .proto = "tcp" },
    };
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .Cmd = &.{"sh"},
        .Env = &.{"A=1"},
        .ExposedPorts = .{ .ports = &ports },
        .WorkingDir = "/work",
        .User = "1000:1000",
        .AttachStdin = true,
        .AttachStdout = true,
        .AttachStderr = true,
        .OpenStdin = true,
        .Tty = false,
        .Mounts = &mounts,
        .HostConfig = .{
            .AutoRemove = true,
            .ReadonlyRootfs = true,
            .Memory = 67_108_864,
            .PidsLimit = 32,
            .SecurityOpt = &sec_opt,
            .PortBindings = .{ .ports = &ports },
            .NetworkMode = "none",
            .CapDrop = &cap_drop,
            .CapAdd = &cap_add,
            .Tmpfs = .{ .tmp_options = "rw,noexec,nosuid,nodev,size=67108864" },
        },
    };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Image\":\"alpine:3.20\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadonlyRootfs\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Memory\":67108864") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"PidsLimit\":32") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"SecurityOpt\":[\"no-new-privileges\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NetworkMode\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"CapDrop\":[\"ALL\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"CapAdd\":[\"NET_ADMIN\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Tmpfs\":{\"/tmp\":\"rw,noexec,nosuid,nodev,size=67108864\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Mounts\":[{\"Type\":\"bind\",\"Source\":\"/srv/data\",\"Target\":\"/data\",\"ReadOnly\":true}]") != null);
}

test "Mount struct field defaults and serialization" {
    const alloc = std.testing.allocator;
    const m = Mount{ .Type = "volume", .Source = "myvol", .Target = "/vol", .ReadOnly = false };
    const json = try std.json.Stringify.valueAlloc(alloc, m, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Type\":\"volume\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Source\":\"myvol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Target\":\"/vol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ReadOnly\":false") != null);
}

test "HostConfig default values are zero/false/null" {
    const hc = HostConfig{};
    try std.testing.expect(hc.AutoRemove == false);
    try std.testing.expect(hc.ReadonlyRootfs == false);
    try std.testing.expect(hc.Init == null);
    try std.testing.expect(hc.Memory == null);
    try std.testing.expect(hc.ShmSize == null);
    try std.testing.expect(hc.PidsLimit == null);
    try std.testing.expect(hc.Ulimits == null);
    try std.testing.expect(hc.SecurityOpt == null);
    try std.testing.expect(hc.PortBindings == null);
    try std.testing.expect(hc.NetworkMode == null);
    try std.testing.expect(hc.CapDrop == null);
    try std.testing.expect(hc.CapAdd == null);
    try std.testing.expect(hc.Tmpfs == null);
}

test "ContainerCreateRequest serializes ShmSize, Ulimits, Init, and Healthcheck" {
    const alloc = std.testing.allocator;
    const ulimits = [_]Ulimit{.{ .Name = "nofile", .Soft = 1024, .Hard = 2048 }};
    const hc_cmd = [_][]const u8{ "CMD-SHELL", "wget -qO- http://127.0.0.1/" };
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .Healthcheck = .{ .Test = &hc_cmd, .Interval = 15_000_000_000 },
        .HostConfig = .{
            .Init = true,
            .ShmSize = 64 * 1024 * 1024,
            .Ulimits = &ulimits,
        },
    };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Init\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ShmSize\":67108864") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Ulimits\":[{\"Name\":\"nofile\",\"Soft\":1024,\"Hard\":2048}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Healthcheck\":{\"Test\":[\"CMD-SHELL\",\"wget -qO- http://127.0.0.1/\"],\"Interval\":15000000000}") != null);
}

test "ContainerSummary default values" {
    const cs = ContainerSummary{ .Id = "" };
    try std.testing.expectEqualStrings("", cs.Id);
    try std.testing.expectEqualStrings("", cs.Image);
    try std.testing.expectEqualStrings("", cs.Command);
    try std.testing.expectEqualStrings("", cs.Status);
    try std.testing.expectEqualStrings("", cs.State);
    try std.testing.expect(cs.Names == null);
}

test "ImageSummary default values" {
    const is_ = ImageSummary{ .Id = "" };
    try std.testing.expectEqualStrings("", is_.Id);
    try std.testing.expect(is_.RepoTags == null);
    try std.testing.expectEqual(@as(i64, 0), is_.Size);
    try std.testing.expectEqual(@as(i64, 0), is_.Created);
}

test "WaitResponse default and parsed status code" {
    const alloc = std.testing.allocator;
    const wr = WaitResponse{ .StatusCode = 0 };
    try std.testing.expectEqual(@as(i64, 0), wr.StatusCode);

    const parsed = try std.json.parseFromSlice(WaitResponse, alloc, "{\"StatusCode\":137}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 137), parsed.value.StatusCode);
}

test "VersionInfo default values" {
    const v = VersionInfo{};
    try std.testing.expectEqualStrings("unknown", v.Version);
    try std.testing.expectEqualStrings("unknown", v.ApiVersion);
    try std.testing.expectEqualStrings("unknown", v.Os);
    try std.testing.expectEqualStrings("unknown", v.Arch);
}

test "ExecCreateRequest default values" {
    const e = ExecCreateRequest{ .Cmd = &.{"ls"} };
    try std.testing.expect(e.AttachStdin == false);
    try std.testing.expect(e.AttachStdout == true);
    try std.testing.expect(e.AttachStderr == true);
    try std.testing.expect(e.Tty == false);
    try std.testing.expectEqualStrings("ls", e.Cmd[0]);
    try std.testing.expect(e.Env == null);
    try std.testing.expect(e.WorkingDir == null);
    try std.testing.expect(e.User == null);
}

test "ExecCreateResponse default values" {
    const e = ExecCreateResponse{};
    try std.testing.expectEqualStrings("", e.Id);
    try std.testing.expect(e.Warnings == null);
}

test "ExecInspect default values" {
    const e = ExecInspect{};
    try std.testing.expect(e.Running == false);
    try std.testing.expectEqual(@as(i64, 0), e.ExitCode);
}

test "PullStatusLine default values and error field" {
    const ps = PullStatusLine{};
    try std.testing.expect(ps.status == null);
    try std.testing.expect(ps.id == null);
    try std.testing.expect(ps.@"error" == null);

    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(PullStatusLine, alloc, "{\"status\":\"Pulling\",\"id\":\"layer1\"}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Pulling", parsed.value.status.?);
    try std.testing.expectEqualStrings("layer1", parsed.value.id.?);
    try std.testing.expect(parsed.value.@"error" == null);

    const parsed_err = try std.json.parseFromSlice(PullStatusLine, alloc, "{\"error\":\"network timeout\"}", .{ .ignore_unknown_fields = true });
    defer parsed_err.deinit();
    try std.testing.expectEqualStrings("network timeout", parsed_err.value.@"error".?);
}

test "ContainerStats nested defaults and zero stats" {
    const alloc = std.testing.allocator;
    const s = ContainerStats{};
    try std.testing.expectEqualStrings("", s.id);
    try std.testing.expectEqualStrings("", s.name);
    try std.testing.expect(s.cpu_stats == null);
    try std.testing.expect(s.memory_stats == null);
    try std.testing.expect(s.pids_stats == null);

    // All-zero stats must not panic.
    const zero = ContainerStats{
        .cpu_stats = .{
            .cpu_usage = .{ .total_usage = 0 },
            .system_cpu_usage = 0,
            .online_cpus = 0,
        },
        .precpu_stats = .{
            .cpu_usage = .{ .total_usage = 0 },
            .system_cpu_usage = 0,
        },
        .memory_stats = .{ .usage = 0, .limit = 0, .stats = null },
        .pids_stats = .{ .current = 0 },
    };
    // cpu: cur_total <= pre_total => 0.0
    // mem: limit == 0 => 0.0
    try std.testing.expectEqual(@as(f64, 0.0), @import("podman_logs.zig").computeCpuPercent(zero));
    const mem = @import("podman_logs.zig").computeMemoryUsage(zero.memory_stats);
    try std.testing.expectEqual(@as(u64, 0), mem.used);
    try std.testing.expectEqual(@as(u64, 0), mem.limit);
    try std.testing.expectEqual(@as(f64, 0.0), mem.percent);
    _ = alloc;
}

test "ContainerTop default values" {
    const ct = ContainerTop{};
    try std.testing.expect(ct.Titles == null);
    try std.testing.expect(ct.Processes == null);
}

test "VolumeCreateRequest defaults" {
    const vcr = VolumeCreateRequest{ .Name = "app-data" };
    try std.testing.expectEqualStrings("app-data", vcr.Name);
    try std.testing.expectEqualStrings("local", vcr.Driver);
}

test "VolumeInfo defaults" {
    const vi = VolumeInfo{};
    try std.testing.expectEqualStrings("", vi.Name);
    try std.testing.expectEqualStrings("local", vi.Driver);
    try std.testing.expectEqualStrings("", vi.Mountpoint);
    try std.testing.expectEqualStrings("", vi.CreatedAt);
}

test "VolumeListResponse null volumes" {
    const vlr = VolumeListResponse{};
    try std.testing.expect(vlr.Volumes == null);
}

test "NetworkInfo defaults" {
    const ni = NetworkInfo{};
    try std.testing.expectEqualStrings("", ni.Id);
    try std.testing.expectEqualStrings("", ni.Name);
    try std.testing.expectEqualStrings("", ni.Driver);
    try std.testing.expectEqualStrings("local", ni.Scope);
    try std.testing.expect(ni.Internal == false);
}

test "SystemDfResponse defaults" {
    const df = SystemDfResponse{};
    try std.testing.expectEqual(@as(i64, 0), df.LayersSize);
    try std.testing.expect(df.Images == null);
    try std.testing.expect(df.Containers == null);
    try std.testing.expect(df.Volumes == null);
}

test "SystemDfResponse nested DfContainer and DfVolume defaults" {
    const dc = SystemDfResponse.DfContainer{};
    try std.testing.expectEqualStrings("", dc.Id);
    try std.testing.expectEqualStrings("", dc.State);
    try std.testing.expectEqual(@as(i64, 0), dc.SizeRw);
    try std.testing.expectEqual(@as(i64, 0), dc.SizeRootFs);

    const dv = SystemDfResponse.DfVolume{};
    try std.testing.expectEqualStrings("", dv.Name);
    try std.testing.expect(dv.UsageData == null);

    const ud = SystemDfResponse.UsageData{};
    try std.testing.expectEqual(@as(i64, 0), ud.Size);
    try std.testing.expectEqual(@as(i64, 0), ud.RefCount);
}

test "ContainerPruneResponse defaults" {
    const cpr = ContainerPruneResponse{};
    try std.testing.expect(cpr.ContainersDeleted == null);
    try std.testing.expectEqual(@as(u64, 0), cpr.SpaceReclaimed);
}

test "ImagePruneItem defaults" {
    const ipi = ImagePruneItem{};
    try std.testing.expect(ipi.Untagged == null);
    try std.testing.expect(ipi.Deleted == null);
}

test "ImagePruneResponse defaults" {
    const ipr = ImagePruneResponse{};
    try std.testing.expect(ipr.ImagesDeleted == null);
    try std.testing.expectEqual(@as(u64, 0), ipr.SpaceReclaimed);
}

test "StatsJsonEntry fields" {
    const alloc = std.testing.allocator;
    const e = StatsJsonEntry{
        .id = "abc123",
        .name = "/web",
        .cpu_percent = 42.5,
        .mem_used_bytes = 67_108_864,
        .mem_limit_bytes = 268_435_456,
        .mem_percent = 25.0,
        .pids = 12,
    };
    try std.testing.expectEqualStrings("abc123", e.id);
    try std.testing.expectEqualStrings("/web", e.name);
    try std.testing.expectApproxEqAbs(@as(f64, 42.5), e.cpu_percent, 0.001);
    try std.testing.expectEqual(@as(u64, 67_108_864), e.mem_used_bytes);
    try std.testing.expectEqual(@as(u64, 268_435_456), e.mem_limit_bytes);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), e.mem_percent, 0.001);
    try std.testing.expectEqual(@as(u64, 12), e.pids);
    _ = alloc;
}

test "ContainerDiffItem kind mapping and defaults" {
    const d0 = ContainerDiffItem{};
    try std.testing.expectEqualStrings("", d0.Path);
    try std.testing.expectEqual(@as(u8, 0), d0.Kind);

    const d1 = ContainerDiffItem{ .Path = "/etc/hosts", .Kind = 1 };
    try std.testing.expectEqualStrings("/etc/hosts", d1.Path);
    try std.testing.expectEqual(@as(u8, 1), d1.Kind);

    const d2 = ContainerDiffItem{ .Path = "/tmp/new", .Kind = 2 };
    try std.testing.expectEqualStrings("/tmp/new", d2.Path);
    try std.testing.expectEqual(@as(u8, 2), d2.Kind);
}

test "DaemonEvent defaults and Actor nested" {
    const ev = DaemonEvent{};
    try std.testing.expectEqualStrings("", ev.Type);
    try std.testing.expectEqualStrings("", ev.Action);
    try std.testing.expectEqualStrings("", ev.status);
    try std.testing.expectEqualStrings("", ev.id);
    try std.testing.expectEqual(@as(i64, 0), ev.time);
    try std.testing.expect(ev.Actor == null);

    const ev_full = DaemonEvent{
        .Type = "container",
        .Action = "start",
        .status = "start",
        .id = "web1234567890abcd",
        .time = 1700000000,
        .Actor = .{ .ID = "web1234567890abcd" },
    };
    try std.testing.expectEqualStrings("container", ev_full.Type);
    try std.testing.expectEqualStrings("start", ev_full.Action);
    try std.testing.expectEqual(@as(i64, 1700000000), ev_full.time);
    try std.testing.expect(ev_full.Actor != null);
    try std.testing.expectEqualStrings("web1234567890abcd", ev_full.Actor.?.ID);
}

test "ImageHistoryItem defaults and populated fields" {
    const ih = ImageHistoryItem{};
    try std.testing.expectEqualStrings("", ih.Id);
    try std.testing.expectEqual(@as(i64, 0), ih.Created);
    try std.testing.expectEqualStrings("", ih.CreatedBy);
    try std.testing.expectEqual(@as(i64, 0), ih.Size);
    try std.testing.expect(ih.Tags == null);
    try std.testing.expectEqualStrings("", ih.Comment);

    const alloc = std.testing.allocator;
    const tags = [_][]const u8{ "alpine:3.20", "docker.io/library/alpine:latest" };
    const ih_full = ImageHistoryItem{
        .Id = "sha256:deadbeef",
        .Created = 1700000000,
        .CreatedBy = "/bin/sh -c echo hi",
        .Size = 4096,
        .Tags = &tags,
        .Comment = "build step",
    };
    try std.testing.expectEqualStrings("sha256:deadbeef", ih_full.Id);
    try std.testing.expectEqual(@as(i64, 1700000000), ih_full.Created);
    try std.testing.expectEqualStrings("/bin/sh -c echo hi", ih_full.CreatedBy);
    try std.testing.expectEqual(@as(i64, 4096), ih_full.Size);
    try std.testing.expectEqualStrings("alpine:3.20", ih_full.Tags.?[0]);
    try std.testing.expectEqualStrings("docker.io/library/alpine:latest", ih_full.Tags.?[1]);
    try std.testing.expectEqualStrings("build step", ih_full.Comment);
    _ = alloc;
}

test "Pod types defaults and serialization" {
    const alloc = std.testing.allocator;
    const req = PodCreateRequest{ .name = "web-pod" };
    try std.testing.expectEqualStrings("web-pod", req.name);

    const summary = PodSummary{ .Id = "abc123", .Name = "web-pod", .Status = "Running", .Created = "now" };
    try std.testing.expectEqualStrings("Running", summary.Status);

    const parsed = try std.json.parseFromSlice(PodSummary, alloc, "{\"Id\":\"p1\",\"Name\":\"db-pod\",\"Status\":\"Exited\",\"Created\":\"yesterday\"}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("db-pod", parsed.value.Name);
}

test "Build stream event parses stream, error, and aux lines" {
    const alloc = std.testing.allocator;

    const stream_line = "{\"stream\":\"Step 1/2 : FROM alpine:3.20\\n\"}";
    const s = try std.json.parseFromSlice(BuildStreamEvent, alloc, stream_line, .{});
    defer s.deinit();
    try std.testing.expectEqualStrings("Step 1/2 : FROM alpine:3.20\n", s.value.stream.?);
    try std.testing.expect(s.value.@"error" == null);

    const err_line = "{\"error\":\"build failed\",\"errorDetail\":{\"message\":\"exit 1\"}}";
    const e = try std.json.parseFromSlice(BuildStreamEvent, alloc, err_line, .{});
    defer e.deinit();
    try std.testing.expectEqualStrings("build failed", e.value.@"error".?);
    try std.testing.expectEqualStrings("exit 1", e.value.errorDetail.?.message);

    const aux_line = "{\"aux\":{\"ID\":\"sha256:deadbeef\"}}";
    const a = try std.json.parseFromSlice(BuildStreamEvent, alloc, aux_line, .{});
    defer a.deinit();
    try std.testing.expectEqualStrings("sha256:deadbeef", a.value.aux.?.ID);
}

test "LabelsMap, Hostname, Entrypoint, NanoCpus, RestartPolicy, and NetworkCreateRequest serialize cleanly" {
    const alloc = std.testing.allocator;
    const labels = [_]LabelEntry{
        .{ .key = "app", .value = "api" },
        .{ .key = "tier", .value = "backend" },
    };
    const ep = [_][]const u8{"/bin/sh"};
    const req = ContainerCreateRequest{
        .Image = "alpine:3.20",
        .Hostname = "api-1.local",
        .Entrypoint = &ep,
        .Labels = .{ .entries = &labels },
        .HostConfig = .{
            .NanoCpus = 500_000_000,
            .RestartPolicy = .{ .Name = "on-failure", .MaximumRetryCount = 3 },
        },
    };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{ .emit_null_optional_fields = false });
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Hostname\":\"api-1.local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Entrypoint\":[\"/bin/sh\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Labels\":{\"app\":\"api\",\"tier\":\"backend\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NanoCpus\":500000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"RestartPolicy\":{\"Name\":\"on-failure\",\"MaximumRetryCount\":3}") != null);

    const nreq = NetworkCreateRequest{ .Name = "iso-net", .Driver = "bridge", .Internal = true };
    const njson = try std.json.Stringify.valueAlloc(alloc, nreq, .{ .emit_null_optional_fields = false });
    defer alloc.free(njson);
    try std.testing.expect(std.mem.indexOf(u8, njson, "\"Name\":\"iso-net\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, njson, "\"Internal\":true") != null);
}

test "BUG-034: ExposedPorts and PortBindings serialize oversized protos cleanly without panicking" {
    const alloc = std.testing.allocator;
    const huge_proto = rep("p", 160);
    const long_ports = [_]PortMapping{.{
        .host_port = 8080,
        .container_port = 80,
        .proto = &huge_proto,
    }};
    const pb_json = try std.json.Stringify.valueAlloc(alloc, PortBindings{ .ports = &long_ports }, .{});
    defer alloc.free(pb_json);
    try std.testing.expect(std.mem.indexOf(u8, pb_json, "80/" ++ huge_proto) != null);

    const ep_json = try std.json.Stringify.valueAlloc(alloc, ExposedPorts{ .ports = &long_ports }, .{});
    defer alloc.free(ep_json);
    try std.testing.expect(std.mem.indexOf(u8, ep_json, "80/" ++ huge_proto) != null);
}
