//! Formatting and logging convenience utilities.
const std = @import("std");
pub const log = @import("log.zig");

/// Returns up to the first 12 characters of an image/container ID,
/// stripping a leading "sha256:" prefix if present.
pub fn shortId(id: []const u8) []const u8 {
    const prefix = "sha256:";
    const clean = if (std.mem.startsWith(u8, id, prefix)) id[prefix.len..] else id;
    return if (clean.len > 12) clean[0..12] else clean;
}

/// Formats a byte count into a human-readable string (B, KB, MB, GB) in `buf`.
pub fn formatSize(buf: []u8, bytes: i64) []const u8 {
    if (bytes <= 0) return std.fmt.bufPrint(buf, "0 B", .{}) catch "0 B";
    const val: f64 = @floatFromInt(bytes);
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    } else if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{val / 1024.0}) catch "?";
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{val / (1024.0 * 1024.0)}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{val / (1024.0 * 1024.0 * 1024.0)}) catch "?";
    }
}

test "shortId strips sha256 prefix and truncates to 12 chars" {
    try std.testing.expectEqualStrings("abcdef123456", shortId("abcdef1234567890"));
    try std.testing.expectEqualStrings("1234567890ab", shortId("sha256:1234567890abcdef"));
    try std.testing.expectEqualStrings("short", shortId("short"));
    try std.testing.expectEqualStrings("", shortId(""));
}

test "formatSize human readable units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatSize(&buf, 0));
    try std.testing.expectEqualStrings("512 B", formatSize(&buf, 512));
    try std.testing.expectEqualStrings("1.5 KB", formatSize(&buf, 1536));
    try std.testing.expectEqualStrings("2.0 MB", formatSize(&buf, 2 * 1024 * 1024));
    try std.testing.expectEqualStrings("1.50 GB", formatSize(&buf, 1610612736));
}
