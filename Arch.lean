import Lean.Elab.ParseImportsFast

/-! `lsrv-arch`: the module boundaries of the server (docs/modules.md),
checked on the imports every Lean file of this package declares. Each module
may import only what its rule below allows; a file no rule names fails, so a
new module must be placed in the map before it builds into a passing check.
Run without an argument, it also compares the rules with the table of
docs/modules.md (`tableAgrees`). Run from the repository root (or pass the package directory); exit status 1 on any
violation. -/

open Lean

/-- Whether `n` is `pre` or lies under it. -/
def under (pre n : Name) : Bool := pre == n || pre.isPrefixOf n

/-- The library modules every server-side module may build on. -/
def contracts : List Name := [`Server.Query, `Server.Wire, `Server.Handler]

/-- What module `m` may import, or `none` when no rule names it. -/
def rule (m : Name) : Option (Name → Bool) :=
  match m with
  -- The contracts: queries as values import nothing; Wire and Handler only them.
  | `Server.Query => some fun _ => false
  | `Server.Wire | `Server.Handler => some (· == `Server.Query)
  -- The transport knows the wire limits and the connection model, not HTTP or the application.
  | `Server.Conn => some (· == `Server.Wire)
  | `Server.Transport => some (· ∈ [`Server.Wire, `Server.Conn])
  -- The HTTP adapters: the contracts and the response writer; only H1Adapter sees Std.Http.
  | `Server.Response => some (· ∈ contracts)
  | `Server.H1Adapter => some (· ∈ contracts ++ [`Server.Response, `Std.Http.Protocol.H1])
  | `Server.HandParser => some (· ∈ contracts ++ [`Server.Response])
  -- Composition roots: one transport, one adapter, one application each.
  | `Main | `Fixture | `MainDb | `MainArena => some fun i => i ∈ [`Server.Transport, `Server.H1Adapter] || under `App i
  | `MainHand | `FixtureHand => some fun i => i ∈ [`Server.Transport, `Server.HandParser] || under `App i
  -- The applications see the handler interface (and through it the query
  -- values), never the transport or an adapter. Each one is named with the
  -- imports it has: a new application fails until it is placed here.
  | `App.Hello | `App.Arena => some (· == `Server.Handler)
  | `App.Fixture | `App.Db => some (· ∈ [`Server.Handler, `App.Hello])
  -- Tests and measurement tools may import anything.
  | `Test | `Bench | `ParseBench | `Compare | `Corpus | `Arch => some fun _ => true
  -- Reproducers for upstream reports, run with `lean --run` and not built by
  -- Lake: Std's HTTP/1.1 machine alone, so each stays self-contained.
  | m => if under `docs.upstream m then some (· == `Std.Http.Protocol.H1) else none

/-- The `.lean` files under `dir`, skipping Lake's build directory, as module names. -/
partial def modules (root dir : System.FilePath) : IO (Array (Name × System.FilePath)) := do
  let mut out := #[]
  for e in ← dir.readDir do
    if e.fileName.startsWith "." then continue
    if ← e.path.isDir then
      out := out ++ (← modules root e.path)
    else if e.path.extension == some "lean" && e.fileName != "lakefile.lean" then
      let rel := (e.path.toString.drop (root.toString.length + 1)).toString
      let parts := ((rel.dropEnd 5).toString.splitOn "/")
      out := out.push (parts.foldl Name.str .anonymous, e.path)
  return out

/-- The names in backticks in a cell of docs/modules.md's table, each with
what it matches: `` `X` `` matches X, `` `X.*` `` what lies under X. -/
def ticked (cell : String) : List (String × (Name → Bool)) :=
  ((cell.splitOn "`").zipIdx.filter (·.2 % 2 == 1)).map fun (t, _) =>
    match t.dropSuffix? ".*" with
    | some pre => (t, under pre.toString.toName)
    | none => (t, fun n => n == t.toName)

/-- The comma-separated words of a cell outside its backticks. -/
def plainWords (cell : String) : List String :=
  ((cell.splitOn "`").zipIdx.filter (·.2 % 2 == 0)).flatMap fun (s, _) =>
    (s.splitOn ",").map (·.trimAscii.toString)

/-- What a cell of docs/modules.md's table names, as a predicate on modules:
`` `X` `` is X, `` `X.*` `` what lies under X, `contracts` the contracts and
`anything` every module (`nothing` names none). -/
def cellNames (cell : String) : Name → Bool :=
  let words := plainWords cell
  fun n => (ticked cell).any (·.2 n) || (words.contains "contracts" && contracts.contains n) ||
    words.contains "anything"

/-- docs/modules.md's table of the modules and what each may import must say
what `rule` says, for every module of the package and every import among the
package's modules and `Std.Http.Protocol.H1`; returns the disagreements. -/
def tableAgrees (doc : String) (mods : List Name) : List String := Id.run do
  let lines := (doc.splitOn "\n").filter (·.startsWith "| `")
  -- Each row as its line and its module and may-import cells.
  let rows := lines.filterMap fun line =>
    match line.splitOn "|" with
    | [_, who, _, may, _] => some (line, who, may)
    | _ => none
  let imports := `Std.Http.Protocol.H1 :: mods
  let mut out := (lines.filter fun l => (l.splitOn "|").length != 5).map
    (s!"docs/modules.md: cannot read `{·}`")
  for (line, who, may) in rows do
    -- Outside backticks the cells hold only these words.
    for w in plainWords who ++ plainWords may do
      unless ["contracts", "nothing", "anything", ""].contains w do
        out := out ++ [s!"docs/modules.md: unknown word `{w}` in `{line}`"]
    for (t, hit) in ticked who do
      unless mods.any hit do out := out ++ [s!"docs/modules.md: no module of the package is `{t}`"]
    for (t, hit) in ticked may do
      unless imports.any hit do out := out ++ [s!"docs/modules.md: `{t}` is no module this package may import"]
  for m in mods do
    match rows.filter (cellNames ·.2.1 m) with
    | [(_, _, may)] =>
      for i in imports do
        let doc := cellNames may i
        if (rule m).any (· i) != doc then
          out := out ++ [s!"docs/modules.md says {m} may{if doc then "" else " not"} import {i}; its rule in Arch.lean says otherwise"]
    | rs => out := out ++ [s!"docs/modules.md: {rs.length} rows name {m}, want 1"]
  return out

def main (args : List String) : IO UInt32 := do
  let root : System.FilePath := args.headD "."
  let mut failures := 0
  let mods ← modules root root
  -- The table is checked on this repository, not on a fixture package given
  -- as an argument.
  if args.isEmpty then
    for f in tableAgrees (← IO.FS.readFile "docs/modules.md") (mods.toList.map (·.1)) do
      IO.println s!"FAIL {f}"
      failures := failures + 1
  for (m, path) in mods.qsort (·.1.toString < ·.1.toString) do
    let header ← parseImports' (← IO.FS.readFile path) path.toString
    match rule m with
    | none =>
      IO.println s!"FAIL {m} ({path}): no boundary rule names this module"
      failures := failures + 1
    | some allowed =>
      for i in header.imports do
        -- `Init`, the prelude, is imported implicitly by every file.
        if i.module != `Init && !allowed i.module then
          IO.println s!"FAIL {m} imports {i.module}"
          failures := failures + 1
  IO.println s!"{mods.size} modules, {failures} violations"
  return if failures == 0 then 0 else 1
