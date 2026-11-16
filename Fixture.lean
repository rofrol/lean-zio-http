import Serve
import FixtureBody

/-! A test server for the Zig/Lean boundary (bench/boundary): `Http.handle`'s
framing and validation with one route, `GET /` and `HEAD /`, whose body is
`fixtureBody` (FixtureBody.lean). -/

def fixtureRoute (buf : ByteArray) (h : Head) : Nat × ByteArray × Bool :=
  match route buf h with
  | (200, _, isHead) => (200, fixtureBody, isHead)
  | other => other

def fixtureHandle (now : Nat) (buf : ByteArray) : Reply := handleWith fixtureRoute now buf

@[export ekk_conn_open] def connOpen (_ : UInt8) : Conn.State × Conn.Action := Serve.connOpen
@[export ekk_conn_on_recv]
def onRecv (now : UInt64) (s : Conn.State) (data : ByteArray) : Conn.State × Conn.Action :=
  Serve.onRecv fixtureHandle now s data
@[export ekk_conn_on_sent]
def onSent (now : UInt64) (s : Conn.State) (n : USize) : Conn.State × Conn.Action :=
  Serve.onSent fixtureHandle now s n
@[export ekk_conn_on_fail]
def onFail (s : Conn.State) : Conn.State × Conn.Action := Serve.onFail fixtureHandle s

def main (args : List String) : IO UInt32 := Serve.main args
