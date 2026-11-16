const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lean_include = b.option([]const u8, "lean-include", "Lean include directory") orelse @panic("-Dlean-include required");
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("zio", zio.module("zio"));
    mod.addIncludePath(.{ .cwd_relative = lean_include });
    mod.addCSourceFile(.{ .file = b.path("src/glue.c"), .flags = &.{ "-O2" } });
    // libpq's headers (Homebrew's libpq by default); the executables link libpq.
    const pq_include = b.option([]const u8, "pq-include", "libpq include directory") orelse @panic("-Dpq-include required");
    mod.addIncludePath(.{ .cwd_relative = pq_include });
    const lib = b.addLibrary(.{ .name = "zsrv", .root_module = mod, .linkage = .static });
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);
}
