import Server.Wire

/-! Byte sequences both parsers are measured and compared on (item 7bccgi):
the spike's test requests (Test.lean, bench/check) and a typical browser GET. -/

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

end Corpus
