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

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/images/search?term=");
    try appendQueryEncoded(&path_buf, term);

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
    parent_dir: std.fs.Dir,
    basename: []const u8,
    kind: OutputKind,

    fn deinit(self: *@This()) void {
        self.parent_dir.close();
    }
};

/// Validates `out_path` lexically and against symlink escapes on both the
/// parent directory and leaf target before any daemon I/O begins (BUG-023).
fn validateOutputPath(alloc: std.mem.Allocator, out_path: []const u8, allow_dir: bool) !ValidatedOutput {
    try validateHostPath(out_path, false);
    const parent = std.fs.path.dirname(out_path) orelse return ApiError.InvalidHostPath;
    const basename = std.fs.path.basename(out_path);
    if (basename.len == 0) return ApiError.InvalidHostPath;

    var parent_dir = std.fs.openDirAbsolute(parent, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return err,
        else => return ApiError.InvalidHostPath,
    };
    errdefer parent_dir.close();

    const real_parent = parent_dir.realpathAlloc(alloc, ".") catch return ApiError.InvalidHostPath;
    defer alloc.free(real_parent);
    try validateHostPath(real_parent, false);

    // Reject symlinks (including dangling links) at the target leaf so atomic
    // creation/replacement never redirects outside the validated parent dir.
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    if (parent_dir.readLink(basename, &link_buf)) |_| {
        return ApiError.InvalidHostPath;
    } else |err| switch (err) {
        error.FileNotFound, error.NotLink => {},
        else => return ApiError.InvalidHostPath,
    }

    var kind: OutputKind = .not_found;
    if (parent_dir.statFile(basename)) |st| {
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

    return .{ .parent_dir = parent_dir, .basename = basename, .kind = kind };
}

const StreamOutput = struct {
    parent_dir: std.fs.Dir,
    tmp_name: []const u8,
    file: ?std.fs.File = null,
    created_tmp: bool = false,
    written: u64 = 0,
    max_bytes: ?u64 = null,

    fn ensureOpen(self: *@This()) !void {
        if (self.file != null) return;
        self.file = try self.parent_dir.createFile(self.tmp_name, .{
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
        try self.file.?.writeAll(chunk);
        self.written += chunk.len;
    }

    fn closeFile(self: *@This()) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
    }

    fn cleanup(self: *@This()) void {
        self.closeFile();
        if (self.created_tmp) {
            self.parent_dir.deleteFile(self.tmp_name) catch {};
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
    var out = try validateOutputPath(client.allocator, out_path, false);
    defer out.deinit();

    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const tmp_name = try std.fmt.allocPrint(client.allocator, ".zigpod-tmp-{s}", .{hex});
    defer client.allocator.free(tmp_name);

    var ctx = StreamOutput{
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
    try out.parent_dir.rename(tmp_name, out.basename);
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
fn openInput(alloc: std.mem.Allocator, path: []const u8) !std.fs.File {
    try validateHostPath(path, false);
    const real_path = std.fs.cwd().realpathAlloc(alloc, path) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };
    defer alloc.free(real_path);
    try validateHostPath(real_path, false);

    const st = std.fs.cwd().statFile(real_path) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };
    if (st.kind != .file) return ApiError.InvalidHostPath;

    const file = try std.fs.openFileAbsolute(real_path, .{});
    errdefer file.close();
    const opened_st = try file.stat();
    if (opened_st.kind != .file) return ApiError.InvalidHostPath;
    return file;
}

/// Reads a local tar file (bounded by `max_load_bytes`) for upload.
fn readInputFile(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try openInput(alloc, path);
    defer file.close();
    const size = (try file.stat()).size;
    if (size > max_load_bytes) return ApiError.BuildContextTooLarge;
    return try file.readToEndAlloc(alloc, max_load_bytes);
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
    const body = try readInputFile(client.allocator, in_path);
    defer client.allocator.free(body);

    const path = api_prefix ++ "/images/load?quiet=0";
    try postTarUpload(client, logger, path, body, stdout);
    logger.info("loaded image tarball from {s}", .{in_path});
}

/// Uploads a local rootfs tarball as a new image
/// (`POST /images/load?fromSrc=-&repo=...`).
pub fn importImage(client: *const http.Client, logger: *log.Logger, in_path: []const u8, ref: []const u8, stdout: anytype) !void {
    try validateResourceRef(ref);
    const body = try readInputFile(client.allocator, in_path);
    defer client.allocator.free(body);

    var path_buf = std.ArrayList(u8).init(client.allocator);
    defer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/images/load?fromSrc=-&repo=");
    try appendQueryEncoded(&path_buf, ref);

    try postTarUpload(client, logger, path_buf.items, body, stdout);
    logger.info("imported image {s} from {s}", .{ ref, in_path });
}

fn randomHexToken() [16]u8 {
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    return std.fmt.bytesToHex(rand_bytes, .lower);
}

fn buildArchiveQueryPath(
    allocator: std.mem.Allocator,
    container: []const u8,
    container_path: []const u8,
) ![]u8 {
    var path_buf = std.ArrayList(u8).init(allocator);
    errdefer path_buf.deinit();
    try path_buf.appendSlice(api_prefix ++ "/containers/");
    try path_buf.appendSlice(container);
    try path_buf.appendSlice("/archive?path=");
    try appendQueryEncoded(&path_buf, container_path);
    return try path_buf.toOwnedSlice();
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
    try validateIdentifier(container);
    try validateCpContainerPath(container_dst_path);
    try validateHostPath(host_path, false);

    const real_host = std.fs.cwd().realpathAlloc(client.allocator, host_path) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };
    defer client.allocator.free(real_host);
    try validateHostPath(real_host, false);

    const basename = std.fs.path.basename(host_path);
    if (basename.len == 0 or basename.len > 100) return ApiError.InvalidHostPath;

    const st = std.fs.cwd().statFile(real_host) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return err,
        else => return ApiError.InvalidHostPath,
    };

    var tar_buf = std.ArrayList(u8).init(client.allocator);
    defer tar_buf.deinit();

    switch (st.kind) {
        .file => {
            const file = try openInput(client.allocator, real_host);
            defer file.close();
            const fstat = try file.stat();
            if (fstat.size > max_cp_bytes) return ApiError.BuildContextTooLarge;
            const content = try file.readToEndAlloc(client.allocator, max_cp_bytes);
            defer client.allocator.free(content);
            try build_mod.writeTarHeader(&tar_buf, basename, content.len, '0', "");
            try tar_buf.appendSlice(content);
            try build_mod.writePad(&tar_buf, content.len);
            try build_mod.writeTarTrailer(&tar_buf);
        },
        .directory => {
            try build_mod.tarDirectoryWithPrefix(client.allocator, real_host, basename, &tar_buf);
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

fn scanCpArchive(alloc: std.mem.Allocator, tar_file: std.fs.File) !ArchiveScan {
    try tar_file.seekTo(0);
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var iter = std.tar.iterator(tar_file.reader(), .{
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

fn rejectIfSymlink(dir: std.fs.Dir, name: []const u8) !void {
    var lbuf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    if (dir.readLink(name, &lbuf)) |_| {
        return ApiError.InvalidHostPath;
    } else |err| switch (err) {
        error.FileNotFound, error.NotLink => {},
        else => return ApiError.InvalidHostPath,
    }
}

fn openSubDirNoSymlink(root: std.fs.Dir, rel_dir: []const u8) !std.fs.Dir {
    var cur = try root.openDir(".", .{});
    errdefer cur.close();
    if (rel_dir.len == 0) return cur;

    var it = std.mem.splitScalar(u8, rel_dir, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return ApiError.InvalidHostPath;
        try rejectIfSymlink(cur, comp);
        cur.makeDir(comp) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try rejectIfSymlink(cur, comp);
        const next = cur.openDir(comp, .{}) catch return ApiError.InvalidHostPath;
        cur.close();
        cur = next;
    }
    return cur;
}

fn copyTarFileContents(src_reader: anytype, dst_file: std.fs.File, expected_size: u64) !void {
    var buf: [8192]u8 = undefined;
    var remaining = expected_size;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buf.len));
        const n = try src_reader.readAll(buf[0..want]);
        if (n != want) return error.UnexpectedEndOfStream;
        try dst_file.writeAll(buf[0..n]);
        remaining -= n;
    }
}

fn extractCpArchiveToDir(tar_file: std.fs.File, dst_dir: std.fs.Dir, strip_prefix: ?[]const u8) !void {
    try tar_file.seekTo(0);
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var iter = std.tar.iterator(tar_file.reader(), .{
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

        const leaf = std.fs.path.basename(rel);
        const parent_rel = std.fs.path.dirname(rel) orelse "";
        var parent_dir = try openSubDirNoSymlink(dst_dir, parent_rel);
        defer parent_dir.close();

        switch (f.kind) {
            .directory => {
                try rejectIfSymlink(parent_dir, leaf);
                parent_dir.makeDir(leaf) catch |err| switch (err) {
                    error.PathAlreadyExists => {
                        const st = parent_dir.statFile(leaf) catch return ApiError.InvalidHostPath;
                        if (st.kind != .directory) return ApiError.InvalidHostPath;
                    },
                    else => return err,
                };
                try rejectIfSymlink(parent_dir, leaf);
            },
            .file => {
                try rejectIfSymlink(parent_dir, leaf);
                const hex = randomHexToken();
                var tmp_buf: [32]u8 = undefined;
                const tmp_name = std.fmt.bufPrint(&tmp_buf, ".zigpod-cp-{s}", .{hex}) catch unreachable;
                var tmp_file: ?std.fs.File = try parent_dir.createFile(tmp_name, .{
                    .truncate = true,
                    .exclusive = true,
                });
                var cleanup_tmp = true;
                defer {
                    if (tmp_file) |tf| tf.close();
                    if (cleanup_tmp) parent_dir.deleteFile(tmp_name) catch {};
                }
                try copyTarFileContents(f.reader(), tmp_file.?, f.size);
                tmp_file.?.close();
                tmp_file = null;
                try parent_dir.rename(tmp_name, leaf);
                cleanup_tmp = false;
            },
            .sym_link => {
                try rejectIfSymlink(parent_dir, leaf);
                parent_dir.deleteFile(leaf) catch {};
                try parent_dir.symLink(f.link_name, leaf, .{});
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
    try validateIdentifier(container);
    try validateCpContainerPath(container_src_path);

    var out = try validateOutputPath(client.allocator, host_dst_path, true);
    defer out.deinit();

    const api_path = try buildArchiveQueryPath(client.allocator, container, container_src_path);
    defer client.allocator.free(api_path);

    const hex = randomHexToken();
    const tmp_tar_name = try std.fmt.allocPrint(client.allocator, ".zigpod-cp-{s}.tar", .{hex});
    defer client.allocator.free(tmp_tar_name);

    var stream_ctx = StreamOutput{
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

    const tar_file = try out.parent_dir.openFile(tmp_tar_name, .{});
    defer tar_file.close();

    const scan = try scanCpArchive(client.allocator, tar_file);
    defer if (scan.common_root) |cr| client.allocator.free(cr);

    if (scan.single_file_only and out.kind != .directory) {
        try tar_file.seekTo(0);
        var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        var iter = std.tar.iterator(tar_file.reader(), .{
            .file_name_buffer = &name_buf,
            .link_name_buffer = &link_buf,
        });
        while (try iter.next()) |f| {
            const clean_rel = try validateTarEntryPath(f.name);
            if (clean_rel.len == 0) continue;
            const out_hex = randomHexToken();
            const tmp_out_name = try std.fmt.allocPrint(client.allocator, ".zigpod-tmp-{s}", .{out_hex});
            defer client.allocator.free(tmp_out_name);

            var out_ctx = StreamOutput{
                .parent_dir = out.parent_dir,
                .tmp_name = tmp_out_name,
            };
            defer out_ctx.cleanup();
            try out_ctx.ensureOpen();
            try copyTarFileContents(f.reader(), out_ctx.file.?, f.size);
            out_ctx.closeFile();
            try out.parent_dir.rename(tmp_out_name, out.basename);
            out_ctx.created_tmp = false;
            break;
        }
    } else if (out.kind == .directory) {
        var dst_dir = try out.parent_dir.openDir(out.basename, .{});
        defer dst_dir.close();
        try extractCpArchiveToDir(tar_file, dst_dir, null);
    } else if (out.kind == .not_found) {
        const stage_hex = randomHexToken();
        const stage_name = try std.fmt.allocPrint(client.allocator, ".zigpod-cp-dir-{s}", .{stage_hex});
        defer client.allocator.free(stage_name);

        try out.parent_dir.makeDir(stage_name);
        var delete_stage = true;
        defer if (delete_stage) out.parent_dir.deleteTree(stage_name) catch {};

        var stage_dir: ?std.fs.Dir = try out.parent_dir.openDir(stage_name, .{});
        defer if (stage_dir) |*d| d.close();

        const strip = if (!scan.single_file_only) scan.common_root else null;
        try extractCpArchiveToDir(tar_file, stage_dir.?, strip);
        stage_dir.?.close();
        stage_dir = null;

        try out.parent_dir.rename(stage_name, out.basename);
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

test "searchImages renders table and rejects malformed terms" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-search-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try searchImages(&client, &logger, "alpine", out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "alpine") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[OK]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "A minimal container") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "user/alpine") != null);

    var sink = std.ArrayList(u8).init(alloc);
    defer sink.deinit();
    var e1 = false;
    searchImages(&client, &logger, "", sink.writer()) catch |e| {
        e1 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e1);
    var e2 = false;
    searchImages(&client, &logger, "a\x01b", sink.writer()) catch |e| {
        e2 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e2);
    var e3 = false;
    searchImages(&client, &logger, "a" ** 257, sink.writer()) catch |e| {
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
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(out_dir);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out.tar", .{out_dir});
    defer alloc.free(out_path);
    defer std.fs.deleteFileAbsolute(out_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try saveImage(&client, &logger, "alpine:3.20", out_path, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Saved alpine:3.20") != null);

    try exportContainer(&client, &logger, "web", out_path, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Exported web") != null);

    const written = try std.fs.cwd().readFileAlloc(alloc, out_path, tar_data.len);
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
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const in_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(in_dir);
    const in_path = try std.fmt.allocPrint(alloc, "{s}/in.tar", .{in_dir});
    defer alloc.free(in_path);
    try tmp.dir.writeFile(.{ .sub_path = "in.tar", .data = "UPLOAD-PAYLOAD" });

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try loadImage(&client, &logger, in_path, out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Loaded image: alpine:3.20") != null);

    try importImage(&client, &logger, in_path, "myrepo/app:v2", out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Imported") != null);

    var got_api_err = false;
    loadImage(&client, &logger, in_path, out.writer()) catch |e| {
        got_api_err = e == ApiError.PodmanApiError;
    };
    try std.testing.expect(got_api_err);

    // Validation paths: dangerous output/input locations and bad refs.
    var e1 = false;
    saveImage(&client, &logger, "img", "/etc/passwd", out.writer()) catch |e| {
        e1 = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e1);
    var e2 = false;
    loadImage(&client, &logger, "/root/../etc/shadow", out.writer()) catch |e| {
        e2 = e == ApiError.InvalidHostPath;
    };
    try std.testing.expect(e2);
    var e3 = false;
    importImage(&client, &logger, in_path, "bad?x=1", out.writer()) catch |e| {
        e3 = e == ApiError.InvalidIdentifier;
    };
    try std.testing.expect(e3);
    var e4 = false;
    exportContainer(&client, &logger, "a/../b", "/tmp/zp-tr-export.tar", out.writer()) catch |e| {
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
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const max_term = "a" ** 256;
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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try searchImages(&client, &logger, "alpine linux#1", out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "NAME") != null);

    try searchImages(&client, &logger, max_term, out.writer());
    try std.testing.expectError(ApiError.InvalidIdentifier, searchImages(&client, &logger, "a\x7fb", out.writer()));
    try std.testing.expectError(error.UnexpectedToken, searchImages(&client, &logger, "badjson", out.writer()));
    try std.testing.expectError(ApiError.PodmanApiError, searchImages(&client, &logger, "fail", out.writer()));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "saveImage and exportContainer preserve existing files on error and block symlink escapes (BUG-023)" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-atomic-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_dir);

    const existing_path = try std.fmt.allocPrint(alloc, "{s}/keep.tar", .{tmp_dir});
    defer alloc.free(existing_path);
    try tmp.dir.writeFile(.{ .sub_path = "keep.tar", .data = "ORIGINAL-TAR" });

    const empty_out_path = try std.fmt.allocPrint(alloc, "{s}/empty.tar", .{tmp_dir});
    defer alloc.free(empty_out_path);

    try tmp.dir.symLink("/etc/hosts", "escape-leaf.tar", .{});
    const escape_leaf = try std.fmt.allocPrint(alloc, "{s}/escape-leaf.tar", .{tmp_dir});
    defer alloc.free(escape_leaf);

    try tmp.dir.symLink("/etc/nonexistent-zigpod-target", "dangling-leaf.tar", .{});
    const dangling_leaf = try std.fmt.allocPrint(alloc, "{s}/dangling-leaf.tar", .{tmp_dir});
    defer alloc.free(dangling_leaf);

    try tmp.dir.symLink("/etc", "etc-dir", .{ .is_directory = true });
    const escape_parent = try std.fmt.allocPrint(alloc, "{s}/etc-dir/out.tar", .{tmp_dir});
    defer alloc.free(escape_parent);

    try tmp.dir.makeDir("subdir");
    const dir_target = try std.fmt.allocPrint(alloc, "{s}/subdir", .{tmp_dir});
    defer alloc.free(dir_target);

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const max_ref = "r" ** 256;
    const max_id = "c" ** 128;
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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    // 404 failure and mid-stream EOF must leave pre-existing output file untouched.
    try std.testing.expectError(ApiError.PodmanApiError, saveImage(&client, &logger, "missing", existing_path, out.writer()));
    try std.testing.expectError(http.Error.InvalidResponse, saveImage(&client, &logger, "truncated", existing_path, out.writer()));
    const preserved = try tmp.dir.readFileAlloc(alloc, "keep.tar", 64);
    defer alloc.free(preserved);
    try std.testing.expectEqualStrings("ORIGINAL-TAR", preserved);

    // Chunked streaming atomically replaces keep.tar without leaving temp files.
    try exportContainer(&client, &logger, "web", existing_path, out.writer());
    const replaced = try tmp.dir.readFileAlloc(alloc, "keep.tar", 64);
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("hello", replaced);

    // Empty 200 OK still creates an empty target file; boundary lengths work.
    try saveImage(&client, &logger, max_ref, empty_out_path, out.writer());
    const empty_bytes = try tmp.dir.readFileAlloc(alloc, "empty.tar", 64);
    defer alloc.free(empty_bytes);
    try std.testing.expectEqual(@as(usize, 0), empty_bytes.len);

    try exportContainer(&client, &logger, max_id, empty_out_path, out.writer());

    // Fail-closed security & boundary checks (before socket I/O).
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", escape_leaf, out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", dangling_leaf, out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, exportContainer(&client, &logger, "web", escape_parent, out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", dir_target, out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, saveImage(&client, &logger, "alpine", "/root-file.tar", out.writer()));
    try std.testing.expectError(ApiError.InvalidIdentifier, saveImage(&client, &logger, "r" ** 257, empty_out_path, out.writer()));
    try std.testing.expectError(ApiError.InvalidIdentifier, exportContainer(&client, &logger, "c" ** 129, empty_out_path, out.writer()));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);

    // Verify no leftover .zigpod-tmp-* files remain in tmp.dir.
    var it = tmp.dir.iterate();
    while (try it.next()) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".zigpod-tmp-"));
    }
}

test "loadImage and importImage reject symlink escapes, directories, missing files, and bad boundaries (BUG-023)" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/zp-tr-in-{d}.sock",
        .{std.time.nanoTimestamp()},
    );
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_dir);

    try tmp.dir.writeFile(.{ .sub_path = "rootfs.tar", .data = "ROOTFS" });
    const good_in = try std.fmt.allocPrint(alloc, "{s}/rootfs.tar", .{tmp_dir});
    defer alloc.free(good_in);

    try tmp.dir.symLink("/etc/passwd", "sym-etc", .{});
    const sym_in = try std.fmt.allocPrint(alloc, "{s}/sym-etc", .{tmp_dir});
    defer alloc.free(sym_in);

    try tmp.dir.makeDir("in-dir");
    const dir_in = try std.fmt.allocPrint(alloc, "{s}/in-dir", .{tmp_dir});
    defer alloc.free(dir_in);

    const missing_in = try std.fmt.allocPrint(alloc, "{s}/missing.tar", .{tmp_dir});
    defer alloc.free(missing_in);

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

    const max_ref = "r" ** 256;
    const replies = [_]ScriptedReply{
        .{
            .expected_prefix = "POST /v1.40/images/load?fromSrc=-&repo=" ++ max_ref ++ " HTTP/1.1\r\n",
            .expected_substring = "Content-Type: application/x-tar\r\n",
            .raw_response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 17\r\n\r\n{\"message\":\"bad\"}",
        },
    };

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();

    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try std.testing.expectError(ApiError.InvalidHostPath, loadImage(&client, &logger, sym_in, out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, importImage(&client, &logger, sym_in, "repo:v1", out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, loadImage(&client, &logger, dir_in, out.writer()));
    try std.testing.expectError(error.FileNotFound, loadImage(&client, &logger, missing_in, out.writer()));
    try std.testing.expectError(ApiError.InvalidIdentifier, importImage(&client, &logger, good_in, "r" ** 257, out.writer()));
    try std.testing.expectError(ApiError.PodmanApiError, importImage(&client, &logger, good_in, max_ref, out.writer()));

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

fn buildTestTarBytes(alloc: std.mem.Allocator, entry_name: []const u8, payload: []const u8, kind: u8, linkname: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();
    try build_mod.writeTarHeader(&buf, entry_name, payload.len, kind, linkname);
    if (kind == '0' and payload.len > 0) {
        try buf.appendSlice(payload);
        try build_mod.writePad(&buf, payload.len);
    }
    try build_mod.writeTarTrailer(&buf);
    return try buf.toOwnedSlice();
}

test "cpToContainer uploads files and directories and rejects unsafe inputs" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-cp-to-{d}.sock", .{std.time.nanoTimestamp()});
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root_dir);

    try tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello-cp" });
    const file_path = try std.fs.path.join(alloc, &.{ root_dir, "hello.txt" });
    defer alloc.free(file_path);

    try tmp.dir.makeDir("bundle");
    try tmp.dir.writeFile(.{ .sub_path = "bundle/cfg.json", .data = "{\"ok\":true}" });
    const dir_path = try std.fs.path.join(alloc, &.{ root_dir, "bundle" });
    defer alloc.free(dir_path);

    try tmp.dir.symLink("/etc/passwd", "evil-link", .{});
    const link_path = try std.fs.path.join(alloc, &.{ root_dir, "evil-link" });
    defer alloc.free(link_path);

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();
    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    try std.testing.expectError(ApiError.InvalidIdentifier, cpToContainer(&client, &logger, "../bad", file_path, "/tmp", out.writer()));
    try std.testing.expectError(ApiError.InvalidMountTarget, cpToContainer(&client, &logger, "web", file_path, "relative", out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, cpToContainer(&client, &logger, "web", "rel.txt", "/tmp", out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, cpToContainer(&client, &logger, "web", "/etc/passwd", "/tmp", out.writer()));
    try std.testing.expectError(ApiError.InvalidHostPath, cpToContainer(&client, &logger, "web", link_path, "/tmp", out.writer()));

    try cpToContainer(&client, &logger, "web", file_path, "/tmp", out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "web:/tmp") != null);

    out.clearRetainingCapacity();
    try cpToContainer(&client, &logger, "web", dir_path, "/", out.writer());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "web:/") != null);

    thread.join();
    joined = true;
    try std.testing.expectEqual(replies.len, ctx.matched);
}

test "cpFromContainer unpacks safely and blocks Tar-Slip, symlink escapes, and partial overwrites" {
    const alloc = std.testing.allocator;
    const sock_path = try std.fmt.allocPrint(alloc, "/tmp/zp-cp-from-{d}.sock", .{std.time.nanoTimestamp()});
    defer alloc.free(sock_path);
    std.fs.deleteFileAbsolute(sock_path) catch {};
    defer std.fs.deleteFileAbsolute(sock_path) catch {};

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root_dir);

    const out_file = try std.fs.path.join(alloc, &.{ root_dir, "hosts.txt" });
    defer alloc.free(out_file);

    try tmp.dir.makeDir("existing");
    const existing_dir = try std.fs.path.join(alloc, &.{ root_dir, "existing" });
    defer alloc.free(existing_dir);

    const out_new_dir = try std.fs.path.join(alloc, &.{ root_dir, "app_copy" });
    defer alloc.free(out_new_dir);

    const file_tar = try buildTestTarBytes(alloc, "hosts", "127.0.0.1 localhost\n", '0', "");
    defer alloc.free(file_tar);

    var dir_tar_buf = std.ArrayList(u8).init(alloc);
    defer dir_tar_buf.deinit();
    try build_mod.writeTarHeader(&dir_tar_buf, "app/", 0, '5', "");
    try build_mod.writeTarHeader(&dir_tar_buf, "app/run.sh", 11, '0', "");
    try dir_tar_buf.appendSlice("#!/bin/sh\n\n");
    try build_mod.writePad(&dir_tar_buf, 11);
    try build_mod.writeTarTrailer(&dir_tar_buf);

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

    var server = try (try std.net.Address.initUnix(sock_path)).listen(.{ .reuse_address = false });
    defer server.deinit();

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

    var ctx = MockApiCtx{ .server = &server, .replies = &replies };
    const thread = try std.Thread.spawn(.{}, runMockPodmanServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const client = http.Client{ .allocator = alloc, .socket_path = sock_path };
    var logger = log.Logger{ .echo_stderr = false };
    defer logger.deinit();
    var out = std.ArrayList(u8).init(alloc);
    defer out.deinit();

    // 1) Single file -> new host file
    try cpFromContainer(&client, &logger, "web", "/etc/hosts", out_file, out.writer());
    const got_file = try std.fs.cwd().readFileAlloc(alloc, out_file, 1024);
    defer alloc.free(got_file);
    try std.testing.expectEqualStrings("127.0.0.1 localhost\n", got_file);

    // 2) Directory -> existing host directory (keeps app/run.sh)
    try cpFromContainer(&client, &logger, "web", "/app", existing_dir, out.writer());
    const inside_existing = try std.fs.path.join(alloc, &.{ existing_dir, "app", "run.sh" });
    defer alloc.free(inside_existing);
    const got_sh1 = try std.fs.cwd().readFileAlloc(alloc, inside_existing, 1024);
    defer alloc.free(got_sh1);
    try std.testing.expectEqualStrings("#!/bin/sh\n\n", got_sh1);

    // 3) Directory -> new host directory (strips common root, creates app_copy/run.sh)
    try cpFromContainer(&client, &logger, "web", "/app", out_new_dir, out.writer());
    const inside_new = try std.fs.path.join(alloc, &.{ out_new_dir, "run.sh" });
    defer alloc.free(inside_new);
    const got_sh2 = try std.fs.cwd().readFileAlloc(alloc, inside_new, 1024);
    defer alloc.free(got_sh2);
    try std.testing.expectEqualStrings("#!/bin/sh\n\n", got_sh2);

    // 4) Tar-Slip ../escape.txt must fail closed without creating files
    try std.testing.expectError(ApiError.InvalidHostPath, cpFromContainer(&client, &logger, "web", "/slip", existing_dir, out.writer()));

    // 5) Symlink escape ../outside must fail closed
    try std.testing.expectError(ApiError.InvalidHostPath, cpFromContainer(&client, &logger, "web", "/sym", existing_dir, out.writer()));

    // 6) 404 from daemon must preserve pre-existing out_file untouched
    try std.testing.expectError(ApiError.PodmanApiError, cpFromContainer(&client, &logger, "web", "/missing", out_file, out.writer()));
    const still_intact = try std.fs.cwd().readFileAlloc(alloc, out_file, 1024);
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
        var hl_buf = std.ArrayList(u8).init(alloc);
        defer hl_buf.deinit();
        var hdr = [_]u8{0} ** 512;
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
        try hl_buf.appendSlice(&hdr);
        try build_mod.writeTarTrailer(&hl_buf);

        try tmp.dir.writeFile(.{ .sub_path = "hardlink.tar", .data = hl_buf.items });
        const f = try tmp.dir.openFile("hardlink.tar", .{});
        defer f.close();
        try std.testing.expectError(error.TarUnsupportedHeader, scanCpArchive(alloc, f));
    }

    // 2) Oversized PAX extended header (typeflag 'x' with path > MAX_PATH_BYTES) must fail.
    {
        var pax_buf = std.ArrayList(u8).init(alloc);
        defer pax_buf.deinit();
        const long_path = "a" ** (std.fs.MAX_PATH_BYTES + 64);
        const rec_body = try std.fmt.allocPrint(alloc, "path={s}\n", .{long_path});
        defer alloc.free(rec_body);
        const total_len = rec_body.len + 5; // "NNNN "
        const pax_payload = try std.fmt.allocPrint(alloc, "{d:0>4} {s}", .{ total_len, rec_body });
        defer alloc.free(pax_payload);

        var hdr = [_]u8{0} ** 512;
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
        try pax_buf.appendSlice(&hdr);
        try pax_buf.appendSlice(pax_payload);
        try build_mod.writePad(&pax_buf, pax_payload.len);
        try build_mod.writeTarTrailer(&pax_buf);

        try tmp.dir.writeFile(.{ .sub_path = "longpax.tar", .data = pax_buf.items });
        const f = try tmp.dir.openFile("longpax.tar", .{});
        defer f.close();
        try std.testing.expectError(error.TarInsufficientBuffer, scanCpArchive(alloc, f));
    }

    // 3) Truncated tar stream (header declares 2048 bytes, stream ends after 64 bytes).
    {
        var trunc_buf = std.ArrayList(u8).init(alloc);
        defer trunc_buf.deinit();
        try build_mod.writeTarHeader(&trunc_buf, "partial.bin", 2048, '0', "");
        try trunc_buf.appendNTimes('Z', 64);

        try tmp.dir.writeFile(.{ .sub_path = "trunc.tar", .data = trunc_buf.items });
        const f = try tmp.dir.openFile("trunc.tar", .{});
        defer f.close();
        try std.testing.expectError(error.EndOfStream, scanCpArchive(alloc, f));
    }
}
