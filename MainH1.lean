import Serve
import H1Adapter

/-! `lsrv` (Main.lean) with `Std.Http.Protocol.H1` as the parser, through
`H1Adapter.handle`. -/

@[export ekk_conn_open] def connOpen (_ : UInt8) : Conn.State × Conn.Action := Serve.connOpen
@[export ekk_conn_on_recv]
def onRecv (now : UInt64) (s : Conn.State) (data : ByteArray) : Conn.State × Conn.Action :=
  Serve.onRecv H1Adapter.handle now s data
@[export ekk_conn_on_sent]
def onSent (now : UInt64) (s : Conn.State) (n : USize) : Conn.State × Conn.Action :=
  Serve.onSent H1Adapter.handle now s n
@[export ekk_conn_on_fail]
def onFail (s : Conn.State) : Conn.State × Conn.Action := Serve.onFail H1Adapter.handle s

def main (args : List String) : IO UInt32 := Serve.main args
