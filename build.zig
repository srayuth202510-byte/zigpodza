const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run only unit/integration tests matching this substring");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    const error_tracing = b.option(bool, "error-tracing", "Preserve @errorReturnTrace() stack frames") orelse
        (optimize == .Debug or optimize == .ReleaseSafe);

    const exe = b.addExecutable(.{
        .name = "zigpod",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = error_tracing,
    });
    b.installArtifact(exe);

    // zig build run -- <args>
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run zigpod");
    run_step.dependOn(&run_cmd.step);

    // zig build test (supports -Dtest-filter=<substring>)
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
        .error_tracing = error_tracing,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
