import Corpus
import H1Adapter

/-! `lsrv-bench`: both parsers in isolation on identical byte sequences
(Corpus.lean), without sockets or the loop. For each sequence and parser it
reports nanoseconds per call (the median of five runs) and small-object
allocations per call, read from the runtime's heartbeat counter
(`IO.getNumHeartbeats`: "the number of 'small' memory allocations performed in
a thread"; allocations too large for the small allocator are not counted).
`parse` is the parser alone; `handle` adds routing and the response bytes,
built by `Http.respond` in both cases. Exit status 1 when the two parsers do
not consume the same bytes of a sequence. -/

/-- Bytes the request consumes, or 0 when it needs more; also forces the result. -/
def consumedOf : Reply → Nat
  | .needMore => 0
  | .respond n r _ => n + r.size

/-- Runs `f` on the bytes in `input` `iters` times; returns (ns per call, allocations per call).
The input is read from a reference on every iteration, so the call is not hoisted out of the loop. -/
def run (f : ByteArray → Nat) (input : IO.Ref ByteArray) (iters : Nat) : IO (Float × Float) := do
  let h0 ← IO.getNumHeartbeats
  let t0 ← IO.monoNanosNow
  let mut acc := 0
  for _ in [0:iters] do
    acc := acc + f (← input.get)
  let t1 ← IO.monoNanosNow
  let h1 ← IO.getNumHeartbeats
  if acc == 0 then IO.println "  (nothing consumed)"
  return ((t1 - t0).toFloat / iters.toFloat, (h1 - h0).toFloat / iters.toFloat)

def median (xs : Array Float) : Float :=
  let s := xs.qsort (· < ·)
  s[s.size / 2]!

def fmt (x : Float) : String :=
  let r := (x * 10).round / 10
  toString r

def timeIt (f : ByteArray → Nat) (input : IO.Ref ByteArray) (iters : Nat) : IO (Float × Float) := do
  discard <| run f input (iters / 10 + 1)
  let mut ts := #[]
  let mut allocs := 0.0
  for _ in [0:5] do
    let (t, a) ← run f input iters
    ts := ts.push t
    allocs := a
  return (median ts, allocs)

def handParse (b : ByteArray) : Nat :=
  match parse b with
  | .needMore => 0
  | .bad s => s
  | .ok h => h.bodyStart + h.contentLength

def h1Parse (b : ByteArray) : Nat :=
  match H1Adapter.parse b with
  | .needMore => 0
  | .bad s => s
  | .ok _ n _ => n

def main : IO UInt32 := do
  let mut failures := 0
  IO.println "request | bytes | parser | parse ns | parse allocs | handle ns | handle allocs"
  for (name, req) in Corpus.requests do
    let b := req.toUTF8
    let input ← IO.mkRef b
    let iters := 40000000 / (b.size + 200)
    if handParse b != h1Parse b then
      IO.println s!"FAIL {name}: hand-written consumes {handParse b}, H1 {h1Parse b}"
      failures := failures + 1
    for (pname, p, hdl) in [("hand-written", handParse, fun b => consumedOf (handle 0 b)),
                            ("H1", h1Parse, fun b => consumedOf (H1Adapter.handle 0 b))] do
      let (pt, pa) ← timeIt p input iters
      let (ht, ha) ← timeIt hdl input iters
      IO.println s!"{name} | {b.size} | {pname} | {fmt pt} | {fmt pa} | {fmt ht} | {fmt ha}"
  IO.println s!"{failures} failures"
  return if failures == 0 then 0 else 1
