//! Image/container transfer endpoints: search, save, load, export, import.
//!
//! All local file paths coming from the CLI pass through the same fail-closed
//! host-path policy as bind mounts (BUG-014), and long-running tar transfers
//! use the blocking timeout instead of the short default (BUG-007).
const std = @import("std");
const http = @import("http.zig");
const log = @import("log.zig");
const validate = @import("podman_validate.zig");
const types = @import("podman_types.zig");
const build_mod = @import("podman_build.zig");
const th = @import("podman_test_helpers.zig");
const utils = @import("utils.zig");

const api_prefix = validate.api_prefix;

const ApiError = types.ApiError;
const ImageSearchItem = types.ImageSearchItem;

const validateIdentifier = validate.validateIdentifier;
const validateResourceRef = validate.validateResourceRef;
const validateHostPath = validate.validateHostPath;
const validateCpContainerPath = validate.validateCpContainerPath;
const validateTarEntryPath = validate.validateTarEntryPath;
const validateTarSymlinkTarget = validate.validateTarSymlinkTarget;
const appendQueryEncoded = validate.appendQueryEncoded;
const logApiFailure = validate.logApiFailure;

/// Upper bound for `load`/`import` request bodies held in memory.
pub const max_load_bytes: usize = 1 << 30; // 1 GiB
pub const max_cp_bytes: usize = 256 * 1024 * 1024;
const max_cp_entries: usize = 10_000;

/// Searches a registry (`GET /images/search?term=...`).
pub fn searchImages(client: *const http.Client, logger: *log.Logger, term: []const u8, writer: anytype) !void {
    if (term.len == 0 or term.len > 256) return ApiError.InvalidIdentifier;
    for (term) |c| {
        if (c < 0x20 or c == 0x7f) return ApiError.InvalidIdentifier;
    }

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(client.allocator);
    try path_buf.appendSlice(client.allocator, api_prefix ++ "/images/search?term=");
    try appendQueryEncoded(client.allocator, &path_buf, term);

    logger.debug("GET {s}", .{path_buf.items});
    const resp = try client.request("GET", path_buf.items, null);
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "GET", path_buf.items, resp);

    const parsed = try std.json.parseFromSlice([]ImageSearchItem, client.allocator, resp.body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try writer.print("{s:<36} {s:<8} {s:<10} {s}\n", .{ "NAME", "OFFICIAL", "STARS", "DESCRIPTION" });
    for (parsed.value) |item| {
        try writer.print("{s:<36} {s:<8} {d:<10} {s}\n", .{
            item.Name,
            if (item.IsOfficial) "[OK]" else "",
            item.StarCount,
            item.Description,
        });
    }
    logger.info("searched {d} result(s) for '{s}'", .{ parsed.value.len, term });
}

const OutputKind = enum {
    not_found,
    file,
    directory,
};

const ValidatedOutput = struct {
    io: std.Io,
    parent_dir: std.Io.Dir,
    basename: []const u8,
    kind: OutputKind,

    fn deinit(self: *@This()) void {
        self.parent_dir.close(self.io);
    }
};

/// Validates `out_path` lexically and against symlink escapes on both the
/// parent directory and leaf target before any daemon I/O begins (BUG-023).
fn validateOutputPath(io: std.Io, alloc: std.mem.Allocator, out_path: []const u8, allow_dir: bool) !ValidatedOutput {
    try validateHostPath(io, out_path, false);
    const parent = std.fs.path.dirname(out_path) orelse return ApiError.InvalidHostPath;
    const basename = std.fs.path.basename(out_path);
    if (basename.len == 0) return ApiError.InvalidHostPath;

    var parent_dir = std.Io.Dir.openDirAbsolute(io, parent, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return err,
        else => return ApiError.InvalidHostPath,
    };
    errdefer parent_dir.close(io);

    const real_parent = utils.realpathAlloc(io, parent_dir, ".", alloc) catch return ApiError.InvalidHostPath;
    defer alloc.free(real_parent);
    try validateHostPath(io, real_parent, false);

    // Reject symlinks (including dangling links) at the target leaf so atomic
    // creation/replacement never redirects outside the validated parent dir.
    var link_buf: [utils.max_path_bytes]u8 = undefined;
    if (parent_dir.readLink(io, basename, &link_buf)) |_| {
        return ApiError.InvalidHostPath;
    } else |err| switch (err) {
        error.FileNotFound, error.NotLink => {},
        else => return ApiError.InvalidHostPath,
    }

    var kind: OutputKind = .not_found;
    if (parent_dir.statFile(io, basename, .{})) |st| {
        if (st.kind == .file) {
            kind = .file;
        } else if (st.kind == .directory and allow_dir) {
            kind = .directory;
        } else {
            return ApiError.InvalidHostPath;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return ApiError.InvalidHostPath,
    }

    return .{ .io = io, .parent_dir = parent_dir, .basename = basename, .kind = kind };
}

const StreamOutput = struct {
    io: std.Io,
    parent_dir: std.Io.Dir,
    tmp_name: []const u8,
    file: ?std.Io.File = null,
    created_tmp: bool = false,
    written: u64 = 0,
    max_bytes: ?u64 = null,

    fn ensureOpen(self: *@This()) !void {
        if (self.file != null) return;
        self.file = try self.parent_dir.createFile(self.io, self.tmp_name, .{
            .read = true,
            .truncate = true,
            .exclusive = true,
        });
        self.created_tmp = true;
    }

    fn onChunk(self: *@This(), chunk: []const u8) anyerror!void {
        if (self.max_bytes) |limit| {
            const next_written = std.math.add(u64, self.written, chunk.len) catch return ApiError.BuildContextTooLarge;
            if (next_written > limit) return ApiError.BuildContextTooLarge;
        }
        try self.ensureOpen();
        try self.file.?.writeStreamingAll(self.io, chunk);
        self.written += chunk.len;
    }

    fn closeFile(self: *@This()) void {
        if (self.file) |f| {
            f.close(self.io);
            self.file = null;
        }
    }

    fn cleanup(self: *@This()) void {
        self.closeFile();
        if (self.created_tmp) {
            self.parent_dir.deleteFile(self.io, self.tmp_name) catch {};
            self.created_tmp = false;
        }
    }
};

fn streamTarToFile(
    client: *const http.Client,
    logger: *log.Logger,
    path: []const u8,
    out_path: []const u8,
) !u64 {
    const io = client.io;
    var out = try validateOutputPath(io, client.allocator, out_path, false);
    defer out.deinit();

    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const tmp_name = try std.fmt.allocPrint(client.allocator, ".zigpod-tmp-{s}", .{hex});
    defer client.allocator.free(tmp_name);

    var ctx = StreamOutput{
        .io = io,
        .parent_dir = out.parent_dir,
        .tmp_name = tmp_name,
    };
    defer ctx.cleanup();

    logger.debug("GET {s}", .{path});
    const resp = try client.streamRequest(
        "GET",
        path,
        null,
        http.blocking_timeout_ms,
        &ctx,
        StreamOutput.onChunk,
    );
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "GET", path, err_resp);
    }

    try ctx.ensureOpen();
    ctx.closeFile();
    try std.Io.Dir.rename(out.parent_dir, tmp_name, out.parent_dir, out.basename, io);
    ctx.created_tmp = false;
    return ctx.written;
}

/// Streams an image tarball from the daemon into a host file
/// (`GET /images/{ref}/get`).
pub fn saveImage(client: *const http.Client, logger: *log.Logger, image: []const u8, out_path: []const u8, stdout: anytype) !void {
    try validateResourceRef(image);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/images/{s}/get", .{ api_prefix, image });
    defer client.allocator.free(path);

    const written = try streamTarToFile(client, logger, path, out_path);
    try stdout.print("Saved {s} to {s}\n", .{ image, out_path });
    logger.info("saved image {s} to {s} ({d} bytes)", .{ image, out_path, written });
}

/// Streams a container rootfs tarball into a host file
/// (`GET /containers/{id}/export`).
pub fn exportContainer(client: *const http.Client, logger: *log.Logger, container: []const u8, out_path: []const u8, stdout: anytype) !void {
    try validateIdentifier(container);

    const path = try std.fmt.allocPrint(client.allocator, "{s}/containers/{s}/export", .{ api_prefix, container });
    defer client.allocator.free(path);

    const written = try streamTarToFile(client, logger, path, out_path);
    try stdout.print("Exported {s} to {s}\n", .{ container, out_path });
    logger.info("exported container {s} to {s} ({d} bytes)", .{ container, out_path, written });
}

/// Validates and opens an input tar file, resolving symlinks fail-closed and
/// ensuring the target is a regular file before reading (BUG-023).
fn openInput(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !std.Io.File {
    try validateHostPath(io, path, false);
    const real_path = utils.realpathAlloc(io, std.Io.Dir.cwd(), path, alloc) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };
    defer alloc.free(real_path);
    try validateHostPath(io, real_path, false);

    const st = std.Io.Dir.cwd().statFile(io, real_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };
    if (st.kind != .file) return ApiError.InvalidHostPath;

    const file = try std.Io.Dir.openFileAbsolute(io, real_path, .{});
    errdefer file.close(io);
    const opened_st = try file.stat(io);
    if (opened_st.kind != .file) return ApiError.InvalidHostPath;
    return file;
}

/// Reads a local tar file (bounded by `max_load_bytes`) for upload.
fn readInputFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try openInput(io, alloc, path);
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > max_load_bytes) return ApiError.BuildContextTooLarge;
    return try utils.readFileToEndAlloc(io, file, alloc, max_load_bytes);
}

fn postTarUpload(
    client: *const http.Client,
    logger: *log.Logger,
    path: []const u8,
    body: []const u8,
    stdout: anytype,
) !void {
    logger.debug("POST {s}", .{path});
    // Loading a large tar can take minutes before the daemon responds.
    const resp = try client.requestWithContentType(
        "POST",
        path,
        body,
        "application/x-tar",
        http.blocking_timeout_ms,
    );
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "POST", path, resp);

    const trimmed = std.mem.trim(u8, resp.body, " \r\n\t");
    if (trimmed.len > 0) try stdout.print("{s}\n", .{trimmed});
}

/// Uploads a local image tarball to the daemon (`POST /images/load?quiet=0`).
pub fn loadImage(client: *const http.Client, logger: *log.Logger, in_path: []const u8, stdout: anytype) !void {
    const body = try readInputFile(client.io, client.allocator, in_path);
    defer client.allocator.free(body);

    const path = api_prefix ++ "/images/load?quiet=0";
    try postTarUpload(client, logger, path, body, stdout);
    logger.info("loaded image tarball from {s}", .{in_path});
}

/// Uploads a local rootfs tarball as a new image
/// (`POST /images/load?fromSrc=-&repo=...`).
pub fn importImage(client: *const http.Client, logger: *log.Logger, in_path: []const u8, ref: []const u8, stdout: anytype) !void {
    try validateResourceRef(ref);
    const body = try readInputFile(client.io, client.allocator, in_path);
    defer client.allocator.free(body);

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(client.allocator);
    try path_buf.appendSlice(client.allocator, api_prefix ++ "/images/load?fromSrc=-&repo=");
    try appendQueryEncoded(client.allocator, &path_buf, ref);

    try postTarUpload(client, logger, path_buf.items, body, stdout);
    logger.info("imported image {s} from {s}", .{ ref, in_path });
}

fn randomHexToken(io: std.Io) [16]u8 {
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    return std.fmt.bytesToHex(rand_bytes, .lower);
}

fn buildArchiveQueryPath(
    allocator: std.mem.Allocator,
    container: []const u8,
    container_path: []const u8,
) ![]u8 {
    var path_buf: std.ArrayList(u8) = .empty;
    errdefer path_buf.deinit(allocator);
    try path_buf.appendSlice(allocator, api_prefix ++ "/containers/");
    try path_buf.appendSlice(allocator, container);
    try path_buf.appendSlice(allocator, "/archive?path=");
    try appendQueryEncoded(allocator, &path_buf, container_path);
    return try path_buf.toOwnedSlice(allocator);
}

/// Copies a local regular file or directory tree into a running/stopped
/// container (`PUT /containers/{id}/archive?path=...`).
pub fn cpToContainer(
    client: *const http.Client,
    logger: *log.Logger,
    container: []const u8,
    host_path: []const u8,
    container_dst_path: []const u8,
    stdout: anytype,
) !void {
    const io = client.io;
    try validateIdentifier(container);
    try validateCpContainerPath(container_dst_path);
    try validateHostPath(io, host_path, false);

    const real_host = utils.realpathAlloc(io, std.Io.Dir.cwd(), host_path, client.allocator) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };
    defer client.allocator.free(real_host);
    try validateHostPath(io, real_host, false);

    const basename = std.fs.path.basename(host_path);
    if (basename.len == 0 or basename.len > 100) return ApiError.InvalidHostPath;

    const st = std.Io.Dir.cwd().statFile(io, real_host, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };

    var tar_buf: std.ArrayList(u8) = .empty;
    defer tar_buf.deinit(client.allocator);

    switch (st.kind) {
        .file => {
            const file = try openInput(io, client.allocator, real_host);
            defer file.close(io);
            const fstat = try file.stat(io);
            if (fstat.size > max_cp_bytes) return ApiError.BuildContextTooLarge;
            const content = try utils.readFileToEndAlloc(io, file, client.allocator, max_cp_bytes);
            defer client.allocator.free(content);
            try build_mod.writeTarHeader(client.allocator, &tar_buf, basename, content.len, '0', "");
            try tar_buf.appendSlice(client.allocator, content);
            try build_mod.writePad(client.allocator, &tar_buf, content.len);
            try build_mod.writeTarTrailer(client.allocator, &tar_buf);
        },
        .directory => {
            try build_mod.tarDirectoryWithPrefix(io, client.allocator, real_host, basename, &tar_buf);
            if (tar_buf.items.len > max_cp_bytes) return ApiError.BuildContextTooLarge;
        },
        else => return ApiError.InvalidHostPath,
    }

    const api_path = try buildArchiveQueryPath(client.allocator, container, container_dst_path);
    defer client.allocator.free(api_path);

    logger.debug("PUT {s} ({d} tar bytes)", .{ api_path, tar_buf.items.len });
    const resp = try client.requestWithContentType(
        "PUT",
        api_path,
        tar_buf.items,
        "application/x-tar",
        http.blocking_timeout_ms,
    );
    defer resp.deinit();

    if (!resp.ok()) return logApiFailure(logger, "PUT", api_path, resp);

    try stdout.print("Copied {s} to {s}:{s}\n", .{ host_path, container, container_dst_path });
    logger.info("copied {s} to {s}:{s} ({d} tar bytes)", .{ host_path, container, container_dst_path, tar_buf.items.len });
}

const ArchiveScan = struct {
    non_root_count: usize = 0,
    single_file_only: bool = false,
    common_root: ?[]u8 = null,
    shared_root_valid: bool = true,
};

fn scanCpArchive(io: std.Io, alloc: std.mem.Allocator, tar_file: std.Io.File) !ArchiveScan {
    var read_buf: [8192]u8 = undefined;
    var file_reader = tar_file.reader(io, &read_buf);
    var name_buf: [utils.max_path_bytes]u8 = undefined;
    var link_buf: [utils.max_path_bytes]u8 = undefined;
    var iter: std.tar.Iterator = .init(&file_reader.interface, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    var scan = ArchiveScan{};
    errdefer if (scan.common_root) |cr| alloc.free(cr);

    var entry_idx: usize = 0;
    var total_unpacked: u64 = 0;
    var first_is_file = false;
    while (try iter.next()) |f| {
        entry_idx += 1;
        if (entry_idx > max_cp_entries) return ApiError.BuildContextTooLarge;

        const clean_rel = try validateTarEntryPath(f.name);
        if (clean_rel.len == 0) continue; // "." root marker

        scan.non_root_count += 1;
        switch (f.kind) {
            .file => {
                total_unpacked = std.math.add(u64, total_unpacked, f.size) catch return ApiError.BuildContextTooLarge;
                if (total_unpacked > max_cp_bytes) return ApiError.BuildContextTooLarge;
                if (scan.non_root_count == 1) first_is_file = true;
            },
            .directory => {},
            .sym_link => {
                try validateTarSymlinkTarget(clean_rel, f.link_name);
            },
        }

        const slash_idx = std.mem.indexOfScalar(u8, clean_rel, '/');
        const first_comp = if (slash_idx) |idx| clean_rel[0..idx] else clean_rel;
        if (scan.common_root == null and scan.shared_root_valid) {
            scan.common_root = try alloc.dupe(u8, first_comp);
        } else if (scan.common_root) |cr| {
            if (!std.mem.eql(u8, cr, first_comp)) {
                alloc.free(cr);
                scan.common_root = null;
                scan.shared_root_valid = false;
            }
        }
    }

    if (scan.non_root_count == 0) return ApiError.InvalidHostPath;
    scan.single_file_only = (scan.non_root_count == 1 and first_is_file);
    return scan;
}

fn rejectIfSymlink(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    var lbuf: [utils.max_path_bytes]u8 = undefined;
    if (dir.readLink(io, name, &lbuf)) |_| {
        return ApiError.InvalidHostPath;
    } else |err| switch (err) {
        error.FileNotFound, error.NotLink => {},
        else => return ApiError.InvalidHostPath,
    }
}

fn openSubDirNoSymlink(io: std.Io, root: std.Io.Dir, rel_dir: []const u8) !std.Io.Dir {
    var cur = try root.openDir(io, ".", .{});
    errdefer cur.close(io);
    if (rel_dir.len == 0) return cur;

    var it = std.mem.splitScalar(u8, rel_dir, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return ApiError.InvalidHostPath;
        try rejectIfSymlink(io, cur, comp);
        cur.createDir(io, comp, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try rejectIfSymlink(io, cur, comp);
        const next = cur.openDir(io, comp, .{}) catch return ApiError.InvalidHostPath;
        cur.close(io);
        cur = next;
    }
    return cur;
}

/// Streams exactly `f.size` bytes of the current tar entry into `dst_file`.
fn copyTarFileContents(io: std.Io, iter: *std.tar.Iterator, f: std.tar.Iterator.File, dst_file: std.Io.File) !void {
    var write_buf: [8192]u8 = undefined;
    var file_writer = dst_file.writer(io, &write_buf);
    iter.streamRemaining(f, &file_writer.interface) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEndOfStream,
        error.WriteFailed => return file_writer.err orelse error.WriteFailed,
        else => |e| return e,
    };
    file_writer.interface.flush() catch return file_writer.err orelse error.WriteFailed;
}

fn extractCpArchiveToDir(io: std.Io, tar_file: std.Io.File, dst_dir: std.Io.Dir, strip_prefix: ?[]const u8) !void {
    var read_buf: [8192]u8 = undefined;
    var file_reader = tar_file.reader(io, &read_buf);
    var name_buf: [utils.max_path_bytes]u8 = undefined;
    var link_buf: [utils.max_path_bytes]u8 = undefined;
    var iter: std.tar.Iterator = .init(&file_reader.interface, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    while (try iter.next()) |f| {
        const clean_rel = try validateTarEntryPath(f.name);
        if (clean_rel.len == 0) continue;

        var rel = clean_rel;
        if (strip_prefix) |pfx| {
            if (std.mem.eql(u8, rel, pfx)) continue;
            if (std.mem.startsWith(u8, rel, pfx) and rel.len > pfx.len and rel[pfx.len] == '/') {
                rel = rel[pfx.len + 1 ..];
                if (rel.len == 0) continue;
            }
        }
        // Re-validate symlink depth against the final stripped extraction path (BUG-026).
        if (f.kind == .sym_link) {
            try validateTarSymlinkTarget(rel, f.link_name);
        }

        const leaf = std.fs.path.basename(rel);
        const parent_rel = std.fs.path.dirname(rel) orelse "";
        var parent_dir = try openSubDirNoSymlink(io, dst_dir, parent_rel);
        defer parent_dir.close(io);

        switch (f.kind) {
            .directory => {
                try rejectIfSymlink(io, parent_dir, leaf);
                parent_dir.createDir(io, leaf, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        const st = parent_dir.statFile(io, leaf, .{}) catch return ApiError.InvalidHostPath;
                        if (st.kind != .directory) return ApiError.InvalidHostPath;
                    },
                    else => return err,
                };
                try rejectIfSymlink(io, parent_dir, leaf);
            },
            .file => {
                try rejectIfSymlink(io, parent_dir, leaf);
                const hex = randomHexToken(io);
                var tmp_buf: [32]u8 = undefined;
                const tmp_name = std.fmt.bufPrint(&tmp_buf, ".zigpod-cp-{s}", .{hex}) catch unreachable;
                var tmp_file: ?std.Io.File = try parent_dir.createFile(io, tmp_name, .{
                    .truncate = true,
                    .exclusive = true,
                });
                var cleanup_tmp = true;
                defer {
                    if (tmp_file) |tf| tf.close(io);
                    if (cleanup_tmp) parent_dir.deleteFile(io, tmp_name) catch {};
                }
                try copyTarFileContents(io, &iter, f, tmp_file.?);
                tmp_file.?.close(io);
                tmp_file = null;
                try std.Io.Dir.rename(parent_dir, tmp_name, parent_dir, leaf, io);
                cleanup_tmp = false;
            },
            .sym_link => {
                try rejectIfSymlink(io, parent_dir, leaf);
                parent_dir.deleteFile(io, leaf) catch {};
                try parent_dir.symLink(io, f.link_name, leaf, .{});
            },
        }
    }
}

/// Copies a file or directory out of a container onto the host
/// (`GET /containers/{id}/archive?path=...`) with two-pass Tar-Slip and
/// symlink-escape protections.
pub fn cpFromContainer(
    client: *const http.Client,
    logger: *log.Logger,
    container: []const u8,
    container_src_path: []const u8,
    host_dst_path: []const u8,
    stdout: anytype,
) !void {
    const io = client.io;
    try validateIdentifier(container);
    try validateCpContainerPath(container_src_path);

    var out = try validateOutputPath(io, client.allocator, host_dst_path, true);
    defer out.deinit();

    const api_path = try buildArchiveQueryPath(client.allocator, container, container_src_path);
    defer client.allocator.free(api_path);

    const hex = randomHexToken(io);
    const tmp_tar_name = try std.fmt.allocPrint(client.allocator, ".zigpod-cp-{s}.tar", .{hex});
    defer client.allocator.free(tmp_tar_name);

    var stream_ctx = StreamOutput{
        .io = io,
        .parent_dir = out.parent_dir,
        .tmp_name = tmp_tar_name,
        .max_bytes = max_cp_bytes,
    };
    defer stream_ctx.cleanup();

    logger.debug("GET {s}", .{api_path});
    const resp = try client.streamRequest(
        "GET",
        api_path,
        null,
        http.blocking_timeout_ms,
        &stream_ctx,
        StreamOutput.onChunk,
    );
    defer resp.deinit();

    if (!resp.ok()) {
        const err_resp = http.Response{
            .status = resp.status,
            .body = resp.error_body,
            .allocator = client.allocator,
        };
        return logApiFailure(logger, "GET", api_path, err_resp);
    }

    try stream_ctx.ensureOpen();
    stream_ctx.closeFile();

    const tar_file = try out.parent_dir.openFile(io, tmp_tar_name, .{});
    defer tar_file.close(io);

    const scan = try scanCpArchive(io, client.allocator, tar_file);
    defer if (scan.common_root) |cr| client.allocator.free(cr);

    if (scan.single_file_only and out.kind != .directory) {
        var read_buf: [8192]u8 = undefined;
        var file_reader = tar_file.reader(io, &read_buf);
        var name_buf: [utils.max_path_bytes]u8 = undefined;
        var link_buf: [utils.max_path_bytes]u8 = undefined;
        var iter: std.tar.Iterator = .init(&file_reader.interface, .{
            .file_name_buffer = &name_buf,
            .link_name_buffer = &link_buf,
        });
        while (try iter.next()) |f| {
            const clean_rel = try validateTarEntryPath(f.name);
            if (clean_rel.len == 0) continue;
            const out_hex = randomHexToken(io);
            const tmp_out_name = try std.fmt.allocPrint(client.allocator, ".zigpod-tmp-{s}", .{out_hex});
            defer client.allocator.free(tmp_out_name);

            var out_ctx = StreamOutput{
                .io = io,
                .parent_dir = out.parent_dir,
                .tmp_name = tmp_out_name,
            };
            defer out_ctx.cleanup();
            try out_ctx.ensureOpen();
            try copyTarFileContents(io, &iter, f, out_ctx.file.?);
            out_ctx.closeFile();
            try std.Io.Dir.rename(out.parent_dir, tmp_out_name, out.parent_dir, out.basename, io);
            out_ctx.created_tmp = false;
            break;
        }
    } else if (out.kind == .directory) {
        var dst_dir = try out.parent_dir.openDir(io, out.basename, .{});
        defer dst_dir.close(io);
        try extractCpArchiveToDir(io, tar_file, dst_dir, null);
    } else if (out.kind == .not_found) {
        const stage_hex = randomHexToken(io);
        const stage_name = try std.fmt.allocPrint(client.allocator, ".zigpod-cp-dir-{s}", .{stage_hex});
        defer client.allocator.free(stage_name);

        try out.parent_dir.createDir(io, stage_name, .default_dir);
        var delete_stage = true;
        defer if (delete_stage) out.parent_dir.deleteTree(io, stage_name) catch {};

        var stage_dir: ?std.Io.Dir = try out.parent_dir.openDir(io, stage_name, .{});
        defer if (stage_dir) |d| d.close(io);

        const strip = if (!scan.single_file_only) scan.common_root else null;
        try extractCpArchiveToDir(io, tar_file, stage_dir.?, strip);
        stage_dir.?.close(io);
        stage_dir = null;

        try std.Io.Dir.rename(out.parent_dir, stage_name, out.parent_dir, out.basename, io);
        delete_stage = false;
    } else {
        return ApiError.InvalidHostPath;
    }

    try stdout.print("Copied {s}:{s} to {s}\n", .{ container, container_src_path, host_dst_path });
    logger.info("copied {s}:{s} to {s} ({d} archive bytes)", .{
        container, container_src_path, host_dst_path, stream_ctx.written,
    });
}

// ---------------------------------------------------------------- tests

const MockApiCtx = th.MockApiCtx;
const ScriptedReply = th.ScriptedReply;
const runMockPodmanServer = th.runMockPodmanServer;

fn rep(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

test "searchImages renders table and rejects malformed terms" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-search-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const search_json =
        \\[{"Description":"A minimal container","IsOfficial":true,"Name":"alpine","StarCount":9000},{"Description":"","IsOfficial":false,"Name":"user/alpine","StarCount":3}]
    ;
    const replies = [_]ScriptedReply{.{
        .expected_prefix = "GET /v1.40/images/search?term=alpine HTTP/1.1\r\n",
        .raw_response = std.fmt.comptimePrint(
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ search_json.len, search_json },
        ),
    }};

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try searchImages(&client, &logger, "alpine", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "alpine") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "[OK]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "A minimal container") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "user/alpine") != null);

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    var e1 = false;
    searchImages(&client, &logger, "", &sink.writer) catch |e| {
        e1 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e1);
    var e2 = false;
    searchImages(&client, &logger, "a\x01b", &sink.writer) catch |e| {
        e2 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e2);
    var e3 = false;
    searchImages(&client, &logger, &rep("a", 257), &sink.writer) catch |e| {
        e3 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e3);

    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 1), ctx.matched);
}

test "saveImage and exportContainer stream tarball into host files" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-save-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(out_dir);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out.tar", .{out_dir});
    defer alloc.free(out_path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, out_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const tar_data = "TARBALL-PAYLOAD-0123456789ABCDEF";
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/images/alpine:3.20/get HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ tar_data.len, tar_data },
            ),
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/export HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ tar_data.len, tar_data },
            ),
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try saveImage(&client, &logger, "alpine:3.20", out_path, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Saved alpine:3.20") != null);

    try exportContainer(&client, &logger, "web", out_path, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Exported web") != null);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, alloc, .limited(tar_data.len + 1));
    defer alloc.free(written);
    try std.testing.expectEqualStrings(tar_data, written);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "loadImage and importImage upload tarballs and fail closed" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-load-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const in_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(in_dir);
    const in_path = try std.fmt.allocPrint(alloc, "{s}/in.tar", .{in_dir});
    defer alloc.free(in_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in.tar", .data = "UPLOAD-PAYLOAD" });

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const loaded_status = "{\"status\":\"Loaded image: alpine:3.20\"}";
    const imported_status = "{\"status\":\"Imported\"}";
    const denied_json = "{\"message\":\"denied\"}";

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/images/load?quiet=0 HTTP/1.1\r\n",
            .expected_substring = "UPLOAD-PAYLOAD",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ loaded_status.len, loaded_status },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/images/load?fromSrc=-&repo=myrepo%2Fapp%3Av2 HTTP/1.1\r\n",
            .expected_substring = "Content-Type: application/x-tar\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ imported_status.len, imported_status },
            ),
        },
        .{
            .expected_prefix = "POST /v1.40/images/load?quiet=0 HTTP/1.1\r\n",
            .raw_response = std.fmt.comptimePrint(
                "HTTP/1.1 403 Forbidden\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ denied_json.len, denied_json },
            ),
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try loadImage(&client, &logger, in_path, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Loaded image: alpine:3.20") != null);

    try importImage(&client, &logger, in_path, "myrepo/app:v2", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Imported") != null);

    var got_api_err = false;
    loadImage(&client, &logger, in_path, &out.writer) catch |e| {
        got_api_err = e == ApiError.PodmanApiError;
    };
    try std.testing.expect(got_api_err);

    // Validation paths: dangerous output/input locations and bad refs.
    var e1 = false;
    saveImage(&client, &logger, "img", "/etc/passwd", &out.writer) catch |e| {
        e1 = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e1);
    var e2 = false;
    loadImage(&client, &logger, "/root/../etc/shadow", &out.writer) catch |e| {
        e2 = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e2);
    var e3 = false;
    importImage(&client, &logger, in_path, "bad?x=1", &out.writer) catch |e| {
        e3 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e3);
    var e4 = false;
    exportContainer(&client, &logger, "a/../b", "/tmp/zp-tr-export.tar", &out.writer) catch |e| {
        e4 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e4);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "searchImages handles empty array, query encoding, 256-byte boundary, API error, and malformed JSON" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-search-edge-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const max_term = &rep("a", 256);
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/images/search?term=alpine%20linux%231 HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]",
        },
        .{
            .expected_prefix = "GET /v1.40/images/search?term=" ++ max_term ++ " HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]",
        },
        .{
            .expected_prefix = "GET /v1.40/images/search?term=badjson HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n{broken",
        },
        .{
            .expected_prefix = "GET /v1.40/images/search?term=fail HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 19\r\n\r\n{\"message\":\"boom\"} ",
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try searchImages(&client, &logger, "alpine linux#1", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "NAME") != null);

    try searchImages(&client, &logger, max_term, &out.writer);
    try std.testing.expectError(ApiError.InvalidIdentifier, searchImages(&client, &logger, "a\x7fb", &out.writer));
    try std.testing.expectError(error.UnexpectedToken, searchImages(&client, &logger, "badjson", &out.writer));
    try std.testing.expectError(ApiError.PodmanApiError, searchImages(&client, &logger, "fail", &out.writer));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "saveImage and exportContainer preserve existing files on error and block symlink escapes (BUG-023)" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-atomic-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_dir);

    const existing_path = try std.fmt.allocPrint(alloc, "{s}/keep.tar", .{tmp_dir});
    defer alloc.free(existing_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.tar", .data = "ORIGINAL-TAR" });

    const empty_out_path = try std.fmt.allocPrint(alloc, "{s}/empty.tar", .{tmp_dir});
    defer alloc.free(empty_out_path);

    try tmp.dir.symLink(std.testing.io, "/etc/hosts", "escape-leaf.tar", .{});
    const escape_leaf = try std.fmt.allocPrint(alloc, "{s}/escape-leaf.tar", .{tmp_dir});
    defer alloc.free(escape_leaf);

    try tmp.dir.symLink(std.testing.io, "/etc/nonexistent-zigpod-target", "dangling-leaf.tar", .{});
    const dangling_leaf = try std.fmt.allocPrint(alloc, "{s}/dangling-leaf.tar", .{tmp_dir});
    defer alloc.free(dangling_leaf);

    try tmp.dir.symLink(std.testing.io, "/etc", "etc-dir", .{ .is_directory = true });
    const escape_parent = try std.fmt.allocPrint(alloc, "{s}/etc-dir/out.tar", .{tmp_dir});
    defer alloc.free(escape_parent);

    try tmp.dir.createDir(std.testing.io, "subdir", .default_dir);
    const dir_target = try std.fmt.allocPrint(alloc, "{s}/subdir", .{tmp_dir});
    defer alloc.free(dir_target);

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const max_ref = &rep("r", 256);
    const max_id = &rep("c", 128);
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/images/missing/get HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 21\r\n\r\n{\"message\":\"missing\"}",
        },
        .{
            .expected_prefix = "GET /v1.40/images/truncated/get HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\npart!",
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/export HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        },
        .{
            .expected_prefix = "GET /v1.40/images/" ++ max_ref ++ "/get HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        },
        .{
            .expected_prefix = "GET /v1.40/containers/" ++ max_id ++ "/export HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // 404 failure and mid-stream EOF must leave pre-existing output file untouched.
    try std.testing.expectError(ApiError.PodmanApiError, saveImage(&client, &logger, "missing", existing_path, &out.writer));
    try std.testing.expectError(http.Error.InvalidResponse, saveImage(&client, &logger, "truncated", existing_path, &out.writer));
    const preserved = try tmp.dir.readFileAlloc(std.testing.io, "keep.tar", alloc, .limited(64));
    defer alloc.free(preserved);
    try std.testing.expectEqualStrings("ORIGINAL-TAR", preserved);

    // Chunked streaming atomically replaces keep.tar without leaving temp files.
    try exportContainer(&client, &logger, "web", existing_path, &out.writer);
    const replaced = try tmp.dir.readFileAlloc(std.testing.io, "keep.tar", alloc, .limited(64));
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("hello", replaced);

    // Empty 200 OK still creates an empty target file; boundary lengths work.
    try saveImage(&client, &logger, max_ref, empty_out_path, &out.writer);
    const empty_bytes = try tmp.dir.readFileAlloc(std.testing.io, "empty.tar", alloc, .limited(64));
    defer alloc.free(empty_bytes);
    try std.testing.expectEqual(@as(usize, 0), empty_bytes.len);

    try exportContainer(&client, &logger, max_id, empty_out_path, &out.writer);

    // Fail-closed security & boundary checks (before socket I/O).
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", escape_leaf, &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", dangling_leaf, &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, exportContainer(&client, &logger, "web", escape_parent, &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", dir_target, &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", "/root-file.tar", &out.writer));
    try std.testing.expectError(ApiError.InvalidIdentifier, saveImage(&client, &logger, &rep("r", 257), empty_out_path, &out.writer));
    try std.testing.expectError(ApiError.InvalidIdentifier, exportContainer(&client, &logger, &rep("c", 129), empty_out_path, &out.writer));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);

    // Verify no leftover .zigpod-tmp-* files remain in tmp.dir.
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".zigpod-tmp-"));
    }
}

test "loadImage and importImage reject symlink escapes, directories, missing files, and bad boundaries (BUG-023)" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-in-{d}.sock",
        .{std.Io.Clock.awake.now(std.testing.io).nanoseconds},
    );
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(tmp_dir);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rootfs.tar", .data = "ROOTFS" });
    const good_in = try std.fmt.allocPrint(alloc, "{s}/rootfs.tar", .{tmp_dir});
    defer alloc.free(good_in);

    try tmp.dir.symLink(std.testing.io, "/etc/passwd", "sym-etc", .{});
    const sym_in = try std.fmt.allocPrint(alloc, "{s}/sym-etc", .{tmp_dir});
    defer alloc.free(sym_in);

    try tmp.dir.createDir(std.testing.io, "in-dir", .default_dir);
    const dir_in = try std.fmt.allocPrint(alloc, "{s}/in-dir", .{tmp_dir});
    defer alloc.free(dir_in);

    const missing_in = try std.fmt.allocPrint(alloc, "{s}/missing.tar", .{tmp_dir});
    defer alloc.free(missing_in);

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const max_ref = &rep("r", 256);
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/images/load?fromSrc=-&repo=" ++ max_ref ++ " HTTP/1.1\r\n",
            .expected_substring = "Content-Type: application/x-tar\r\n",
            .raw_response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 17\r\n\r\n{\"message\":\"bad\"}",
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try std.testing.expectError(ApiError.InvalidHostPath, loadImage(&client, &logger, sym_in, &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, importImage(&client, &logger, sym_in, "repo:v1", &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, loadImage(&client, &logger, dir_in, &out.writer));
    try std.testing.expectError(error.FileNotFound, loadImage(&client, &logger, missing_in, &out.writer));
    try std.testing.expectError(ApiError.InvalidIdentifier, importImage(&client, &logger, good_in, &rep("r", 257), &out.writer));
    try std.testing.expectError(ApiError.PodmanApiError, importImage(&client, &logger, good_in, max_ref, &out.writer));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

fn buildTestTarBytes(alloc: std.mem.Allocator, entry_name: []const u8, payload: []const u8, kind: u8, linkname: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try build_mod.writeTarHeader(alloc, &buf, entry_name, payload.len, kind, linkname);
    if (kind == '0' and payload.len > 0) {
        try buf.appendSlice(alloc, payload);
        try build_mod.writePad(alloc, &buf, payload.len);
    }
    try build_mod.writeTarTrailer(alloc, &buf);
    return try buf.toOwnedSlice(alloc);
}

test "cpToContainer uploads files and directories and rejects unsafe inputs" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-cp-to-{d}.sock", .{std.Io.Clock.awake.now(std.testing.io).nanoseconds});
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root_dir);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "hello-cp" });
    const file_path = try std.fs.path.join(alloc, &.{ root_dir, "hello.txt" });
    defer alloc.free(file_path);

    try tmp.dir.createDir(std.testing.io, "bundle", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bundle/cfg.json", .data = "{\"ok\":true}" });
    const dir_path = try std.fs.path.join(alloc, &.{ root_dir, "bundle" });
    defer alloc.free(dir_path);

    try tmp.dir.symLink(std.testing.io, "/etc/passwd", "evil-link", .{});
    const link_path = try std.fs.path.join(alloc, &.{ root_dir, "evil-link" });
    defer alloc.free(link_path);

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "PUT /v1.40/containers/web/archive?path=%2Ftmp HTTP/1.1\r\n",
            .expected_substring = "hello-cp",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        },
        .{
            .expected_prefix = "PUT /v1.40/containers/web/archive?path=%2F HTTP/1.1\r\n",
            .expected_substring = "bundle/cfg.json",
            .raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try std.testing.expectError(ApiError.InvalidIdentifier, cpToContainer(&client, &logger, "../bad", file_path, "/tmp", &out.writer));
    try std.testing.expectError(ApiError.InvalidMountTarget, cpToContainer(&client, &logger, "web", file_path, "relative", &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, cpToContainer(&client, &logger, "web", "rel.txt", "/tmp", &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, cpToContainer(&client, &logger, "web", "/etc/passwd", "/tmp", &out.writer));
    try std.testing.expectError(ApiError.InvalidHostPath, cpToContainer(&client, &logger, "web", link_path, "/tmp", &out.writer));

    try cpToContainer(&client, &logger, "web", file_path, "/tmp", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "web:/tmp") != null);

    out.clearRetainingCapacity();
    try cpToContainer(&client, &logger, "web", dir_path, "/", &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "web:/") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "cpFromContainer unpacks safely and blocks Tar-Slip, symlink escapes, and partial overwrites" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-cp-from-{d}.sock", .{std.Io.Clock.awake.now(std.testing.io).nanoseconds});
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root_dir);

    const out_file = try std.fs.path.join(alloc, &.{ root_dir, "hosts.txt" });
    defer alloc.free(out_file);

    try tmp.dir.createDir(std.testing.io, "existing", .default_dir);
    const existing_dir = try std.fs.path.join(alloc, &.{ root_dir, "existing" });
    defer alloc.free(existing_dir);

    const out_new_dir = try std.fs.path.join(alloc, &.{ root_dir, "app_copy" });
    defer alloc.free(out_new_dir);

    const file_tar = try buildTestTarBytes(alloc, "hosts", "127.0.0.1 localhost\n", '0', "");
    defer alloc.free(file_tar);

    var dir_tar_buf: std.ArrayList(u8) = .empty;
    defer dir_tar_buf.deinit(alloc);
    try build_mod.writeTarHeader(alloc, &dir_tar_buf, "app/", 0, '5', "");
    try build_mod.writeTarHeader(alloc, &dir_tar_buf, "app/run.sh", 11, '0', "");
    try dir_tar_buf.appendSlice(alloc, "#!/bin/sh\n\n");
    try build_mod.writePad(alloc, &dir_tar_buf, 11);
    try build_mod.writeTarTrailer(alloc, &dir_tar_buf);

    const slip_tar = try buildTestTarBytes(alloc, "../escape.txt", "pwn", '0', "");
    defer alloc.free(slip_tar);

    const sym_tar = try buildTestTarBytes(alloc, "badlink", "", '2', "../outside");
    defer alloc.free(sym_tar);

    const resp_file = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ file_tar.len, file_tar });
    defer alloc.free(resp_file);
    const resp_dir = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ dir_tar_buf.items.len, dir_tar_buf.items });
    defer alloc.free(resp_dir);
    const resp_slip = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ slip_tar.len, slip_tar });
    defer alloc.free(resp_slip);
    const resp_sym = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ sym_tar.len, sym_tar });
    defer alloc.free(resp_sym);

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "GET /v1.40/containers/web/archive?path=%2Fetc%2Fhosts HTTP/1.1\r\n",
            .raw_response = resp_file,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/archive?path=%2Fapp HTTP/1.1\r\n",
            .raw_response = resp_dir,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/archive?path=%2Fapp HTTP/1.1\r\n",
            .raw_response = resp_dir,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/archive?path=%2Fslip HTTP/1.1\r\n",
            .raw_response = resp_slip,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/archive?path=%2Fsym HTTP/1.1\r\n",
            .raw_response = resp_sym,
        },
        .{
            .expected_prefix = "GET /v1.40/containers/web/archive?path=%2Fmissing HTTP/1.1\r\n",
            .raw_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot found",
        },
    };

    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // 1) Single file -> new host file
    try cpFromContainer(&client, &logger, "web", "/etc/hosts", out_file, &out.writer);
    const got_file = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_file, alloc, .limited(1024));
    defer alloc.free(got_file);
    try std.testing.expectEqualStrings("127.0.0.1 localhost\n", got_file);

    // 2) Directory -> existing host directory (keeps app/run.sh)
    try cpFromContainer(&client, &logger, "web", "/app", existing_dir, &out.writer);
    const inside_existing = try std.fs.path.join(alloc, &.{ existing_dir, "app", "run.sh" });
    defer alloc.free(inside_existing);
    const got_sh1 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, inside_existing, alloc, .limited(1024));
    defer alloc.free(got_sh1);
    try std.testing.expectEqualStrings("#!/bin/sh\n\n", got_sh1);

    // 3) Directory -> new host directory (strips common root, creates app_copy/run.sh)
    try cpFromContainer(&client, &logger, "web", "/app", out_new_dir, &out.writer);
    const inside_new = try std.fs.path.join(alloc, &.{ out_new_dir, "run.sh" });
    defer alloc.free(inside_new);
    const got_sh2 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, inside_new, alloc, .limited(1024));
    defer alloc.free(got_sh2);
    try std.testing.expectEqualStrings("#!/bin/sh\n\n", got_sh2);

    // 4) Tar-Slip ../escape.txt must fail closed without creating files
    try std.testing.expectError(ApiError.InvalidHostPath, cpFromContainer(&client, &logger, "web", "/slip", existing_dir, &out.writer));

    // 5) Symlink escape ../outside must fail closed
    try std.testing.expectError(ApiError.InvalidHostPath, cpFromContainer(&client, &logger, "web", "/sym", existing_dir, &out.writer));

    // 6) 404 from daemon must preserve pre-existing out_file untouched
    try std.testing.expectError(ApiError.PodmanApiError, cpFromContainer(&client, &logger, "web", "/missing", out_file, &out.writer));
    const still_intact = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_file, alloc, .limited(1024));
    defer alloc.free(still_intact);
    try std.testing.expectEqualStrings("127.0.0.1 localhost\n", still_intact);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "scanCpArchive rejects hardlink escapes, oversized PAX headers, and truncated tar streams" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1) Hardlink (typeflag '1') pointing outside archive root must be rejected fail-closed.
    {
        var hl_buf: std.ArrayList(u8) = .empty;
        defer hl_buf.deinit(alloc);
        var hdr: [512]u8 = @splat(0);
        @memcpy(hdr[0..4], "evil");
        @memcpy(hdr[100..107], "000644 ");
        hdr[107] = 0;
        @memcpy(hdr[108..115], "000000 ");
        hdr[115] = 0;
        @memcpy(hdr[116..123], "000000 ");
        hdr[123] = 0;
        @memcpy(hdr[124..135], "00000000000");
        hdr[135] = 0;
        @memcpy(hdr[136..147], "00000000000");
        hdr[147] = 0;
        @memset(hdr[148..156], ' ');
        hdr[156] = '1'; // hard_link
        const target = "../../etc/shadow";
        @memcpy(hdr[157 .. 157 + target.len], target);
        @memcpy(hdr[257..263], "ustar\x00");
        @memcpy(hdr[263..265], "00");
        var sum: u32 = 0;
        for (hdr) |b| sum += b;
        _ = std.fmt.bufPrint(hdr[148..154], "{o:0>6}", .{sum}) catch unreachable;
        hdr[154] = 0;
        hdr[155] = ' ';
        try hl_buf.appendSlice(alloc, &hdr);
        try build_mod.writeTarTrailer(alloc, &hl_buf);

        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hardlink.tar", .data = hl_buf.items });
        const f = try tmp.dir.openFile(std.testing.io, "hardlink.tar", .{});
        defer f.close(std.testing.io);
        try std.testing.expectError(error.TarUnsupportedHeader, scanCpArchive(std.testing.io, alloc, f));
    }

    // 2) Oversized PAX extended header (typeflag 'x' with path > MAX_PATH_BYTES) must fail.
    {
        var pax_buf: std.ArrayList(u8) = .empty;
        defer pax_buf.deinit(alloc);
        const long_path = &rep("a", utils.max_path_bytes + 64);
        const rec_body = try std.fmt.allocPrint(alloc, "path={s}\n", .{long_path});
        defer alloc.free(rec_body);
        const total_len = rec_body.len + 5; // "NNNN "
        const pax_payload = try std.fmt.allocPrint(alloc, "{d:0>4} {s}", .{ total_len, rec_body });
        defer alloc.free(pax_payload);

        var hdr: [512]u8 = @splat(0);
        @memcpy(hdr[0..10], "PaxHeader/");
        @memcpy(hdr[100..107], "000644 ");
        hdr[107] = 0;
        @memcpy(hdr[108..115], "000000 ");
        hdr[115] = 0;
        @memcpy(hdr[116..123], "000000 ");
        hdr[123] = 0;
        _ = std.fmt.bufPrint(hdr[124..135], "{o:0>11}", .{pax_payload.len}) catch unreachable;
        hdr[135] = 0;
        @memcpy(hdr[136..147], "00000000000");
        hdr[147] = 0;
        @memset(hdr[148..156], ' ');
        hdr[156] = 'x';
        @memcpy(hdr[257..263], "ustar\x00");
        @memcpy(hdr[263..265], "00");
        var sum: u32 = 0;
        for (hdr) |b| sum += b;
        _ = std.fmt.bufPrint(hdr[148..154], "{o:0>6}", .{sum}) catch unreachable;
        hdr[154] = 0;
        hdr[155] = ' ';
        try pax_buf.appendSlice(alloc, &hdr);
        try pax_buf.appendSlice(alloc, pax_payload);
        try build_mod.writePad(alloc, &pax_buf, pax_payload.len);
        try build_mod.writeTarTrailer(alloc, &pax_buf);

        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "longpax.tar", .data = pax_buf.items });
        const f = try tmp.dir.openFile(std.testing.io, "longpax.tar", .{});
        defer f.close(std.testing.io);
        try std.testing.expectError(error.TarInsufficientBuffer, scanCpArchive(std.testing.io, alloc, f));
    }

    // 3) Truncated tar stream (header declares 2048 bytes, stream ends after 64 bytes).
    {
        var trunc_buf: std.ArrayList(u8) = .empty;
        defer trunc_buf.deinit(alloc);
        try build_mod.writeTarHeader(alloc, &trunc_buf, "partial.bin", 2048, '0', "");
        try trunc_buf.appendNTimes(alloc, 'Z', 64);

        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "trunc.tar", .data = trunc_buf.items });
        const f = try tmp.dir.openFile(std.testing.io, "trunc.tar", .{});
        defer f.close(std.testing.io);
        try std.testing.expectError(error.EndOfStream, scanCpArchive(std.testing.io, alloc, f));
    }
}

test "BUG-026: cpFromContainer rejects symlink escape exposed after common-root strip" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-cp-strip-{d}.sock", .{std.Io.Clock.awake.now(std.testing.io).nanoseconds});
    defer alloc.free(sock_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root_dir);
    const out_new_dir = try std.fs.path.join(alloc, &.{ root_dir, "extracted" });
    defer alloc.free(out_new_dir);

    var tar_buf: std.ArrayList(u8) = .empty;
    defer tar_buf.deinit(alloc);
    try build_mod.writeTarHeader(alloc, &tar_buf, "wrap/", 0, '5', "");
    try build_mod.writeTarHeader(alloc, &tar_buf, "wrap/ok.txt", 3, '0', "");
    try tar_buf.appendSlice(alloc, "ok\n");
    try build_mod.writePad(alloc, &tar_buf, 3);
    try build_mod.writeTarHeader(alloc, &tar_buf, "wrap/escape", 0, '2', "../secret");
    try build_mod.writeTarTrailer(alloc, &tar_buf);

    const resp = try std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ tar_buf.items.len, tar_buf.items });
    defer alloc.free(resp);

    var server = try (try std.Io.net.UnixAddress.init(sock_path)).listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);

    const replies = [_]ScriptedReply{.{
        .expected_prefix = "GET /v1.40/containers/web/archive?path=%2Fwrap HTTP/1.1\r\n",
        .raw_response = resp,
    }};
    var ctx = MockApiCtx{ .io = std.testing.io, .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path, .io = std.testing.io };
    var logger = log.Logger{ .io = std.testing.io, .echo_stderr = false };
    defer logger.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try std.testing.expectError(
        ApiError.InvalidHostPath,
        cpFromContainer(&client, &logger, "web", "/wrap", out_new_dir, &out.writer),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(std.testing.io, out_new_dir, .{}));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}
