import Server.Handler

/-! The benchmark application: `GET /` and `HEAD /` answer "Hello, World!",
everything else 404. It sees only `Server.Handler`. -/

namespace App.Hello

def textPlain : Array (String × String) := #[("Content-Type", "text/plain; charset=utf-8")]
def helloBody : ByteArray := "Hello, World!".toUTF8
def notFoundBody : ByteArray := "404 page not found\n".toUTF8

def respond (r : Server.Request) : Server.Response :=
  if r.target == "/" && (r.method == "GET" || r.method == "HEAD") then
    { status := 200, headers := textPlain, body := helloBody }
  else { status := 404, headers := textPlain, body := notFoundBody }

def app : Server.Handler := fun r => .done (respond r)

end App.Hello
