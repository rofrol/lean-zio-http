import Corpus
import Server.Conn
import Server.H1Adapter
import Server.HandParser
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

Exit status 1 when the two parsers do not consume the same bytes of a
sequence, or a fragmented request is not answered. -/

open Server

/-- Bytes the request consumes plus the response's size, or 0 when it needs more; also forces the result. -/
def consumedOf : Reply → Nat
  | .respond n r _ => n + r.size
  | _ => 0

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
  match HandParser.parse b with
  | .needMore => 0
  | .bad s => s
  | .ok h => h.bodyStart + h.contentLength

def h1Parse (b : ByteArray) : Nat :=
  match H1Adapter.parse b with
  | .needMore | .awaitingBody => 0
  | .bad s => s
  | .ok _ _ n _ => n

/-- Feeds `b` to a new connection in receives of `k` bytes; returns the size
of the response it sends, 0 if it sends none or closes. -/
def fragmented {σ : Type} (ad : Adapter σ) (k : Nat) (b : ByteArray) : Nat := Id.run do
  let mut s := Conn.initial ad
  let mut off := 0
  while off < b.size do
    let (s', a) := Conn.step ad s (.received (b.extract off (min b.size (off + k))))
    off := off + k
    match a with
    | .recv _ => s := s'
    | .send d _ => return if off ≥ b.size then d.size else 0
    | _ => return 0
  return 0

/-- The sequences of the fragmentation table: a typical request and the largest ones. -/
def fragmentCorpus : List (String × String) :=
  (Corpus.requests.filter fun (n, _) => n == "browser GET, 16 headers" || n == "largest head (8192 B)" || n == "largest request (16388 B)")

def main : IO UInt32 := do
  let mut failures := 0
  let hand := HandParser.adapter {} App.Hello.app 0
  let h1 := H1Adapter.adapter {} App.Hello.app 0
  -- Each parser in one call, and a request fed through `Conn.step` in receives of `k` bytes.
  let adapters : List (String × (ByteArray → Nat) × (ByteArray → Reply) × (Nat → ByteArray → Nat)) :=
    [("hand-written", handParse, (fun b => (hand.handle hand.init b).2), (fragmented hand)),
     ("H1", h1Parse, (fun b => (h1.handle h1.init b).2), (fragmented h1))]
  IO.println "request | bytes | parser | parse ns | parse allocs | handle ns | handle allocs"
  for (name, req) in Corpus.requests do
    let b := req.toUTF8
    let input ← IO.mkRef b
    let iters := 40000000 / (b.size + 200)
    if handParse b != h1Parse b then
      IO.println s!"FAIL {name}: hand-written consumes {handParse b}, H1 {h1Parse b}"
      failures := failures + 1
    for (pname, p, hdl, _) in adapters do
      let (pt, pa) ← timeIt p input iters
      let (ht, ha) ← timeIt (fun b => consumedOf (hdl b)) input iters
      IO.println s!"{name} | {b.size} | {pname} | {fmt pt} | {fmt pa} | {fmt ht} | {fmt ha}"
  IO.println ""
  IO.println "fragmented request | bytes | receive size | parser | receives | ms per request | allocs per request"
  for (name, req) in fragmentCorpus do
    let b := req.toUTF8
    let input ← IO.mkRef b
    for k in [1, 7, 64, 1460] do
      -- About 2 * 10^8 bytes parsed per run by a parser that reparses the buffer after each receive.
      let receives := (b.size + k - 1) / k
      let iters := max 1 (200000000 / (receives * b.size / 2 + 1))
      for (pname, _, _, frag) in adapters do
        if frag k b == 0 then
          IO.println s!"FAIL {name} in receives of {k} B through {pname}: no response"
          failures := failures + 1
        let (t, a) ← timeIt (frag k) input iters
        IO.println s!"{name} | {b.size} | {k} | {pname} | {receives} | {fmt (t / 1000000)} | {fmt a}"
  IO.println s!"{failures} failures"
  return if failures == 0 then 0 else 1
