import Server.Transport
import Server.H1Adapter
import App.Fixture

/-! `lsrv-fixture`: the boundary test's server (bench/boundary), `App.Fixture`
through `Std.Http.Protocol.H1`. -/

server_exports (Server.H1Adapter.handle App.Fixture.app)

def main (args : List String) : IO UInt32 := Server.Transport.main args
