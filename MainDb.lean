import Server.Transport
import Server.H1Adapter
import App.Db

/-! `lsrv-db`: `App.Db` through `Std.Http.Protocol.H1` on the zio.ev loops,
with each loop's PostgreSQL pool (`--pg CONNINFO`, `--pg-conns N`). -/

server_exports (Server.H1Adapter.adapter {} App.Db.app)

def main (args : List String) : IO UInt32 := Server.Transport.main args
