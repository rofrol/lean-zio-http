# Draft: upstream feature request for jqzv42 (request-target count limits in H1.Config)

Not posted. The coordinating session posts it on leanprover/lean4 (item jqzv42).

## Notes for the poster (not part of the issue)

- Kind: a feature proposal. leanprover/lean4's template for it is
  `.github/ISSUE_TEMPLATE/rfc.md` at HEAD (title prefix `RFC: `, label `RFC`,
  sections Proposal, Community Feedback, Impact); CONTRIBUTING.md asks an RFC
  to answer User Experience, Beneficiaries, Community Feedback and
  Maintainability. The text below follows it.
- The RFC template says ideas "should be discussed on the Lean Zulip prior to
  submitting a proposal". No such discussion exists; "Community Feedback" says
  so. The owner decided on an issue; a Zulip thread first is the alternative.
- The last line discloses AI assistance (CONTRIBUTING.md requires that for
  PRs, not issues). Confirm or edit it before posting.
- Duplicate check, 2026-11-17: `gh search issues|prs --repo leanprover/lean4`
  for "maxQueryParams", "maxPathSegments", "requestTargetConfig" found nothing.
- The reproducer is `docs/upstream/TargetCount.lean` in this repository; the
  copy below is that file verbatim, and the outputs are its runs on 2026-11-17.
- The memory figures are this repository's ([Memory](../memory.md), "The adapter's
  state"; item jqzv42): 557,224 bytes is the derived bound of the parsed
  target's live blocks, 484,960 bytes what `lsrv-test` finds for 8,176 empty
  query parameters, 500.7 to 501.0 KiB the resident growth `bench/boundary`
  measured (M1, 2026-11-17).

---

**Title:** RFC: `maxPathSegments` and `maxQueryParams` in `Std.Http.Protocol.H1.Config`

### Proposal

`H1.Config` bounds the request-target only by its length, `maxUriLength`. The element counts the URI parser already supports (`URI.Config.maxPathSegments`, `URI.Config.maxQueryParams`, documented as "Prevents excessive segment counts that could arise from paths like `/a/b/c/…` repeated many times.", [Data/URI/Config.lean:67-81](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Data/URI/Config.lean#L67-L81)) are set to `maxUriLength` by `requestTargetConfig` ([Protocol/H1/Parser.lean:263-271](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1/Parser.lean#L263-L271), line 261 at nightly-2026-11-14), so a server cannot set them:

```lean
/--
The URI limits for a request-target. `maxUriLength` bounds the whole target, so no component limit
lower than it rejects a target the server accepts as a whole, which RFC 9112 §3 would answer with
`414`, not `400`. The host keeps its own limit, the length of a DNS name.
-/
def requestTargetConfig (limits : H1.Config) : URI.Config :=
  let n := limits.maxUriLength
  { maxSchemeLength := n, maxUserInfoLength := n, maxSegmentLength := n, maxQueryLength := n,
    maxFragmentLength := n, maxPathSegments := n, maxTotalPathLength := n, maxQueryParams := n }
```

We propose two fields in `H1.Config`, passed through by `requestTargetConfig`, with the status question answered by how their failure is classified:

```lean
/-- Maximum number of path segments in a request-target, counted as `URI.Config.maxPathSegments`
counts them (empty segments included); `none` keeps it at `maxUriLength`. -/
maxPathSegments : Option Nat := none
/-- Maximum number of query parameters in a request-target, counted as `URI.Config.maxQueryParams`
counts them (empty parameters included); `none` keeps it at `maxUriLength`. -/
maxQueryParams : Option Nat := none
```

- `requestTargetConfig` sets `URI.Config.maxPathSegments := limits.maxPathSegments.getD n` and `maxQueryParams := limits.maxQueryParams.getD n`. With the defaults nothing changes.
- A request-target over either count is refused with `414 URI Too Long`, like one over `maxUriLength`: `processReceivingStartLine` classifies the URI parser's "too many path segments" and "too many query parameters" failures ([Data/URI/Parser.lean:247-248, 268-269, 289-290](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Data/URI/Parser.lean#L247-L290)) as `.uriTooLong`, as `classifyStartLineHardError` does for "uri too long" ([Protocol/H1.lean:1731-1734](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1.lean#L1731-L1734)). Today they would fall through to `.badMessage`; a structured error from the URI parser would avoid matching on its message text. Tests would cover a target at each limit and one element over it, refused with `.uriTooLong`.

On the 414-versus-400 concern in the comment above: we propose that these configured count-limit failures get 414 rather than 400. The RFCs speak of length, not element counts, so this is an extension rather than a requirement, but a count limit the server sets is a limit on how much of an otherwise well-formed target it is willing to parse, which is what 414 reports, so we prefer it to the general 400. RFC 9112 §3: "A server that receives a request-target longer than any URI it wishes to parse MUST respond with a 414 (URI Too Long) status code"; RFC 9110 §15.5.15: "the server is refusing to service the request because the target URI is longer than the server is willing to interpret". 431 does not fit: RFC 6585 §5 defines it for header fields ("the server is unwilling to process the request because its header fields are too large"). With the defaults no target the server accepts as a whole is refused, so the concern in the comment holds unchanged for servers that do not set the fields.

The alternative available today, a lower `maxUriLength`, also refuses long targets with few elements (long tokens in a query string, for example).

- **User Experience**: a server can bound what a request-target costs in memory independently of how long a target it accepts. With the default `maxUriLength = 8192`, a server-side `H1.Machine` accepts a target of 8,176 query parameters or 8,177 path segments (reproducer below), each kept in the parsed `Request.Head` as its own objects. In our server, which keeps the machine while a request is incomplete, the parsed target is bounded by 557,224 bytes of live heap blocks per connection, derived from the runtime's object layouts, array growth and mimalloc's block sizes (about 48 bytes of blocks per element beyond its own bytes, plus its 8-byte slot in an array of up to twice the needed capacity). A request line whose target is 8,176 empty query parameters holds 484,960 bytes of live blocks for an 8 KiB line, measured by walking the objects reachable from the retained machine and adding `mi_usable_size` of each block; we measured 500.7 to 501.0 KiB of resident-set growth per connection holding such a line, across many connections (Apple M1, nightly-2026-11-14). At 4,096 connections the bound is about 2.1 GiB. These are figures for our runtime and allocator, not a property of Std. By the same derivation, limits of P path segments and Q query parameters would bound the target's part by about 64·(P + Q) bytes plus the target's own length.
- **Beneficiaries**: servers built on `Std.Http` (its own `Std.Http.Server` and servers that drive `H1.Machine` directly) that hold many connections with incomplete requests and need a per-connection memory bound.
- **Maintainability**: two optional fields and their use in `requestTargetConfig` and in the start-line error classification; the URI parser already enforces both counts. Note that `parseQuery` checks the parameter count after splitting the whole query (Data/URI/Parser.lean:287-290), so the limit bounds what the head retains, not the split's transient allocation.

Reproducer (`lean --run TargetCount.lean`, Std only):

<details>
<summary>TargetCount.lean</summary>

```lean
/-
Reproducer for docs/upstream/std-http-target-count-limits.md: with the default
`H1.Config`, a server-side `H1.Machine` accepts a request-target of one element
per byte, since `requestTargetConfig` sets `maxPathSegments` and
`maxQueryParams` to `maxUriLength`, and `H1.Config` has no field for them.

Self-contained, Std only:

    lean --run TargetCount.lean
-/
import Std.Http.Protocol.H1

open Std.Http Std.Http.Protocol

/-- The request-target of the head the machine accepts for `target`, or the
error it fails with. -/
def parse (target : String) : String := Id.run do
  let m : H1.Machine .receiving := { config := {} }
  let (_, r) := (m.feed s!"GET {target} HTTP/1.1\r\nHost: a\r\n\r\n".toUTF8).step
  for e in r.events do
    match e with
    | .endHeaders head =>
      match head.uri with
      | .originForm path query =>
        return s!"accepted: {path.segments.size} path segments, {(query.map (·.size)).getD 0} query parameters"
      | _ => return "accepted: another form"
    | .failed err => return s!"failed: {repr err}"
    | _ => pure ()
  return "no head"

def main : IO Unit := do
  let cfg : H1.Config := {}
  IO.println s!"Lean {Lean.versionString}; default maxUriLength = {cfg.maxUriLength}, maxStartLineLength = {cfg.maxStartLineLength}"
  -- The longest target the default start line allows: the line, its CRLF included, is
  -- `GET ` ++ target ++ ` HTTP/1.1\r\n`.
  let n := cfg.maxStartLineLength - "GET  HTTP/1.1\r\n".length
  IO.println s!"target \"/?\" ++ {n - 2} × \"&\" ({n} bytes): {parse ("/?".pushn '&' (n - 2))}"
  IO.println s!"target {n} × \"/\" ({n} bytes): {parse ("".pushn '/' n)}"
  IO.println s!"target \"/?\" ++ {n - 1} × \"&\" ({n + 1} bytes): {parse ("/?".pushn '&' (n - 1))}"
```

</details>

At nightly-2026-11-14 (commit 62e0cf067af1febf28eee560a43bd4f72d23bfaa):

```
Lean 4.37.0-nightly-2026-11-14; default maxUriLength = 8192, maxStartLineLength = 8192
target "/?" ++ 8175 × "&" (8177 bytes): accepted: 0 path segments, 8176 query parameters
target 8177 × "/" (8177 bytes): accepted: 8177 path segments, 0 query parameters
target "/?" ++ 8176 × "&" (8178 bytes): failed: Std.Http.Protocol.H1.Error.uriTooLong
```

At nightly-2026-11-17 (commit 55069db87ef1cff027fd59149f022e63d6c5f1cf; its `src/Std/Http` is identical to master at c2f30473d048afc28212e67ae39a0d11b0d4f30d, 2026-11-17T13:41:34Z):

```
Lean 4.37.0-nightly-2026-11-17; default maxUriLength = 8192, maxStartLineLength = 8192
target "/?" ++ 8175 × "&" (8177 bytes): accepted: 0 path segments, 8176 query parameters
target 8177 × "/" (8177 bytes): accepted: 8177 path segments, 0 query parameters
target "/?" ++ 8176 × "&" (8178 bytes): failed: Std.Http.Protocol.H1.Error.uriTooLong
```

The last row is refused by `maxStartLineLength`, which bounds the whole request line ([Protocol/H1.lean:1764-1765](https://github.com/leanprover/lean4/blob/c2f30473d048afc28212e67ae39a0d11b0d4f30d/src/Std/Http/Protocol/H1.lean#L1764-L1765)), and gets 414 as well.

### Community Feedback

None yet: this has not been discussed on Zulip. It came up while bounding the per-connection memory of a server that uses `H1.Machine`.

This proposal was drafted with the help of an AI assistant (Claude); the reproducer was run and its output is pasted unchanged.

### Impact

Add :+1: to [issues you consider important](https://github.com/leanprover/lean4/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc). If others benefit from the changes in this proposal being added, please ask them to add :+1: to it.
