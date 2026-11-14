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
    PolicyViolation,
    InvalidPolicyFile,
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

pub const HostConfig = struct {
    AutoRemove: bool = false,
    ReadonlyRootfs: bool = false,
    Memory: ?i64 = null,
    PidsLimit: ?i64 = null,
    SecurityOpt: ?[]const []const u8 = null,
    PortBindings: ?PortBindings = null,
    NetworkMode: ?[]const u8 = null,
    CapDrop: ?[]const []const u8 = null,
    CapAdd: ?[]const []const u8 = null,
    Tmpfs: ?TmpfsBounds = null,
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

/// Serializes the Docker `ExposedPorts` object: `{"80/tcp":{},...}`.
pub const ExposedPorts = struct {
    ports: []const PortMapping,

    pub fn jsonStringify(self: ExposedPorts, jw: anytype) !void {
        try jw.beginObject();
        for (self.ports) |p| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}/{s}", .{ p.container_port, p.proto }) catch unreachable;
            try jw.objectField(key);
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
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}/{s}", .{ p.container_port, p.proto }) catch unreachable;
            try jw.objectField(key);
            try jw.beginArray();
            try jw.beginObject();
            if (p.host_ip) |ip| {
                try jw.objectField("HostIp");
                try jw.write(ip);
            }
            try jw.objectField("HostPort");
            var port_buf: [8]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&port_buf, "{d}", .{host_port}) catch unreachable);
            try jw.endObject();
            try jw.endArray();
        }
        try jw.endObject();
    }
};

pub const ContainerCreateRequest = struct {
    Image: []const u8,
    Cmd: ?[]const []const u8 = null,
    Env: ?[]const []const u8 = null,
    ExposedPorts: ?ExposedPorts = null,
    WorkingDir: ?[]const u8 = null,
    User: ?[]const u8 = null,
    AttachStdin: bool = false,
    AttachStdout: bool = false,
    AttachStderr: bool = false,
    OpenStdin: bool = false,
    Tty: bool = false,
    Mounts: ?[]const Mount = null,
    HostConfig: ?HostConfig = null,
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
    State: ?State = null,
    Config: ?Config = null,
    HostConfig: ?HostConfigView = null,
    NetworkSettings: ?NetworkSettings = null,
    Mounts: ?[]const MountView = null,

    pub const State = struct {
        Status: []const u8 = "",
        Running: bool = false,
        ExitCode: i64 = 0,
        StartedAt: []const u8 = "",
        FinishedAt: []const u8 = "",
    };

    pub const Config = struct {
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

    pub const NetworkSettings = struct {
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
    Actor: ?Actor = null,

    pub const Actor = struct {
        ID: []const u8 = "",
    };
};
