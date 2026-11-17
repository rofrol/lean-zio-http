#!/bin/sh
# The negative controls of the transport tests' cleanup (item znorfg; README,
# "Running"). `zig build cleanup-controls` in zig/ runs serve_test.zig's tests
# after two tests of zig/src/cleanup_controls_test.zig that misbehave on
# purpose; it must fail, and in exactly this way:
# - the test that fails with two connections open fails with its own error,
#   Single.deinit logs that it drains those two and then that it drained
#   them, and every serve_test.zig test after it passes (no cascade);
# - the test that passes with a connection left open is reported for the
#   leak Single.deinit logged at error level, naming it, though it passed.
# Anything else (a compile error, a crash, another failure, other counts)
# fails this script. It is not part of ./check.sh: run it at each update of
# Zig and for every change to Single.deinit in zig/src/serve_test.zig
# (decided 2026-11-17, item znorfg). Needs what check.sh needs for
# `zig build`: the Lean toolchain and pg_config.
set -eu
cd "$(dirname "$0")"
out=$(mktemp)
trap 'rm -f "$out" "$out.f" "$out.l"' EXIT
lean_prefix=$(lean --print-prefix)
status=0
(cd zig && zig build cleanup-controls -Dlean-include="$lean_prefix/include" \
  -Dpq-include="$(pg_config --includedir)") >"$out" 2>&1 || status=$?

fail() {
  echo "cleanup-controls: $1; zig build cleanup-controls exited $status, printing:"
  cat "$out"; exit 1
}
# The lines the runner prints for one reported test: its header and the
# indented lines of its output after it.
report() {
  awk -v h="$1" '$0 == h { on = 1; next } on && /^       / { print; next } { on = 0 }' "$out"
}

[ "$status" = 1 ] || fail "expected exit status 1"
# serve_test.zig's tests, counted from their declarations, and the two controls.
serve=$(grep -c '^test "' zig/src/serve_test.zig)
total=$((serve + 2))
grep -qx "Build Summary: [0-9]*/[0-9]* steps succeeded (1 failed); $((total - 1))/$total tests passed (1 failed)" "$out" ||
  fail "expected $((total - 1)) of $total tests to pass and 1 to fail"

failing="error: 'cleanup_controls_test.test.cleanup control: a test that fails with two connections open' failed:"
leaking="error: 'cleanup_controls_test.test.cleanup control: a test that passes with a connection left open' logged 1 errors:"
[ "$(grep -c "^error: " "$out")" = 2 ] || fail "expected exactly two reported tests"
grep -qxF "$failing" "$out" || fail "the failing control is not reported as failed"
grep -qxF "$leaking" "$out" || fail "the leaking control is not reported for 1 logged error"

report "$failing" >"$out.f"
report "$leaking" >"$out.l"
expect() { # FILE PATTERN WHAT
  grep -Eq "$2" "$1" || fail "$3"
}
expect "$out.f" '^ +return error\.CleanupControlFailsOnPurpose;$' "the failing control did not fail with its own error"
expect "$out.f" '^ +\[default\] \(err\): the test left 2 connections open and [0-9]+ slots held; Single\.deinit drains them$' \
  "Single.deinit did not report the failing control's two connections"
expect "$out.f" '^ +\[default\] \(warn\): Single\.deinit drained them$' "Single.deinit did not finish draining the failing control"
expect "$out.l" '^ +\[default\] \(err\): the test left 1 connections open and [0-9]+ slots held; Single\.deinit drains them$' \
  "Single.deinit did not log the leaking control's connection"
expect "$out.l" '^ +\[default\] \(warn\): Single\.deinit drained them$' "Single.deinit did not finish draining the leaking control"
echo "cleanup controls: the failing and the leaking control reported as intended; the other $serve tests passed"
