const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dusty = b.dependency("dusty", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    mod.addImport("dusty", dusty.module("dusty"));
    mod.addImport("zio", zio.module("zio"));
    const exe = b.addExecutable(.{ .name = "dhello", .root_module = mod });
    b.installArtifact(exe);
}
