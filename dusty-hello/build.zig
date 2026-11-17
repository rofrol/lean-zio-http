const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dusty = b.dependency("dusty", .{ .target = target, .optimize = optimize });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    // dusty's own `zio` import is a stub that selects its portable std.Io
    // timeout watchdog (a second task per connection); an application on the
    // zio runtime replaces it with the real zio, so dusty's deadlines use
    // zio.AutoCancel instead (dusty 0.6.0, build.zig, "Default `zio` import").
    dusty.module("dusty").addImport("zio", zio.module("zio"));
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    mod.addImport("dusty", dusty.module("dusty"));
    mod.addImport("zio", zio.module("zio"));
    const exe = b.addExecutable(.{ .name = "dhello", .root_module = mod });
    b.installArtifact(exe);
}
