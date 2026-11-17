/-
Reproducer for docs/upstream/std-http-incremental-field-line.md: how many bytes
`Std.Http.Protocol.H1.Machine` parses for one long header field line when the
line arrives 1 byte per `feed` and when it arrives in one `feed`.

Self-contained, Std only. Run with any toolchain that has `Std.Http`:

    lean --run IncrementalFieldLine.lean

Counting stays outside Std. Before each `step`, while the machine is in
`needHeader`, it replays with the public `H1.parseSingleHeader` the calls the
machine's private `processFieldLine`/`processNeedHeader` make on the machine's
public `reader.input` (one call per field line until a call fails or reads the
empty line), and adds up the bytes each call scans, computed as `parseWith`
computes `usedBytes`/`usedBytesUntilFailure`. The parser is a pure function of
that input, so the machine's own calls scan the same bytes; the reproducer
checks that the machine's input then advanced exactly by what the replayed
successful calls consumed. Timing (no replay) is a second, independent signal.
-/
import Std.Http.Protocol.H1

open Std.Http.Protocol

/-- The start line and a `Host` field, fed first in every case. -/
def prefixBytes : ByteArray := "GET / HTTP/1.1\r\nHost: a\r\n".toUTF8

/-- One field line with a value of `n` bytes, then the empty line ending the head. -/
def fieldBytes (n : Nat) : ByteArray := ("X: ".pushn 'a' n ++ "\r\n\r\n").toUTF8

/-- Replays the header-field parse calls of one `step` on `it`: the bytes they
scan, and the bytes the successful calls consume. -/
partial def replay (cfg : H1.Config) (it : ByteArray.Iterator) (scanned consumed : Nat := 0) : Nat × Nat :=
  match H1.parseSingleHeader cfg it with
  | .success rest (some _) =>
    let n := it.remainingBytes - rest.remainingBytes
    replay cfg rest (scanned + n) (consumed + n)
  | .success rest none =>
    let n := it.remainingBytes - rest.remainingBytes
    (scanned + n, consumed + n)
  | .error rest _ => (scanned + (it.remainingBytes - rest.remainingBytes), consumed)

def isNeedHeader : H1.Reader.State .receiving → Bool
  | .needHeader _ => true
  | _ => false

def isEndHeaders : H1.Event .receiving → Bool
  | .endHeaders _ => true
  | _ => false

def isNeedMoreData : H1.Event .receiving → Bool
  | .needMoreData _ => true
  | _ => false

/-- The pieces `data` is fed in: `k` bytes each. -/
def pieces (data : ByteArray) (k : Nat) : Array ByteArray := Id.run do
  let mut out := #[]
  let mut i := 0
  while i < data.size do
    out := out.push (data.extract i (i + k))
    i := i + k
  return out

structure Count where
  feeds : Nat := 0
  scanned : Nat := 0
  needMoreData : Nat := 0
  headEnded : Bool := false

/-- Feeds the prefix at once, then the field line and the empty line in pieces
of `k` bytes, counting the bytes the header-field parser scans. -/
def count (n k : Nat) : IO Count := do
  let cfg : H1.Config := {}
  let mut m : H1.Machine .receiving := { config := cfg }
  m := m.feed prefixBytes
  let (m', _) := m.step
  m := m'
  unless isNeedHeader m.reader.state && m.reader.input.atEnd do
    throw <| IO.userError "the prefix did not leave the machine at a field line with no input"
  let mut c : Count := {}
  for piece in pieces (fieldBytes n) k do
    m := m.feed piece
    c := { c with feeds := c.feeds + 1 }
    if isNeedHeader m.reader.state then
      let before := m.reader.input.remainingBytes
      let (scanned, consumed) := replay cfg m.reader.input
      let (m', r) := m.step
      m := m'
      unless m.reader.input.remainingBytes + consumed == before do
        throw <| IO.userError s!"replay disagrees with the machine: consumed {consumed}, machine {before - m.reader.input.remainingBytes}"
      c := { c with
        scanned := c.scanned + scanned
        needMoreData := c.needMoreData + (r.events.filter isNeedMoreData).size
        headEnded := c.headEnded || r.events.any isEndHeaders }
    else
      throw <| IO.userError "fed after the head ended"
  return c

/-- Monotonic wall-clock time in ms of feeding the field line in pieces of `k`
bytes (no replay), the best of `runs`. -/
def time (n k : Nat) (runs : Nat := 5) : IO Float := do
  let cfg : H1.Config := {}
  let ps := pieces (fieldBytes n) k
  let mut best : Nat := 0
  for r in [0:runs] do
    let t0 ← IO.monoNanosNow
    let mut m : H1.Machine .receiving := { config := cfg }
    m := (m.feed prefixBytes).step.1
    let mut ended := false
    for piece in ps do
      let (m', res) := (m.feed piece).step
      m := m'
      ended := ended || res.events.any isEndHeaders
    let t1 ← IO.monoNanosNow
    unless ended do throw <| IO.userError "the head did not end"
    if r == 0 || t1 - t0 < best then best := t1 - t0
  return best.toFloat / 1.0e6

def main : IO Unit := do
  IO.println s!"Lean {Lean.versionString}"
  IO.println "value bytes | line bytes | feed size | feeds | bytes scanned | needMoreData events | head ended | best of 5, ms"
  for n in [1018, 2042, 4090, 8180] do
    let line := (fieldBytes n).size - 2
    for k in [1, (fieldBytes n).size] do
      let c ← count n k
      let ms ← time n k
      IO.println s!"{n} | {line} | {k} | {c.feeds} | {c.scanned} | {c.needMoreData} | {c.headEnded} | {ms}"
