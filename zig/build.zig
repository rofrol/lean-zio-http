const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lean_include = b.option([]const u8, "lean-include", "Lean include directory") orelse @panic("-Dlean-include required");
    // On Linux zio's event loop runs on the backend named here, epoll (the
    // default) or io_uring (`-Dlinux-backend`; docs/modules.md, `zig/`;
    // item wi7efy). Never zio's own default there, `.linux` (Backend(.auto),
    // src/ev/backends/linux.zig), which picks one at run time: the build and
    // the tests must know which one runs. The choice is a build option, not a
    // `zio_options` declaration in serve.zig, because a test binary's root is
    // Zig's test runner: only the build option reaches the library and every
    // test module alike. serve.zig refuses to compile on `.linux`.
    const LinuxBackend = enum { epoll, io_uring };
    const linux_backend = b.option(LinuxBackend, "linux-backend", "zio's event loop backend on Linux") orelse .epoll;
    const zio = if (target.result.os.tag == .linux)
        b.dependency("zio", .{ .target = target, .optimize = optimize, .backend = linux_backend })
    else
        b.dependency("zio", .{ .target = target, .optimize = optimize });
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

    // `zig build test`: the deterministic tests of the PostgreSQL pool (docs/postgresql.md)
    // and of the transport's shutdown and admission
    // (docs/production-contract.md). pg_test.zig runs pg.zig on a real loop with a
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
    // with a fake of glue.c (docs/production-contract.md).
    const serve_mod = b.createModule(.{
        .root_source_file = b.path("src/serve_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    serve_mod.addImport("zio", zio.module("zio"));
    // The backend the build chose, for the test that checks the loops run on it.
    const test_options = b.addOptions();
    test_options.addOption(LinuxBackend, "linux_backend", linux_backend);
    serve_mod.addOptions("build_options", test_options);
    const serve_tests = b.addTest(.{ .root_module = serve_mod });
    test_step.dependOn(&b.addRunArtifact(serve_tests).step);

    // `zig build cleanup-controls`: serve_test.zig's tests after two negative
    // controls of Single.deinit (src/cleanup_controls_test.zig). It fails by
    // design; ./cleanup-controls.sh runs it and checks how.
    const controls_step = b.step("cleanup-controls", "Run the transport's tests after the cleanup's negative controls (fails by design; see ./cleanup-controls.sh)");
    const controls_mod = b.createModule(.{
        .root_source_file = b.path("src/cleanup_controls_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    controls_mod.addImport("zio", zio.module("zio"));
    controls_mod.addOptions("build_options", test_options);
    const controls_tests = b.addTest(.{ .root_module = controls_mod });
    controls_step.dependOn(&b.addRunArtifact(controls_tests).step);

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
    // pg_glue_test.c calls dladdr, which glibc before 2.34 has only in libdl.
    // No `-ldl` is needed here: for every glibc target Zig (0.17.1) links
    // libdl itself, from its own glibc stubs below 2.34 (src/libs/glibc.zig,
    // `libs`) or, from the host's glibc, as part of libcFullLinkFlags
    // (src/target.zig); and linkSystemLibrary("dl") on a GNU ABI only sets
    // link_libc (std.zig.target.isLibCLibName). A cross-link for
    // aarch64-linux-gnu.2.26 and x86_64-linux-gnu.2.26 (stub libpq and Lean
    // libraries) needs dladdr from libdl.so.2. Recheck at a Zig update.
    const glue_tests = b.addExecutable(.{ .name = "pg_glue_test", .root_module = glue_mod });
    test_step.dependOn(&b.addRunArtifact(glue_tests).step);
}
