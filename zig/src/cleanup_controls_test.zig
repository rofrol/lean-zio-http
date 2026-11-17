//! Two negative controls of `Single.deinit` in serve_test.zig: tests that
//! misbehave on purpose, run only by `zig build cleanup-controls`, never by
//! `zig build test`. ./cleanup-controls.sh runs them and checks that the
//! runner reports exactly these two, each as intended, and that every test
//! of serve_test.zig passes after them: that `Single.deinit` drains what a
//! failed test left open, so the tests after it do not fail with it, and
//! that the leak it logs from a test that passed fails that test.
//!
//! The build runner runs the tests in the order of
//! `builtin.test_functions` (Zig 0.17.1, lib/compiler/Maker/Step/Run.zig
//! `requestNextTest`), which puts this file's tests before those of the
//! files it imports (seen, not documented); the first control checks that
//! the two controls come first and fails otherwise with an error the
//! script rejects.
const std = @import("std");
const builtin = @import("builtin");
const t = @import("serve_test.zig");

const c = std.c;

test "cleanup control: a test that fails with two connections open" {
    const tests = builtin.test_functions;
    if (!std.mem.endsWith(u8, tests[0].name, "cleanup control: a test that fails with two connections open") or
        !std.mem.endsWith(u8, tests[1].name, "cleanup control: a test that passes with a connection left open"))
        return error.CleanupControlsNotFirst;
    var s: t.Single = undefined;
    try s.init(64);
    defer s.deinit();
    var clients: [2]c.fd_t = undefined;
    for (&clients, 1..) |*cl, i| {
        cl.* = try s.listener.connect();
        t.awaitReadable(s.listener.fd);
        try s.stepUntil(.open, i);
    }
    defer for (clients) |cl| {
        _ = c.close(cl);
    };
    return error.CleanupControlFailsOnPurpose;
}

test "cleanup control: a test that passes with a connection left open" {
    var s: t.Single = undefined;
    try s.init(64);
    defer s.deinit();
    const cl = try s.listener.connect();
    defer _ = c.close(cl);
    t.awaitReadable(s.listener.fd);
    try s.stepUntil(.open, 1);
}

comptime {
    _ = t;
}
