import Server.Handler
import App.Hello

/-! The application of the boundary test's fixture servers (`lsrv-fixture`,
`lsrv-fixture-hand`): `App.Hello` with `/`'s body replaced by `body`, larger
than the loop's 8192-byte send buffer and no multiple of it, so every
response takes several sends and ends with a short one; `/too-big` answers a
body over `maxResponseBytes`, which the adapter must replace by 500; `POST /echo`
answers the request's body. -/

namespace App.Fixture

/-- 60,001 bytes: byte `i` is `a` + (i mod 26). bench/boundary expects exactly this. -/
def body : ByteArray := Id.run do
  let mut b := ByteArray.emptyWithCapacity 60001
  for i in [0:60001] do
    b := b.push (97 + (i % 26).toUInt8)
  return b

def app (r : Server.Request) : Server.Response :=
  if r.target == "/too-big" then
    { status := 200, headers := App.Hello.textPlain, body := ByteArray.mk (Array.replicate 70001 97) }
  else if r.target == "/echo" && r.method == "POST" then
    { status := 200, headers := App.Hello.textPlain, body := r.body }
  else match App.Hello.app r with
    | { status := 200, headers, .. } => { status := 200, headers, body }
    | other => other

end App.Fixture
