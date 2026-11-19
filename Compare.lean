import Corpus
import Server.HandParser
import Server.H1Adapter

/-! `lsrv-compare`: the verdicts of the hand-written parser (`Server.HandParser.parse`)
and of `Std.Http.Protocol.H1` (`Server.H1Adapter.parse`) on the same bytes (item 7bccgi).

1. Properties over generated valid requests, for each parser: every proper
   prefix needs more bytes; the whole request is accepted with the generated
   method, target, Content-Length, Host (H1 only: the hand-written parser does
   not extract it) and connection-close decision, consuming exactly its bytes;
   the same holds with a second request pipelined after it.
2. Limits at their exact boundaries, each parser's own and the other's.
3. A fuzz run of malformed framing: generated requests with one malformed
   request line or header field from the lists below, and with one byte
   replaced, inserted or deleted at a random place.

The PRNG is seeded, so a run is reproducible. Every disagreement is printed,
grouped by the mutation that produced it (for a byte edit: the byte and the
part of the request it hit) and the two verdicts, with one example. Exit status 1 when a parser breaks a property of part 1, or a
boundary verdict differs from the one recorded below for it. -/

open Std.Http Std.Http.Protocol

/-! ## Verdicts -/

inductive V where
  | needMore
  /-- H1 only: the head asked for `100-continue` and the body is missing. -/
  | awaitingBody
  | bad (status : Nat)
  | ok (method target : String) (cl : Nat) (close : Bool) (consumed : Nat)
deriving BEq, Repr

def V.short : V → String
  | .needMore => "need-more"
  | .awaitingBody => "awaiting-body"
  | .bad s => s!"bad {s}"
  | .ok m t cl c n => s!"ok {m} {t} cl={cl} close={c} consumed={n}"

/-- The kind of a verdict and its status, without the request's fields. -/
def V.kind : V → String
  | .needMore => "need-more"
  | .awaitingBody => "awaiting-body"
  | .bad s => s!"{s}"
  | .ok .. => "ok"

def text (b : ByteArray) : String := String.fromUTF8Lossy b

def hand (b : ByteArray) : V :=
  match Server.HandParser.parse b with
  | .needMore _ => .needMore
  | .bad s => .bad s
  | .ok h => .ok (text (b.extract 0 h.methodEnd)) (text (b.extract h.targetStart h.targetEnd))
      h.contentLength h.close (h.bodyStart + h.contentLength)

def h1Host : ByteArray → Option String := fun b =>
  match Server.H1Adapter.parse b with
  | .ok h _ _ _ => (h.headers.get? Header.Name.host).map (·.value)
  | _ => none

def h1 (b : ByteArray) : V :=
  match Server.H1Adapter.parse b with
  | .needMore _ => .needMore
  | .awaitingBody => .awaitingBody
  | .bad s => .bad s
  | .ok h _ n close =>
    let cl := match H1.Message.Head.getSize (dir := .receiving) h true with
      | some (.fixed k) => k
      | _ => 0
    .ok (toString h.method) (toString h.uri) cl close n

/-! ## A seeded generator (xorshift64) -/

abbrev Gen := StateM UInt64

def next : Gen UInt64 := modifyGet fun (s : UInt64) =>
  let s := s ^^^ (s <<< 13)
  let s := s ^^^ (s >>> 7)
  let s := s ^^^ (s <<< 17)
  (s, s)

def below (n : Nat) : Gen Nat := return (← next).toNat % n

def pick [Inhabited α] (xs : Array α) : Gen α := return xs[← below xs.size]!

def chance (percent : Nat) : Gen Bool := return (← below 100) < percent

def randomCase (s : String) : Gen String := do
  let mut out := ""
  for c in s.toList do
    out := out.push (if ← chance 50 then c.toUpper else c.toLower)
  return out

def stringOf (alphabet : String) (lo hi : Nat) : Gen String := do
  let cs := alphabet.toList.toArray
  let n := lo + (← below (hi - lo + 1))
  let mut out := ""
  for _ in [0:n] do
    out := out.push (← pick cs)
  return out

def lowerAlnum := "abcdefghijklmnopqrstuvwxyz0123456789"
def unreserved := lowerAlnum ++ "-._~"
def tokenChars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
/-- Visible ASCII (field-vchar without obs-text). -/
def vchars : String := String.ofList ((List.range 94).map fun i => Char.ofNat (33 + i))

def ows : Gen String := do
  stringOf " \t" 0 2

/-- What a generated valid request must be accepted as. -/
structure Expected where
  method : String
  target : String
  cl : Nat
  host : Option String
  close : Bool

structure Generated where
  bytes : String
  expected : Expected

def genTarget : Gen String := do
  let n ← below 4
  let mut segs : Array String := #[]
  for _ in [0:n] do
    segs := segs.push (← stringOf unreserved 1 8)
  let path := "/" ++ "/".intercalate segs.toList
  if ← chance 25 then
    return path ++ "?" ++ (← stringOf lowerAlnum 1 5) ++ "=" ++ (← stringOf lowerAlnum 0 5)
  return path

def genValid : Gen Generated := do
  let method ← pick #["GET", "GET", "GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"]
  let target ← genTarget
  let v11 ← chance 80
  let host : Option String ←
    if v11 || (← chance 50) then some <$> pick #["a", "example.org", "ekklesiai.org:8080", "127.0.0.1", "[::1]:443"]
    else pure none
  let conn ← pick #[none, none, some "close", some "keep-alive", some "keep-alive, Close", some "Upgrade"]
  let conn ← match conn with
    | some c => some <$> randomCase c
    | none => pure none
  let bodySize ← if method == "POST" || method == "PUT" || method == "PATCH" then below 65 else pure 0
  let sendCL := bodySize > 0 || (← chance 20)
  let mut fields : Array String := #[]
  if let some h := host then fields := fields.push s!"{← randomCase "host"}:{← ows}{h}{← ows}"
  if let some c := conn then fields := fields.push s!"{← randomCase "connection"}:{← ows}{c}{← ows}"
  if sendCL then fields := fields.push s!"{← randomCase "content-length"}:{← ows}{bodySize}{← ows}"
  for _ in [0:(← below 13)] do
    let value ← if ← chance 20 then pure "" else do
      let first ← stringOf vchars 1 6
      if ← chance 50 then pure (first ++ " " ++ (← stringOf vchars 1 6)) else pure first
    fields := fields.push s!"X-{← stringOf tokenChars 1 10}:{← ows}{value}{← ows}"
  -- Shuffle the fields (Fisher-Yates).
  for i in [0:fields.size] do
    let j := i + (← below (fields.size - i))
    fields := fields.swapIfInBounds i j
  let tokens := (conn.getD "").toLower
  let hasClose := (tokens.splitOn ",").any (·.trimAscii.toString == "close")
  let hasKeepAlive := (tokens.splitOn ",").any (·.trimAscii.toString == "keep-alive")
  let head := s!"{method} {target} HTTP/1.{if v11 then 1 else 0}\r\n" ++
    String.join (fields.toList.map (· ++ "\r\n")) ++ "\r\n"
  return {
    bytes := head ++ Corpus.big bodySize
    expected := { method, target, cl := bodySize, host, close := hasClose || (!v11 && !hasKeepAlive) } }

/-! ## Part 1: properties over valid requests -/

structure Tally where
  failures : Nat := 0
  shown : Nat := 0

def Tally.fail (t : Tally) (msg : String) : IO Tally := do
  if t.shown < 10 then IO.println s!"  FAIL {msg}"
  return { failures := t.failures + 1, shown := t.shown + 1 }

def checkValid (name : String) (parser : ByteArray → V) (host? : Option (ByteArray → Option String))
    (g : Generated) (t : Tally) : IO Tally := do
  let mut t := t
  let b := g.bytes.toUTF8
  for k in [0:b.size] do
    let v := parser (b.extract 0 k)
    if v != .needMore then
      t ← t.fail s!"{name}: prefix {k} of {repr g.bytes}: {v.short}"
      break
  let e := g.expected
  let want := V.ok e.method e.target e.cl e.close b.size
  let got := parser b
  if got != want then
    t ← t.fail s!"{name}: {repr g.bytes}: {got.short}, want {want.short}"
  let piped := parser (b ++ "GET / HTTP/1.1\r\nHost: a\r\n\r\n".toUTF8)
  if piped != want then
    t ← t.fail s!"{name}: pipelined {repr g.bytes}: {piped.short}, want {want.short}"
  if let some hostOf := host? then
    if hostOf b != e.host then
      t ← t.fail s!"{name}: {repr g.bytes}: Host {hostOf b}, want {e.host}"
  return t

/-! ## Part 2: limits at their exact boundaries -/

/-- A request whose head (request line and fields, before CRLFCRLF) is `n` bytes. -/
def headOf (n : Nat) : String :=
  let fixed := "GET / HTTP/1.1\r\nHost: a\r\nX: "
  fixed ++ Corpus.big (n - fixed.length) ++ "\r\n\r\n"

/-- A request whose field lines count `n` bytes as H1 counts them (H1.lean:1947:
the bytes of each line, CRLF included). -/
def fieldBytesOf (n : Nat) : String :=
  -- "Host: a\r\n" is 9 bytes, "X: " and CRLF 5 more.
  "GET / HTTP/1.1\r\nHost: a\r\nX: " ++ Corpus.big (n - 14) ++ "\r\n\r\n"

def bodyOf (n : Nat) : String :=
  s!"POST / HTTP/1.1\r\nHost: a\r\nContent-Length: {n}\r\n\r\n" ++ Corpus.big n

/-- A request whose request line is `n` bytes, CRLF included, as H1 counts it
against `maxStartLineLength` (H1.lean:1862). -/
def requestLineOf (n : Nat) : String :=
  "GET /" ++ Corpus.big (n - 16) ++ " HTTP/1.1\r\nHost: a\r\n\r\n"

/-- Boundary cases with the verdict kind recorded for each parser. H1 alone
bounds the request line and the field lines separately; `H1Adapter.parse`
adds the bound on the whole head (`maxHeadBytes`), so both parsers refuse a
head over 8,192 bytes, H1 with its own 414 where its line limit comes first. -/
def boundaries : List (String × String × String × String) := [
  ("head of 8192 bytes", headOf 8192, "ok", "ok"),
  ("head of 8193 bytes", headOf 8193, "431", "431"),
  ("field lines of 8192 bytes (H1's count)", fieldBytesOf 8192, "431", "431"),
  ("field lines of 8193 bytes (H1's count)", fieldBytesOf 8193, "431", "431"),
  ("100 fields", Corpus.manyHeaders 100, "ok", "ok"),
  ("101 fields", Corpus.manyHeaders 101, "431", "431"),
  ("body of 8192 bytes", bodyOf 8192, "ok", "ok"),
  ("body of 8193 bytes", bodyOf 8193, "413", "413"),
  ("request line of 8192 bytes", requestLineOf 8192, "431", "431"),
  ("request line of 8193 bytes", requestLineOf 8193, "431", "414")
]

/-! ## Part 3: fuzzing malformed framing -/

def badRequestLines : Array String := #[
  "GET  / HTTP/1.1", "GET / HTTP/1.1 ", "GET / http/1.1", "GET / HTTP/1.10", "GET / HTTP/1.2",
  "GET / HTTP/2.0", "GET / HTTP/0.9", "GET /", "GET\t/ HTTP/1.1", "GET http://a/ HTTP/1.1",
  "CONNECT a:443 HTTP/1.1", "OPTIONS * HTTP/1.1", "GET * HTTP/1.1", "BREW / HTTP/1.1",
  "get / HTTP/1.1", "GET /a%zz HTTP/1.1", "GET /a b HTTP/1.1", "GET a HTTP/1.1",
  "GET /\x80 HTTP/1.1", "\r\nGET / HTTP/1.1", " GET / HTTP/1.1", "GET /a#f HTTP/1.1",
  "GET //a HTTP/1.1", "GET /a/../b HTTP/1.1", "GET /%41 HTTP/1.1", "GET /?a=b&c HTTP/1.1"]

def badFields : Array String := #[
  "Content-Length: 5", "Content-Length: 1, 1", "Content-Length: +5", "Content-Length: 05",
  "Content-Length: 99999999999", "Content-Length: 0x5", "Content-Length:", "Content-Length: 1 2",
  "Transfer-Encoding: chunked", "Transfer-Encoding: gzip, chunked", "Transfer-Encoding: chunked, gzip",
  "Transfer-Encoding: Chunked", "Transfer-Encoding:", "Transfer-Encoding: identity",
  " folded", "\tfolded", "Host: b", "Host:", "Host: a b", "Host: a:99999", "Host: a@b",
  "Bad Header: x", ": novalue", "X : y", "X:\x00y", "X: a\x7fb", "X: \x80\xff", "X: é",
  "Connection: close", "Connection: , close", "Connection: close;x", "Expect: 100-continue",
  "Expect: bogus", "X: " ++ Corpus.big 9000, "X" ++ Corpus.big 300 ++ ": y"]

def interesting : Array (UInt8 × String) := #[
  (13, "CR"), (10, "LF"), (32, "SP"), (9, "HTAB"), (58, "':'"), (0, "NUL"), (127, "DEL"),
  (128, "0x80"), (255, "0xFF"), (44, "','"), (48, "'0'"), (57, "'9'"), (47, "'/'"), (63, "'?'"), (37, "'%'")]

/-- The part of request `b` that byte `i` belongs to. -/
def regionAt (b : ByteArray) (i : Nat) : String := Id.run do
  let some he := Server.HandParser.findHeadEnd b (b.size + 1) | return "?"
  if i ≥ he + 4 then return "body"
  if i ≥ he + 2 then return "empty line"
  let mut ls := i
  while ls > 0 && b[ls - 1]! != 10 do ls := ls - 1
  let mut le := i
  while le < b.size && b[le]! != 13 do le := le + 1
  if i ≥ le then return if ls == 0 then "request-line CRLF" else "field CRLF"
  if ls == 0 then
    let mut sp := 0
    for k in [0:i] do
      if b[k]! == 32 then sp := sp + 1
    if b[i]! == 32 then return if sp == 0 then "SP after method" else "SP after target"
    return match sp with
      | 0 => "method"
      | 1 => "target"
      | _ => "version"
  let mut colon := ls
  while colon < le && b[colon]! != 58 do colon := colon + 1
  if i < colon then return "field name"
  if i == colon then return "colon"
  let name := (text (b.extract ls colon)).toLower
  let kind := if name == "host" || name == "connection" || name == "content-length" then name else "other field"
  let mut vs := colon + 1
  while vs < le && (b[vs]! == 32 || b[vs]! == 9) do vs := vs + 1
  let mut ve := le
  while ve > vs && (b[ve - 1]! == 32 || b[ve - 1]! == 9) do ve := ve - 1
  if i < vs then return s!"OWS before {kind} value"
  if i < ve then return s!"{kind} value"
  return s!"OWS after {kind} value"

/-- One template of malformed framing applied to a generated request. -/
def applyTemplate (g : Generated) (line? : Option String) (field? : Option String) : Gen ByteArray := do
  let mut s := g.bytes
  if let some line := line? then
    s := "\r\n".intercalate (line :: (s.splitOn "\r\n").drop 1)
  if let some field := field? then
    let lines := (s.splitOn "\r\n").toArray
    let headEnd := (lines.findIdx? (· == "")).getD lines.size
    let at_ := 1 + (← below (max 1 headEnd))
    s := "\r\n".intercalate (lines.insertIdxIfInBounds (min at_ headEnd) field).toList
  return s.toUTF8

/-- One byte replaced, inserted or deleted at a random place of a generated request. -/
def byteEdit (g : Generated) : Gen (ByteArray × String) := do
  let b := g.bytes.toUTF8
  let i ← below b.size
  let region := regionAt b i
  let (c, cname) ← pick interesting
  match ← below 3 with
  | 0 => return ((b.extract 0 i).push c ++ b.extract (i + 1) b.size, s!"{cname} replaces a byte of {region}")
  | 1 => return ((b.extract 0 i).push c ++ b.extract i b.size, s!"{cname} inserted in {region}")
  | _ =>
    let d := interesting.find? (·.1 == b[i]!) |>.map (·.2) |>.getD "a byte"
    return (b.extract 0 i ++ b.extract (i + 1) b.size, s!"{if d == "a byte" then d else d} deleted from {region}")

/-- Which accepted fields differ between two `ok` verdicts. -/
def diffFields : V → V → String
  | .ok m t cl c n, .ok m' t' cl' c' n' =>
    let ds := [("method", m != m'), ("target", t != t'), ("Content-Length", cl != cl'),
      ("close", c != c'), ("consumed", n != n')].filter (·.2) |>.map (·.1)
    s!" ({", ".intercalate ds} differ)"
  | _, _ => ""

structure Group where
  count : Nat
  example_ : String
  hand : String
  h1 : String

abbrev Groups := Std.HashMap String Group

/-- The bytes as a quoted string: printable ASCII as itself, every other byte as `\xHH`. -/
def escape (b : ByteArray) : String := Id.run do
  let hex := "0123456789abcdef".toList.toArray
  let mut out := "\""
  for c in b.toList do
    if c >= 32 && c < 127 && c != 92 && c != 34 then out := out.push (Char.ofNat c.toNat)
    else out := out ++ "\\x" ++ String.singleton hex[c.toNat / 16]! ++ String.singleton hex[c.toNat % 16]!
  return out ++ "\""

def record (groups : Groups) (label : String) (b : ByteArray) (vh v1 : V) : Groups :=
  let key := s!"{label} | hand-written {vh.kind} | H1 {v1.kind}{diffFields vh v1}"
  groups.alter key fun
    | some gr => some { gr with count := gr.count + 1 }
    | none => some { count := 1, example_ := ((escape b).take 240).toString, hand := vh.short, h1 := v1.short }

def printGroups (groups : Groups) : IO Unit := do
  for (key, gr) in groups.toArray.qsort (fun a b => a.1 < b.1) do
    IO.println s!"- {gr.count} × {key}\n    {gr.example_}\n    hand-written: {gr.hand}\n    H1: {gr.h1}"

def main : IO UInt32 := do
  let mut seed : UInt64 := 0x7bcc9100c0ffee
  -- Part 1
  IO.println "## Properties over valid requests"
  let mut tHand : Tally := {}
  let mut tH1 : Tally := {}
  let valid := 2000
  for _ in [0:valid] do
    let (g, s) := genValid.run seed
    seed := s
    tHand ← checkValid "hand-written" hand none g tHand
    tH1 ← checkValid "H1" h1 (some h1Host) g tH1
  IO.println s!"{valid} requests: hand-written {tHand.failures} failures, H1 {tH1.failures} failures"
  let mut failures := tHand.failures + tH1.failures
  -- Part 2
  IO.println "## Limits at their exact boundaries"
  for (name, req, wantHand, wantH1) in boundaries do
    let b := req.toUTF8
    let vh := hand b
    let v1 := h1 b
    let mark := if vh.kind == wantHand && v1.kind == wantH1 then "" else "FAIL "
    if mark != "" then failures := failures + 1
    IO.println s!"{mark}{name}: hand-written {vh.kind} (recorded {wantHand}), H1 {v1.kind} (recorded {wantH1})"
  -- Part 3
  IO.println "## Malformed request lines and fields, each on 40 generated requests"
  let perTemplate := 40
  let templates : Array (String × Option String × Option String) :=
    badRequestLines.map (fun l => (s!"request line {escape l.toUTF8}", some l, none)) ++
    badFields.map (fun f => (s!"field {escape (f.take 40).toString.toUTF8}", none, some f))
  let mut groups : Groups := {}
  let mut agree := 0
  for (label, line?, field?) in templates do
    for _ in [0:perTemplate] do
      let (g, s) := genValid.run seed
      let (b, s) := (applyTemplate g line? field?).run s
      seed := s
      let vh := hand b
      let v1 := h1 b
      if vh == v1 then agree := agree + 1
      else groups := record groups label b vh v1
  let total := templates.size * perTemplate
  IO.println s!"{total} requests: {agree} verdicts agree, {total - agree} differ, in {groups.size} groups"
  printGroups groups
  IO.println "## Single byte edits"
  let edits := 30000
  groups := {}
  agree := 0
  for _ in [0:edits] do
    let (g, s) := genValid.run seed
    let ((b, label), s) := (byteEdit g).run s
    seed := s
    let vh := hand b
    let v1 := h1 b
    if vh == v1 then agree := agree + 1
    else groups := record groups label b vh v1
  IO.println s!"{edits} requests: {agree} verdicts agree, {edits - agree} differ, in {groups.size} groups"
  printGroups groups
  IO.println s!"{failures} failures"
  return if failures == 0 then 0 else 1
