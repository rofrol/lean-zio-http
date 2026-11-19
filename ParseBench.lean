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

With no arguments it then prints the `full` section (item vhvejg): for each
of `Corpus.fullCases`, a receive that fills the connection's buffer with one
small request pipelined, per receive (the median of five runs):

- `first step`: the one `Conn.step` on the receive, on a kept-alive
  connection waiting for it: it answers as many of the requests as fit in
  one send (`Conn.gather`), the longest step a connection of lsrv-arena's
  takes; with the responses in its send.
- `receive`: the whole receive as `step` above measures it, every step until
  the connection asks to receive again.
- `copy`: only the copies of the buffer's suffix that the first step makes,
  one `buf.extract consumed buf.size` per request it answers, with the bytes
  they copy.

Before measuring it checks that each shape is what it is taken for on this
toolchain (`Corpus.arenaShapesCheck` and `Corpus.fullCasesCheck`, which
`lsrv-test` runs too), and every measured receive must complete the shape's
requests; else exit status 1. It measures only: its figures are
machine-dependent and draw no conclusion. -/

/-- Prints a line and flushes it, so that each row appears as it is measured. -/
def say (line : String) : IO Unit := do
  let out ← IO.getStdout
  out.putStrLn line
  out.flush

def levels : List String := ["parse", "step"]

/-- `receives` receives of the bytes in `input` at `level`; the
nanoseconds and small allocations they took, and how many did not complete
`want` requests: at `step`, how many were not answered with `outBytes` bytes
of responses, the size of the `want` responses `Corpus.arenaShapesCheck`
finds in the answer to the receive (one send since item paarzq, so the
number of sends does not count the requests). The input is read from a
reference on every receive, so the work is not hoisted out of the loop. -/
def runLevel (level : String) (input : IO.Ref ByteArray) (want outBytes receives : Nat) : IO (Nat × Nat × Nat) := do
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
        if out.foldl (· + ·.size) 0 != outBytes then bad := bad + 1
      | none => bad := bad + 1
  let t1 ← IO.monoNanosNow
  let h1 ← IO.getNumHeartbeats
  return (t1 - t0, h1 - h0, bad)

/-- One run; fails when a receive did not complete its requests. Nanoseconds
and allocations per request. -/
def perRequest (name level : String) (input : IO.Ref ByteArray) (want receives : Nat) : IO (Float × Float) := do
  let outBytes := match Corpus.arenaReceive Corpus.arenaInitial (← input.get) with
    | some (_, out) => out.foldl (· + ·.size) 0
    | none => 0
  let (t, a, bad) ← runLevel level input want outBytes receives
  if bad != 0 then throw <| IO.userError s!"{name} {level}: {bad} of {receives} receives did not complete {want} requests"
  let n := (receives * want).toFloat
  return (t.toFloat / n, a.toFloat / n)

def fmt (x : Float) : String := toString ((x * 10).round / 10)

def row (name level : String) (want : Nat) (t a : Float) : String :=
  s!"{name} | {level} | {want} | {fmt t} | {fmt a}"

def header : String := "shape | level | requests per receive | ns per request | allocs per request"

def usage : String :=
  s!"usage: lsrv-parsebench [SHAPE LEVEL RECEIVES]\n  SHAPE: {" ".intercalate (Corpus.arenaShapes.map (·.1))}\n  LEVEL: {" ".intercalate levels}"

/-- What a full receive `b` is answered with,
outside the timed loops: the responses in the first step's send and that
send's bytes, and the bytes of every response of the receive; `none` when
the first step does not send or the receive is not answered (which
`Corpus.fullCasesCheck` rules out). The answer is a function of the bytes
(the clock is 0), so a timed receive answered with as many bytes is taken
to be answered with these, whose responses `Corpus.fullCasesCheck` checks
once. -/
def fullAnswer (b : ByteArray) : Option (Nat × Nat × Nat) :=
  match Server.Conn.step Corpus.arenaAdapter 0 Corpus.arenaInitial (.received b), Corpus.arenaReceive Corpus.arenaInitial b with
  | (_, .send d _), some (_, out) =>
    some (((String.fromUTF8! d).splitOn "HTTP/1.1 ").length - 1, d.size, out.foldl (· + ·.size) 0)
  | _, _ => none

/-- `receives` runs of one level of the `full` section on the bytes in
`input`; the nanoseconds they took, and how many did not do what the level
expects: a first step that sends `firstBytes` bytes and keeps the bytes
after `answered` requests of `len` bytes, a receive answered with `outBytes`
bytes, a copy chain that ends with the bytes after `answered` requests. -/
def runFull (level : String) (input : IO.Ref ByteArray) (len answered firstBytes outBytes receives : Nat) : IO (Nat × Nat) := do
  let t0 ← IO.monoNanosNow
  let mut bad := 0
  for _ in [0:receives] do
    let b ← input.get
    if level == "first step" then
      match Server.Conn.step Corpus.arenaAdapter 0 Corpus.arenaInitial (.received b) with
      | (s, .send d _) => if s.buf.size != b.size - answered * len || d.size != firstBytes then bad := bad + 1
      | _ => bad := bad + 1
    else if level == "receive" then
      match Corpus.arenaReceive Corpus.arenaInitial b with
      | some (_, out) => if out.foldl (· + ·.size) 0 != outBytes then bad := bad + 1
      | none => bad := bad + 1
    else
      let mut buf := b
      for _ in [0:answered] do
        buf := buf.extract len buf.size
      if buf.size != b.size - answered * len then bad := bad + 1
  let t1 ← IO.monoNanosNow
  return (t1 - t0, bad)

def fullLevels : List String := ["first step", "receive", "copy"]

def fullHeader : String := "case | requests per receive | responses in the first send | level | µs per receive | bytes copied"

/-- The `full` section: each case's levels, the median of five runs of
`receives` receives each. -/
def fullSection (receives : Nat) : IO Unit := do
  say fullHeader
  for (name, req, _, _) in Corpus.fullCases do
    let b := Corpus.fullReceive req
    let len := req.utf8ByteSize
    let total := b.size / len
    let some (answered, firstBytes, outBytes) := fullAnswer b
      | throw <| IO.userError s!"{name}: the first step sent nothing or the receive was not answered"
    -- The first step copies the suffix after each request it answers.
    let copied := (List.range answered).foldl (fun acc k => acc + (b.size - (k + 1) * len)) 0
    let input ← IO.mkRef b
    for level in fullLevels do
      discard <| runFull level input len answered firstBytes outBytes (receives / 10)
      let mut ts := #[]
      for _ in [0:5] do
        let (t, bad) ← runFull level input len answered firstBytes outBytes receives
        if bad != 0 then throw <| IO.userError s!"{name} {level}: {bad} of {receives} receives did not do what was expected"
        ts := ts.push (t.toFloat / receives.toFloat / 1000)
      let bytes := if level == "copy" then toString copied else "-"
      say s!"{name} | {total} | {answered} | {level} | {fmt (ts.qsort (· < ·))[2]!} | {bytes}"

def main (args : List String) : IO UInt32 := do
  if let some e := Corpus.arenaShapesCheck then
    IO.eprintln s!"lsrv-parsebench: {e}"
    return 1
  if let some e := Corpus.fullCasesCheck then
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
    say ""
    fullSection 2000
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
