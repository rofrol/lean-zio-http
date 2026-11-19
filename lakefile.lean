import Lake
open Lake DSL System

/-! The server's Lake package. Its modules form one library per
responsibility; `Arch.lean` (`lsrv-arch`) checks every module's imports
against the allowed directions, since Lake alone lets any module of a package
import any other.

The Zig side (`zig/`: the zio.ev loops and the libpq glue) is the external
library `zsrv`, built by `zig build` from this package's own directory, so a
package that requires this one links it without knowing where it is checked
out. Executables that use the transport also link the system's libpq: add
`-lpq` to their `moreLinkArgs` and put `pg_config --libdir` on
`LIBRARY_PATH`. -/

package lsrv where
  testDriver := "lsrv-test"

/-- The highest glibc version a `libc.so` defines: the greatest `GLIBC_2.N` or
`GLIBC_2.N.M` version name among its NUL-terminated strings, as `"2.N"` or `"2.N.M"`; `none`
when it holds no such name. -/
def glibcVersion (libc : ByteArray) : Option String := Id.run do
  let pre := "GLIBC_2.".toUTF8
  let isDigit (b : UInt8) := '0'.toUInt8 ≤ b && b ≤ '9'.toUInt8
  -- The decimal number at `j` and the position after it.
  let number (j : Nat) : Nat × Nat := Id.run do
    let mut j := j
    let mut n := 0
    while j < libc.size && isDigit libc[j]! do
      n := n * 10 + (libc[j]! - '0'.toUInt8).toNat
      j := j + 1
    return (n, j)
  let mut best : Option (Nat × Nat) := none
  let mut i := 0
  while i + pre.size < libc.size do
    if (List.range pre.size).all fun k => libc[i + k]! == pre[k]! then
      let start := i + pre.size
      if isDigit libc[start]! then
        let (minor, j) := number start
        let (patch, end_) := if j + 1 < libc.size && libc[j]! == '.'.toUInt8 && isDigit libc[j + 1]! then
          number (j + 1) else (0, j)
        -- A version name is a whole NUL-terminated string (in .dynstr and
        -- as the suffix of `symbol@@GLIBC_2.N` in .strtab), not text around it.
        if end_ < libc.size && libc[end_]! == 0 &&
            best.all fun (m, p) => m < minor || (m == minor && p < patch) then
          best := some (minor, patch)
      i := start
    else
      i := i + 1
  return best.map fun (m, p) => if p == 0 then s!"2.{m}" else s!"2.{m}.{p}"

/-- The `zig build -Dtarget` of `libzsrv.a`: the host's (`none`, Zig's native
target), except under a Lean toolchain that ships the glibc its programs link
against (`lib/glibc/libc.so`, Linux), where it is the host's architecture on
Linux with that glibc. Zig's std calls a libc function only when the target's
glibc has it, so the archive then references no symbol the linker Lean runs
cannot resolve; with the host's newer glibc it references `copy_file_range`,
`statx`, `execveat` and `arc4random_buf`, which glibc 2.26 (Lean's
nightly-2026-11-17) lacks (issue 4n7czb). Lean's toolchain copies glibc's
`libc-<version>.so` to `lib/glibc/libc.so`, dropping the version from the name
(`script/prepare-llvm-linux.sh` in leanprover/lean4), so the version is read
from the version names the library defines. -/
def zsrvTarget (sysroot : FilePath) : IO (Option String) := do
  let libc := sysroot / "lib" / "glibc" / "libc.so"
  unless ← libc.pathExists do return none
  match glibcVersion (← IO.FS.readBinFile libc) with
  | some v => return some s!"native-linux-gnu.{v}"
  | none => throw <| IO.userError s!"{libc} defines no GLIBC_2.* version"

/-- `libzsrv.a`, rebuilt when a file under `zig/` (sources, `build.zig`,
`build.zig.zon`), `ZIG_OPTIMIZE`, the Zig compiler's version, the Lean
toolchain's version, libpq's version (`pg_config --version`), the paths of the
Lean and libpq include directories, or the contents of the headers the glue
reads from them (every file of the Lean include directory's `lean/`,
`libpq-fe.h` and the `postgres_ext.h` it includes) or the Zig target
(`zsrvTarget`) change. Other system headers and the Zig compiler's own files are
traced only through those versions. `ZIG_OPTIMIZE` picks the build of the loop and zio:
ReleaseSafe (bounds and overflow checks) unless set; it measured no slower
than ReleaseFast. `LSRV_LINUX_BACKEND` picks zio's event loop backend on Linux,
`epoll` (unless set) or `io_uring` (`-Dlinux-backend`, zig/build.zig; item
wi7efy); it is traced too, and ignored on macOS (kqueue). -/
extern_lib zsrv (pkg) := do
  let zigDir := pkg.dir / "zig"
  let srcs ← inputDir zigDir (text := true) fun p =>
    -- Zig's caches and outputs and the fetched packages are not inputs;
    -- build.zig.zon pins zio by commit and hash.
    let under (d : String) := p.toString.startsWith ((zigDir / d).toString ++ "/")
    !(under "zig-out" || under ".zig-cache" || under "zig-pkg")
  let leanInclude ← getLeanIncludeDir
  let pqInclude : FilePath := (← captureProc { cmd := "pg_config", args := #["--includedir"] }).trimAscii.toString
  let optimize := (← IO.getEnv "ZIG_OPTIMIZE").getD "ReleaseSafe"
  let backend := (← IO.getEnv "LSRV_LINUX_BACKEND").getD "epoll"
  unless backend == "epoll" || backend == "io_uring" do
    error s!"LSRV_LINUX_BACKEND is {backend}: it must be epoll or io_uring"
  let zigTarget ← zsrvTarget (← getLeanSysroot)
  let zigVersion := (← captureProc { cmd := "zig", args := #["version"] }).trimAscii.toString
  let pqVersion := (← captureProc { cmd := "pg_config", args := #["--version"] }).trimAscii.toString
  -- Every Lean header (lean.h includes config.h, version.h and mimalloc.h),
  -- and the two libpq headers the glue reads.
  let leanHeaders ← ((← (leanInclude / "lean").readDir).map (·.path)).filterM fun p => return !(← p.isDir)
  let leanHeaders := leanHeaders.qsort (·.toString < ·.toString)
  let headers := leanHeaders ++ #[pqInclude / "libpq-fe.h", pqInclude / "postgres_ext.h"]
  let mut headerHashes := #[]
  for h in headers do
    headerHashes := headerHashes.push s!"{h} {hash (← IO.FS.readBinFile h)}"
  -- Fields joined by NUL, which no path, environment value or version holds.
  let config := "\x00".intercalate ([leanInclude.toString, pqInclude.toString, optimize, backend,
    zigTarget.getD "native", zigVersion, Lean.versionString, pqVersion] ++ headerHashes.toList)
  let lib := pkg.staticLibDir / nameToStaticLib "zsrv"
  buildFileAfterDep lib srcs (extraDepTrace := pure (BuildTrace.ofHash (Hash.ofString config))) fun _ => do
    proc { cmd := "zig", cwd := zigDir,
           args := #["build", s!"-Doptimize={optimize}", s!"-Dlinux-backend={backend}",
                     s!"-Dlean-include={leanInclude}",
                     s!"-Dpq-include={pqInclude}", "--prefix", (pkg.staticLibDir.parent.getD pkg.dir).toString,
                     "--prefix-lib-dir", pkg.staticLibDir.fileName.getD "lib"] ++
                   (zigTarget.map (#[s!"-Dtarget={·}"])).getD #[] }

-- The contracts: Query (database queries and results as values), Wire
-- (connection <-> protocol adapter) and Handler (adapter <-> application).
-- Query imports nothing; Wire and Handler import only Query.
lean_lib ServerContracts where
  roots := #[`Server.Query, `Server.Wire, `Server.Handler]

-- The transport's Lean side: the connection model and the FFI to the zio.ev
-- loop (zig/). Imports only Wire.
lean_lib ServerTransport where
  roots := #[`Server.Conn, `Server.Transport]

-- The HTTP/1.1 adapter (Std.Http.Protocol.H1, decision D1) and the response
-- writer; the hand-written parser as comparator and rollback. Import Wire and
-- Handler, never the transport.
lean_lib ServerHttp where
  roots := #[`Server.Response, `Server.H1Adapter, `Server.HandParser]

-- Example applications the tests and benchmarks run: import only
-- Server.Handler and the applications Arch.lean names for each.
lean_lib App where
  roots := #[`App.Hello, `App.Fixture, `App.Db, `App.Arena]

-- Tests and measurements.
lean_lib TestSupport where
  roots := #[`Corpus]

-- The server executables link libpq (zig/src/pg.zig, pg.c); bench.sh puts
-- its directory (pg_config --libdir) in LIBRARY_PATH.
@[default_target] lean_exe lsrv where
  root := `Main
  moreLinkArgs := #["-lpq"]

@[default_target] lean_exe «lsrv-db» where
  root := `MainDb
  moreLinkArgs := #["-lpq"]

@[default_target] lean_exe «lsrv-hand» where
  root := `MainHand
  moreLinkArgs := #["-lpq"]

-- HttpArena's HTTP/1.1 entry (item 53rwgc; README, "HttpArena on the VPS").
@[default_target] lean_exe «lsrv-arena» where
  root := `MainArena
  moreLinkArgs := #["-lpq"]

@[default_target] lean_exe «lsrv-fixture» where
  root := `Fixture
  moreLinkArgs := #["-lpq"]

@[default_target] lean_exe «lsrv-fixture-hand» where
  root := `FixtureHand
  moreLinkArgs := #["-lpq"]

/-- The test support in C that `lsrv-test` links: `lsrv_retained_bytes`, the
allocator blocks a Lean value holds, and `lsrv_byte_array_capacity` (README,
"Memory"). -/
target retained.o pkg : FilePath := do
  let src ← inputTextFile <| pkg.dir / "test" / "retained.c"
  buildLeanO (pkg.buildDir / "test" / "retained.o") src

@[default_target] lean_exe «lsrv-test» where
  root := `Test
  moreLinkObjs := #[retained.o]

@[default_target] lean_exe «lsrv-bench» where
  root := `Bench

-- The H1 parse path on HttpArena's request shapes, for profiling (item
-- r4q3yu; bench/parse/profile.sh).
@[default_target] lean_exe «lsrv-parsebench» where
  root := `ParseBench

@[default_target] lean_exe «lsrv-compare» where
  root := `Compare

@[default_target] lean_exe «lsrv-arch» where
  root := `Arch
  supportInterpreter := true
