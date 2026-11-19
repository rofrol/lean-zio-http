import Server.Conn
import Server.H1Adapter
import Server.HandParser
import App.Arena

/-! Byte sequences both parsers are measured and compared on (item 7bccgi):
the spike's test requests (Test.lean, bench/check) and a typical browser GET;
and the parsers' calls `lsrv-test` checks on them and `lsrv-bench` measures;
and HttpArena's request shapes with the H1 adapter's and lsrv-arena's calls on
them, which `lsrv-test` checks and `lsrv-parsebench` measures. -/

namespace Corpus

open Server

def big (n : Nat) : String := String.ofList (List.replicate n 'a')

/-- A head of exactly `maxHeadBytes` (8192) bytes before CRLFCRLF. -/
def maxHeadRequest : String :=
  let fixed := "GET / HTTP/1.1\r\nHost: a\r\nX: "
  fixed ++ big (maxHeadBytes - fixed.length) ++ "\r\n\r\n"

/-- The largest request the parsers accept: an 8192-byte head and an 8192-byte body. -/
def maxRequest : String :=
  let fixed := "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 8192\r\nX: "
  fixed ++ big (maxHeadBytes - fixed.length) ++ "\r\n\r\n" ++ big maxBodyBytes

/-- `n` header fields: Host and `n - 1` short ones. -/
def manyHeaders (n : Nat) : String := Id.run do
  let mut s := "GET / HTTP/1.1\r\nHost: a\r\n"
  for i in [1:n] do
    s := s ++ s!"X-{i}: v\r\n"
  return s ++ "\r\n"

/-- A GET as Chrome sends it for a page, with 16 header fields (the item asked for about 15). -/
def browserGet : String :=
  "GET /parafia/ogloszenia?tydzien=46 HTTP/1.1\r\n" ++
  "Host: ekklesiai.org\r\n" ++
  "Connection: keep-alive\r\n" ++
  "sec-ch-ua: \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"\r\n" ++
  "sec-ch-ua-mobile: ?0\r\n" ++
  "sec-ch-ua-platform: \"macOS\"\r\n" ++
  "Upgrade-Insecure-Requests: 1\r\n" ++
  "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36\r\n" ++
  "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7\r\n" ++
  "Sec-Fetch-Site: same-origin\r\n" ++
  "Sec-Fetch-Mode: navigate\r\n" ++
  "Sec-Fetch-User: ?1\r\n" ++
  "Sec-Fetch-Dest: document\r\n" ++
  "Referer: https://ekklesiai.org/parafia\r\n" ++
  "Accept-Encoding: gzip, deflate, br, zstd\r\n" ++
  "Accept-Language: pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7\r\n" ++
  "Cookie: session=4f2c9a7e1b3d5f60a8c2e4b6d8f0a1c3\r\n" ++
  "\r\n"

/-- The named byte sequences of the isolated measurement. -/
def requests : List (String × String) := [
  ("GET", "GET / HTTP/1.1\r\nHost: a\r\n\r\n"),
  ("HEAD", "HEAD / HTTP/1.1\r\nHost: a\r\n\r\n"),
  ("POST then pipelined GET", "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhelloGET / HTTP/1.1\r\nHost: a\r\n\r\n"),
  ("browser GET, 16 headers", browserGet),
  ("100 headers (the limit)", manyHeaders maxHeaders),
  ("largest head (8192 B)", maxHeadRequest),
  ("largest request (16388 B)", maxRequest)
]

/-- The sequences of the fragmentation table: a typical request and the largest ones. -/
def fragmentCorpus : List (String × String) :=
  requests.filter fun (n, _) => n == "browser GET, 16 headers" || n == "largest head (8192 B)" || n == "largest request (16388 B)"

/-- Bytes the hand-written parser consumes, its status on a rejection, or 0 when it needs more. -/
def handParse (b : ByteArray) : Nat :=
  match HandParser.parse b with
  | .needMore _ => 0
  | .bad s => s
  | .ok h => h.bodyStart + h.contentLength

/-- Bytes H1 consumes, its status on a rejection, or 0 when it needs more. -/
def h1Parse (b : ByteArray) : Nat :=
  match H1Adapter.parse b with
  | .needMore _ | .awaitingBody => 0
  | .bad s => s
  | .ok _ _ n _ => n

/-- Feeds `b` to a new connection in receives of `k` bytes, each through
`Conn.step` as the loop does; the response it sends after the last receive,
`none` if it sends one earlier, closes, or sends none. -/
def fragmented {σ : Type} (ad : Adapter σ) (k : Nat) (b : ByteArray) : Option ByteArray := Id.run do
  let mut s := Conn.initial ad
  let mut off := 0
  while off < b.size do
    let (s', a) := Conn.step ad 0 s (.received (b.extract off (min b.size (off + k))))
    off := off + k
    match a with
    | .recv _ => s := s'
    | .send d _ => return if off ≥ b.size then some d else none
    | _ => return none
  return none

/-! HttpArena's request shapes, which `lsrv-parsebench` measures (item
r4q3yu, for owgate): the bytes of one receive as lsrv-arena gets it in the
`bench/arena` runs. Baseline sends HttpArena's `requests/get.raw` and
`requests/post_cl.raw` (HttpArena da3ded60952b), one request per receive;
pipelined sends the request gcannon (fb63bf613873, `src/http.c`,
`http_build_pipeline`) writes for `http://127.0.0.1:8080/pipeline`, 16 times
in one write, read in one receive (the runs counted 0.066 `recvfrom` per
request; docs/reports/over-5s-tail.md, "What a pipelined response costs"). -/

/-- One receive of each shape, with the body App.Arena answers each request
of it with. -/
def arenaShapes : List (String × String × String) :=
  let pipeline := "GET /pipeline HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n"
  [("baseline-get", "GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost:8080\r\n\r\n", "55"),
   ("baseline-post", "POST /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost:8080\r\nContent-Length: 2\r\n\r\n20", "75"),
   ("pipelined", String.join (List.replicate 16 pipeline), "ok")]

/-- lsrv-arena's adapter (`MainArena.lean`). -/
def arenaAdapter : Adapter H1Adapter.Parser := H1Adapter.adapter {} App.Arena.app

/-- The adapter's parses of one receive `b`, as `Conn.serve` asks for them:
a new parser (`init`) on the buffer, then on the bytes after each complete
request (`buf.extract consumed buf.size`) until none are left. The number of
requests, or 0 when a parse is not a complete request. -/
def h1Receive (b : ByteArray) : Nat := Id.run do
  let mut buf := b
  -- Each complete request consumes at least one byte.
  for n in [0:b.size + 1] do
    if buf.size == 0 then return n
    match (H1Adapter.Parser.parse arenaAdapter.init buf).2 with
    | .ok _ _ c _ => if 0 < c && c ≤ buf.size then buf := buf.extract c buf.size else return 0
    | _ => return 0
  return 0

/-- Lsrv-arena's Lean side for one receive `b` on a kept-alive connection `s`
(`H1Adapter.adapter {} App.Arena.app`): `Conn.step` on the receive, then on
each send's completion, as the loop reports a send that wrote everything,
until the connection asks to receive again. The connection's state then and
the responses sent; `none` when it does anything else. -/
def arenaReceive (s : Conn.State H1Adapter.Parser) (b : ByteArray) :
    Option (Conn.State H1Adapter.Parser × Array ByteArray) := Id.run do
  let ad := arenaAdapter
  let mut (s, a) := Conn.step ad 0 s (.received b)
  let mut out := #[]
  -- At most one response per byte received.
  for _ in [0:b.size + 1] do
    match a with
    | .send d off =>
      out := out.push d
      (s, a) := Conn.step ad 0 s (.sent (d.size - off))
    | .recv _ => return some (s, out)
    | _ => return none
  return none

/-- A new connection of lsrv-arena's, before its first receive. -/
def arenaInitial : Conn.State H1Adapter.Parser := Conn.initial arenaAdapter

/-- Whether each shape is what `lsrv-parsebench` takes it for, on this
toolchain: every parse of its receive completes a request, and lsrv-arena's
Lean side answers the receive, twice on one connection, with one `200`
response per request, carrying the shape's body. The first failure, or
`none`. -/
def arenaShapesCheck : Option String := Id.run do
  for (name, req, body) in arenaShapes do
    let b := req.toUTF8
    let want := if name == "pipelined" then 16 else 1
    let n := h1Receive b
    if n != want then return some s!"{name}: the adapter parsed {n} complete requests, want {want}"
    let mut s := arenaInitial
    for round in [0:2] do
      let some (s', out) := arenaReceive s b
        | return some s!"{name}, receive {round}: the connection did not ask to receive again after answering"
      if out.size != want then return some s!"{name}, receive {round}: {out.size} responses, want {want}"
      for r in out do
        let r := String.fromUTF8! r
        -- The body is everything after the head's first empty line.
        let ok := match r.splitOn "\r\n\r\n" with
          | _ :: b :: rest => r.startsWith "HTTP/1.1 200 " && "\r\n\r\n".intercalate (b :: rest) == body
          | _ => false
        unless ok do
          return some s!"{name}, receive {round}: response {r.quote}, want 200 with body {body}"
      s := s'
  return none

end Corpus
