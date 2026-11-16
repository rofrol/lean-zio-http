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

/-- `libzsrv.a`, rebuilt when a file under `zig/` (sources, `build.zig`,
`build.zig.zon`), `ZIG_OPTIMIZE`, the Zig compiler's version, the Lean
toolchain's version or libpq's version (`pg_config --version`), or the paths
of the Lean and libpq include directories change. Header contents are traced
through those versions, not file by file. `ZIG_OPTIMIZE` picks the build of the loop and zio:
ReleaseSafe (bounds and overflow checks) unless set; it measured no slower
than ReleaseFast. -/
extern_lib zsrv (pkg) := do
  let zigDir := pkg.dir / "zig"
  let srcs ← inputDir zigDir (text := true) fun p =>
    -- Zig's caches and outputs and the fetched packages are not inputs;
    -- build.zig.zon pins zio by commit and hash.
    let under (d : String) := p.toString.startsWith ((zigDir / d).toString ++ "/")
    !(under "zig-out" || under ".zig-cache" || under "zig-pkg")
  let leanInclude ← getLeanIncludeDir
  let pqInclude := (← captureProc { cmd := "pg_config", args := #["--includedir"] }).trimAscii.toString
  let optimize := (← IO.getEnv "ZIG_OPTIMIZE").getD "ReleaseSafe"
  let zigVersion := (← captureProc { cmd := "zig", args := #["version"] }).trimAscii.toString
  let pqVersion := (← captureProc { cmd := "pg_config", args := #["--version"] }).trimAscii.toString
  let config := s!"{leanInclude} {pqInclude} {optimize} zig {zigVersion} lean {Lean.versionString} {pqVersion}"
  let lib := pkg.staticLibDir / nameToStaticLib "zsrv"
  buildFileAfterDep lib srcs (extraDepTrace := pure (BuildTrace.ofHash (Hash.ofString config))) fun _ => do
    proc { cmd := "zig", cwd := zigDir,
           args := #["build", s!"-Doptimize={optimize}", s!"-Dlean-include={leanInclude}",
                     s!"-Dpq-include={pqInclude}", "--prefix", (pkg.staticLibDir.parent.getD pkg.dir).toString,
                     "--prefix-lib-dir", pkg.staticLibDir.fileName.getD "lib"] }

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
-- Server.Handler and Server.Query (and each other).
lean_lib App where
  roots := #[`App.Hello, `App.Fixture, `App.Db]

-- Tests and measurements.
lean_lib TestSupport where
  roots := #[`Corpus]

-- The server executables link libpq (zig/src/pg.zig, glue.c); bench.sh puts
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

@[default_target] lean_exe «lsrv-fixture» where
  root := `Fixture
  moreLinkArgs := #["-lpq"]

@[default_target] lean_exe «lsrv-fixture-hand» where
  root := `FixtureHand
  moreLinkArgs := #["-lpq"]

@[default_target] lean_exe «lsrv-test» where
  root := `Test

@[default_target] lean_exe «lsrv-bench» where
  root := `Bench

@[default_target] lean_exe «lsrv-compare» where
  root := `Compare

@[default_target] lean_exe «lsrv-arch» where
  root := `Arch
  supportInterpreter := true
