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
