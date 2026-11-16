import Serve

/-! The spike server: `Http.handle` on the zio.ev loops. -/

@[export ekk_conn_open] def connOpen (_ : UInt8) : Conn.State × Conn.Action := Serve.connOpen
@[export ekk_conn_on_recv]
def onRecv (now : UInt64) (s : Conn.State) (data : ByteArray) : Conn.State × Conn.Action :=
  Serve.onRecv handle now s data
@[export ekk_conn_on_sent]
def onSent (now : UInt64) (s : Conn.State) (n : USize) : Conn.State × Conn.Action :=
  Serve.onSent handle now s n
@[export ekk_conn_on_fail]
def onFail (s : Conn.State) : Conn.State × Conn.Action := Serve.onFail handle s

def main (args : List String) : IO UInt32 := Serve.main args
