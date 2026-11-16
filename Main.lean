import Server.Transport
import Server.H1Adapter
import App.Hello

/-! `lsrv`, the server: `Std.Http.Protocol.H1` (decision D1) serving
`App.Hello` on the zio.ev loops. -/

server_exports (Server.H1Adapter.handle {} App.Hello.app)

def main (args : List String) : IO UInt32 := Server.Transport.main args
