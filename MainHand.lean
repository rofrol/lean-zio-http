import Server.Transport
import Server.HandParser
import App.Hello

/-! `lsrv-hand`: `lsrv` with the hand-written parser, the rollback and
comparator kept until the Linux acceptance runs (decision D1). -/

server_exports (Server.HandParser.adapter {} App.Hello.app)

def main (args : List String) : IO UInt32 := Server.Transport.main args
