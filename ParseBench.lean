import Corpus

/-! `lsrv-parsebench`: the H1 adapter's parse path as lsrv-arena drives it,
on HttpArena's baseline and pipelined request shapes (`Corpus.arenaShapes`),
without sockets or the loop (item r4q3yu, the harness of item owgate). Two
levels per shape, each one receive at a time:

- `parse`: the adapter's parses of the receive as `Conn.serve` asks for them
  (`Corpus.h1Receive`): a new `H1Adapter.Parser` on the buffer, then on the
  bytes after each request.
- `step`: lsrv-arena's whole Lean side (`Corpus.arenaReceive`): `Conn.step`
  with `H1Adapter.adapter {} App.Arena.app` on the receive and on each send's
  completion, on one kept-alive connection; so the parse, the application,
  the response's bytes and the connection's bookkeeping.

With no arguments it prints, per shape and level, nanoseconds per request
(the median of five runs) and small allocations per request (the runtime's
heartbeat counter, `IO.getNumHeartbeats`, as `lsrv-bench`). With `SHAPE LEVEL
RECEIVES` it runs that loop once, `RECEIVES` receives, for a profiler
(`bench/parse/profile.sh`), and prints its row.

Before measuring it checks that each shape is what it is taken for on this
toolchain (`Corpus.arenaShapesCheck`, which `lsrv-test` runs too), and every
measured receive must complete the shape's requests; else exit status 1. It
measures only: its figures are machine-dependent and draw no conclusion. -/

/-- Prints a line and flushes it, so that each row appears as it is measured. -/
def say (line : String) : IO Unit := do
  let out ← IO.getStdout
  out.putStrLn line
  out.flush

def levels : List String := ["parse", "step"]

/-- `receives` receives of the bytes in `input` at `level`; the
nanoseconds and small allocations they took, and how many did not complete
`want` requests. The input is read from a reference on every receive, so the
work is not hoisted out of the loop. -/
def runLevel (level : String) (input : IO.Ref ByteArray) (want receives : Nat) : IO (Nat × Nat × Nat) := do
  let h0 ← IO.getNumHeartbeats
  let t0 ← IO.monoNanosNow
  let mut bad := 0
  if level == "parse" then
    for _ in [0:receives] do
      if Corpus.h1Receive (← input.get) != want then bad := bad + 1
  else
    let mut s := Corpus.arenaInitial
    for _ in [0:receives] do
      match Corpus.arenaReceive s (← input.get) with
      | some (s', out) =>
        s := s'
        if out.size != want then bad := bad + 1
      | none => bad := bad + 1
  let t1 ← IO.monoNanosNow
  let h1 ← IO.getNumHeartbeats
  return (t1 - t0, h1 - h0, bad)

/-- One run; fails when a receive did not complete its requests. Nanoseconds
and allocations per request. -/
def perRequest (name level : String) (input : IO.Ref ByteArray) (want receives : Nat) : IO (Float × Float) := do
  let (t, a, bad) ← runLevel level input want receives
  if bad != 0 then throw <| IO.userError s!"{name} {level}: {bad} of {receives} receives did not complete {want} requests"
  let n := (receives * want).toFloat
  return (t.toFloat / n, a.toFloat / n)

def fmt (x : Float) : String := toString ((x * 10).round / 10)

def row (name level : String) (want : Nat) (t a : Float) : String :=
  s!"{name} | {level} | {want} | {fmt t} | {fmt a}"

def header : String := "shape | level | requests per receive | ns per request | allocs per request"

def usage : String :=
  s!"usage: lsrv-parsebench [SHAPE LEVEL RECEIVES]\n  SHAPE: {" ".intercalate (Corpus.arenaShapes.map (·.1))}\n  LEVEL: {" ".intercalate levels}"

def main (args : List String) : IO UInt32 := do
  if let some e := Corpus.arenaShapesCheck then
    IO.eprintln s!"lsrv-parsebench: {e}"
    return 1
  let shapes := Corpus.arenaShapes.map fun (name, req, _) =>
    (name, req.toUTF8, if name == "pipelined" then 16 else 1)
  match args with
  | [] =>
    say header
    for (name, b, want) in shapes do
      let input ← IO.mkRef b
      -- About 200,000 requests per run.
      let receives := 200000 / want
      for level in levels do
        discard <| perRequest name level input want (receives / 10)
        let mut ts := #[]
        let mut allocs := 0.0
        for _ in [0:5] do
          let (t, a) ← perRequest name level input want receives
          ts := ts.push t
          allocs := a
        say (row name level want (ts.qsort (· < ·))[2]! allocs)
    return 0
  | [shape, level, n] =>
    let some (name, b, want) := shapes.find? (·.1 == shape)
      | IO.eprintln usage; return 2
    let some receives := n.toNat?
      | IO.eprintln usage; return 2
    unless levels.contains level && 0 < receives do
      IO.eprintln usage; return 2
    let (t, a) ← perRequest name level (← IO.mkRef b) want receives
    say header
    say (row name level want t a)
    return 0
  | _ => IO.eprintln usage; return 2
