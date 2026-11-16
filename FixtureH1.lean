import Serve
import FixtureBody
import H1Adapter

/-! `lsrv-fixture` (Fixture.lean) with `Std.Http.Protocol.H1` as the parser,
through `H1Adapter`: the same route and `fixtureBody`, for bench/boundary
(`-fixture lean/.lake/build/bin/lsrv-fixture-h1`). -/

def fixtureRoute (h : Std.Http.Request.Head) : Nat × ByteArray × Bool :=
  match H1Adapter.route h with
  | (200, _, isHead) => (200, fixtureBody, isHead)
  | other => other

def fixtureHandle (now : Nat) (buf : ByteArray) : Reply := H1Adapter.handleWith fixtureRoute now buf

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
