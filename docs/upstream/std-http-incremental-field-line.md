# Draft: upstream question for mxzlsx (Std.Http H1 reparses an unfinished field line)

Not posted. The coordinating session posts it on leanprover/lean4 (item mxzlsx).

## Notes for the poster (not part of the issue)

- Kind: a question, not a bug report. leanprover/lean4 has two issue templates
  at HEAD (`.github/ISSUE_TEMPLATE/bug_report.md`, `rfc.md`) and no template or
  contact link for questions; its CONTRIBUTING.md says "If you have found a bug
  or want to propose a change, please open an issue". The text below follows
  the bug report template's sections, the closest kind, with the question in
  "Description" and "Expected behavior". The bug report template applies the
  label `bug`; posting with `gh issue create` without `--template` leaves the
  label to the triage team, which matches a question better.
- An alternative venue is the Lean Zulip (the RFC template asks for prior
  discussion there); the owner decided on an issue.
- CONTRIBUTING.md asks PR authors to note generative-AI assistance. It does not
  say so for issues; the last line of the issue discloses it anyway. Confirm or
  edit it before posting.
- Prerequisite "Test your test case against the latest nightly": done with
  nightly-2026-11-17 locally, not on live.lean-lang.org.
- Duplicate check, 2026-11-17: `gh search issues|prs --repo leanprover/lean4`
  for "Std.Http needMoreData", "H1 Machine feed incremental", "Std.Http
  quadratic" found nothing; https://github.com/leanprover/lean4/issues/13469
  (Std.Http server throughput under concurrency) is unrelated, and
  https://github.com/leanprover/lean4/issues/16111 (closed by
  https://github.com/leanprover/lean4/pull/16362) is a correctness bug for a
  split inside the method name, not about cost.
- The reproducer is `docs/upstream/IncrementalFieldLine.lean` in this
  repository; the copy below is that file verbatim, and the outputs below are
  its runs on 2026-11-17 (M1 Pro, macOS 27.2).

---

**Title:** Std.Http H1: is an unfinished field line meant to be parsed incrementally across `Machine.feed` calls?

### Prerequisites

* [x] Check that your issue is not already filed:
      https://github.com/leanprover/lean4/issues
* [x] Reduce the issue to a minimal, self-contained, reproducible test case.
      Avoid dependencies to Mathlib or Batteries.
* [x] Test your test case against the latest nightly release (nightly-2026-11-17, locally)
* [ ] When reporting a perceived soundness bug: Does it affect `lake check --paranoid`? (not applicable)

### Description

This is a question about the intended contract of `Std.Http.Protocol.H1.Machine`, not a claim that it is wrong.

When a field line (or the request line) arrives over several `Machine.feed` calls, each `Machine.step` parses that line again from its first byte, since `parseWith` leaves the reader's input where it was when the parser hits the end of the buffered input. For a line of n bytes that arrives 1 byte per `feed`, with one `step` after each `feed`, the parser advances over about n²/2 bytes in total: 33,501,208 for one 8,185-byte field line, against 8,187 when the same bytes arrive in one `feed` (output below). With this feed/step pattern the configured limits (`maxHeaderValueLength`, `maxStartLineLength`, `maxHeaderBytes`) bound the total.

Is a field line or the start line meant to be parsed incrementally across `Machine.feed` calls, or is parsing it again from the line's start on every call the intended behavior?

What we found in the documentation, at HEAD (c2f30473d048afc28212e67ae39a0d11b0d4f30d) and the same text at nightly-2026-11-14:

- `Machine.feed` ([H1.lean:928-933](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1.lean#L928-L933)):
  > Feeds input bytes into the reader side of the machine.
- `Machine.step` ([H1.lean:2010-2013](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1.lean#L2010-L2013)):
  > Execute one step of the state machine.
- `Event.needMoreData` ([Event.lean:39-42](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1/Event.lean#L39-L42)):
  > Signals that additional input data is required to continue processing.

  The event is emitted on every `step` that still needs data (8,186 times in the 1-byte run below); the wording allows that.
- The private `parseWith` ([H1.lean:626-664](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1.lean#L626-L664)), which `processFieldLine` uses for each field line ([H1.lean:1882-1889](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1.lean#L1882-L1889)):
  > - On success, advances reader input.
  > - On EOF with open input, emits `needMoreData`.
- `manyItems` ([Parser.lean:67-74](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1/Parser.lean#L67-L74)), the only passage we found that names re-parsing; it covers chunk extensions and trailers, not field lines:
  > An item cut off by the end of the input fails with `.eof` instead of ending the list, so it is
  > re-parsed once the rest arrives.

None of these says whether the parse of an unfinished line is meant to resume where it stopped, or what a caller should expect it to cost. The module docs (`Std/Http.lean`, "Sans I/O Architecture") and `H1.Config`'s limits do not say either.

### Context

We use `H1.Machine` as the HTTP/1.1 parser of an event-loop server, one machine per incomplete request, fed only the bytes of each receive. In that server (compiled, CPU time per request, Apple M1, nightly-2026-11-14), a request whose head is almost all one 8 KiB header line costs 182 ms with H1 in 1-byte receives, against 116 ms with a hand-written parser that keeps no state and parses the whole buffer again on every receive. A head of the same size and shape followed by an 8 KiB body costs 195 ms with H1 in 1-byte receives against 758 ms: H1 consumes the body incrementally, and only the unfinished line is parsed again. We would like to know whether to document the cost of a long line in small receives as expected, or whether incremental parsing of a line is intended.

### Steps to Reproduce

1. Save the file below as `IncrementalFieldLine.lean` (Std only, no Lake project needed).
2. Run `lean --run IncrementalFieldLine.lean`.
3. Compare, for each line length, the row fed 1 byte per `feed` with the row fed in one `feed`.

The reproducer counts outside Std: before each `step` it replays, with the public `H1.parseSingleHeader` on the machine's public `reader.input`, the calls `processFieldLine` makes for this input (one field line, then the empty line, within the default limits), and adds up how far each call advances, as `parseWith` computes `usedBytes`/`usedBytesUntilFailure` (`remainingBytes` before minus after). That is a lower bound on the bytes the parser inspects. After each `step` it checks that the machine's input advanced exactly by what the replayed successful calls consumed. Timing, without the replay, is a second signal.

<details>
<summary>IncrementalFieldLine.lean</summary>

```lean
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
```

</details>

**Expected behavior:** we do not know; that is the question. If a line is meant to be parsed incrementally, the bytes scanned in 1-byte feeds would grow linearly with the line's length, as they do for a line fed at once.

**Actual behavior:** the bytes scanned grow with the square of the line's length (523,779 → 2,096,131 → 8,386,563 → 33,501,208 as the line doubles from 1,023 to 8,185 bytes), and so does the time (4.6 → 14.8 → 53.3 → 198 ms at nightly-2026-11-17), while one `feed` of the same bytes scans each byte once (0.12 ms).

At nightly-2026-11-14 (commit 62e0cf067af1febf28eee560a43bd4f72d23bfaa):

```
Lean 4.37.0-nightly-2026-11-14
value bytes | line bytes | feed size | feeds | bytes scanned | needMoreData events | head ended | best of 5, ms
1018 | 1023 | 1 | 1025 | 523779 | 1024 | true | 4.340042
1018 | 1023 | 1025 | 1 | 1025 | 0 | true | 0.037917
2042 | 2047 | 1 | 2049 | 2096131 | 2048 | true | 14.765542
2042 | 2047 | 2049 | 1 | 2049 | 0 | true | 0.066375
4090 | 4095 | 1 | 4097 | 8386563 | 4096 | true | 53.554125
4090 | 4095 | 4097 | 1 | 4097 | 0 | true | 0.132583
8180 | 8185 | 1 | 8187 | 33501208 | 8186 | true | 203.463125
8180 | 8185 | 8187 | 1 | 8187 | 0 | true | 0.270042
```

At nightly-2026-11-17 (commit 55069db87ef1cff027fd59149f022e63d6c5f1cf; its `src/Std/Http` is identical to master at c2f30473d048afc28212e67ae39a0d11b0d4f30d, 2026-11-17T13:41:34Z):

```
Lean 4.37.0-nightly-2026-11-17
value bytes | line bytes | feed size | feeds | bytes scanned | needMoreData events | head ended | best of 5, ms
1018 | 1023 | 1 | 1025 | 523779 | 1024 | true | 4.615500
1018 | 1023 | 1025 | 1 | 1025 | 0 | true | 0.022041
2042 | 2047 | 1 | 2049 | 2096131 | 2048 | true | 14.816542
2042 | 2047 | 2049 | 1 | 2049 | 0 | true | 0.033583
4090 | 4095 | 1 | 4097 | 8386563 | 4096 | true | 53.299625
4090 | 4095 | 4097 | 1 | 4097 | 0 | true | 0.062542
8180 | 8185 | 1 | 8187 | 33501208 | 8186 | true | 197.793167
8180 | 8185 | 8187 | 1 | 8187 | 0 | true | 0.124000
```

"line bytes" is the field line with its CRLF; "bytes scanned" is the sum of the parser's advance over the calls replayed (field line and final empty line; the request line and `Host` line, fed before, are not counted). Times are wall-clock, best of 5, under `lean --run` (the loop is interpreted, Std is compiled).

### Versions

Lean (version 4.37.0-nightly-2026-11-14, arm64-apple-darwin24.6.0, commit 62e0cf067af1febf28eee560a43bd4f72d23bfaa, Release)
Lean (version 4.37.0-nightly-2026-11-17, arm64-apple-darwin24.6.0, commit 55069db87ef1cff027fd59149f022e63d6c5f1cf, Release)
macOS 27.2 (Apple M1 Pro)

### Additional Information

The same applies to the request line, which `processReceivingStartLine` also parses through `parseWith` ([H1.lean:1751-1760](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1.lean#L1751-L1760)); the reproducer measures a field line only.

This issue was drafted with the help of an AI assistant (Claude); the reproducer was run and its output is pasted unchanged.

### Impact

Add :+1: to [issues you consider important](https://github.com/leanprover/lean4/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc). If others are impacted by this issue, please ask them to add :+1: to it.
