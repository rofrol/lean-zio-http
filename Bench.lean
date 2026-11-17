import Corpus
import App.Hello

/-! `lsrv-bench`: both parsers in isolation on identical byte sequences
(Corpus.lean), without sockets or the loop.

The first table reports, for each sequence and parser, nanoseconds per call
(the median of five runs) and small-object allocations per call, read from the
runtime's heartbeat counter (`IO.getNumHeartbeats`: "the number of 'small'
memory allocations performed in a thread"; allocations too large for the
small allocator are not counted). `parse` is the parser alone; `handle` adds
the application (`App.Hello`) and the response bytes (`Server.Response`).

The second table is the fragmentation measurement decision D1 requires: a
request delivered in receives of `k` bytes, each fed to `Conn.step` as the
loop does. The hand-written parser parses the whole buffer again after every
receive; H1 keeps its machine between receives and parses again only the line
it is in the middle of (`Server.H1Adapter`). It reports the CPU time and
allocations for the whole request. The
transport's memory per connection does not depend on `k` (README, "Memory"):
the buffer is bounded by `inCap` whatever the split; what the split costs is
CPU and transient allocation, which this table measures.

A measurement only: `lsrv-test` checks that the two parsers consume the same
bytes of each sequence and that every fragmented request is answered, so
`check.sh` runs those checks and `bench.sh` runs this. Each row is printed
and flushed as soon as it is measured, so a run that prints nothing for
minutes is stuck, not measuring. -/

open Server

/-- Bytes the request consumes plus the response's size, or 0 when it needs more; also forces the result. -/
def consumedOf : Reply → Nat
  | .respond n r _ => n + r.size
  | _ => 0

/-- Prints a line and flushes it, so that each row appears as it is measured. -/
def say (line : String) : IO Unit := do
  let out ← IO.getStdout
  out.putStrLn line
  out.flush

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
  if acc == 0 then say "  (nothing consumed)"
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

/-- Size of the response to `b` fed in receives of `k` bytes, 0 when there is none. -/
def fragmentedSize {σ : Type} (ad : Adapter σ) (k : Nat) (b : ByteArray) : Nat :=
  ((Corpus.fragmented ad k b).map (·.size)).getD 0

def main : IO Unit := do
  let hand := HandParser.adapter {} App.Hello.app 0
  let h1 := H1Adapter.adapter {} App.Hello.app 0
  -- Each parser in one call, and a request fed through `Conn.step` in receives of `k` bytes.
  let adapters : List (String × (ByteArray → Nat) × (ByteArray → Reply) × (Nat → ByteArray → Nat)) :=
    [("hand-written", Corpus.handParse, (fun b => (hand.handle hand.init b).2), (fragmentedSize hand)),
     ("H1", Corpus.h1Parse, (fun b => (h1.handle h1.init b).2), (fragmentedSize h1))]
  say "request | bytes | parser | parse ns | parse allocs | handle ns | handle allocs"
  for (name, req) in Corpus.requests do
    let b := req.toUTF8
    let input ← IO.mkRef b
    let iters := 40000000 / (b.size + 200)
    for (pname, p, hdl, _) in adapters do
      let (pt, pa) ← timeIt p input iters
      let (ht, ha) ← timeIt (fun b => consumedOf (hdl b)) input iters
      say s!"{name} | {b.size} | {pname} | {fmt pt} | {fmt pa} | {fmt ht} | {fmt ha}"
  say ""
  say "fragmented request | bytes | receive size | parser | receives | ms per request | allocs per request"
  for (name, req) in Corpus.fragmentCorpus do
    let b := req.toUTF8
    let input ← IO.mkRef b
    for k in [1, 7, 64, 1460] do
      -- About 2 * 10^8 bytes parsed per run by a parser that reparses the buffer after each receive.
      let receives := (b.size + k - 1) / k
      let iters := max 1 (200000000 / (receives * b.size / 2 + 1))
      for (pname, _, _, frag) in adapters do
        let (t, a) ← timeIt (frag k) input iters
        say s!"{name} | {b.size} | {k} | {pname} | {receives} | {fmt (t / 1000000)} | {fmt a}"
