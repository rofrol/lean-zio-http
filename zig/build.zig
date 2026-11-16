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
    mod.addCSourceFile(.{ .file = b.path("src/pg.c"), .flags = &.{ "-O2" } });
    // libpq's headers (Homebrew's libpq by default); the executables link libpq.
    const pq_include = b.option([]const u8, "pq-include", "libpq include directory") orelse @panic("-Dpq-include required");
    mod.addIncludePath(.{ .cwd_relative = pq_include });
    const lib = b.addLibrary(.{ .name = "zsrv", .root_module = mod, .linkage = .static });
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);

    // `zig build test`: the deterministic tests of the PostgreSQL pool (README,
    // "PostgreSQL") and of the transport's shutdown and admission (README,
    // "Production contract"). pg_test.zig runs pg.zig on a real loop with a
    // scripted fake in place of pg.c; pg_glue_test.c runs pg.c and the real
    // libpq against a fake PostgreSQL server, so it links libpq and the Lean
    // runtime.
    const test_step = b.step("test", "Run the PostgreSQL pool's and the transport's tests");
    const pool_mod = b.createModule(.{
        .root_source_file = b.path("src/pg_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pool_mod.addImport("zio", zio.module("zio"));
    const pool_tests = b.addTest(.{ .root_module = pool_mod });
    test_step.dependOn(&b.addRunArtifact(pool_tests).step);
    // serve_test.zig runs serve.zig's shutdown and admission on real loops,
    // with a fake of glue.c (README, "Production contract").
    const serve_mod = b.createModule(.{
        .root_source_file = b.path("src/serve_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    serve_mod.addImport("zio", zio.module("zio"));
    const serve_tests = b.addTest(.{ .root_module = serve_mod });
    test_step.dependOn(&b.addRunArtifact(serve_tests).step);

    const lean_lib = b.option([]const u8, "lean-lib", "Lean library directory, with libleanshared (tests)");
    const pq_lib = b.option([]const u8, "pq-lib", "libpq library directory (tests)");
    if (lean_lib == null or pq_lib == null) {
        test_step.dependOn(&b.addFail("zig build test needs -Dlean-lib and -Dpq-lib").step);
        return;
    }
    const glue_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    glue_mod.addIncludePath(.{ .cwd_relative = lean_include });
    glue_mod.addIncludePath(.{ .cwd_relative = pq_include });
    glue_mod.addCSourceFile(.{ .file = b.path("src/pg_glue_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Werror" } });
    for ([_][]const u8{ lean_lib.?, pq_lib.? }) |dir| {
        glue_mod.addLibraryPath(.{ .cwd_relative = dir });
        glue_mod.addRPath(.{ .cwd_relative = dir });
    }
    glue_mod.linkSystemLibrary("leanshared", .{});
    glue_mod.linkSystemLibrary("pq", .{});
    const glue_tests = b.addExecutable(.{ .name = "pg_glue_test", .root_module = glue_mod });
    test_step.dependOn(&b.addRunArtifact(glue_tests).step);
}
