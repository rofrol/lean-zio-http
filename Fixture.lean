import Server.Transport
import Server.H1Adapter
import App.Fixture

/-! `lsrv-fixture`: the boundary test's server (bench/boundary), `App.Fixture`
through `Std.Http.Protocol.H1`. The server's own responses carry
`X-Robots-Tag: noindex, nofollow`, which the boundary test checks on its 500. -/

server_exports (Server.H1Adapter.handle { fields := #[("X-Robots-Tag", "noindex, nofollow")] } App.Fixture.app)

def main (args : List String) : IO UInt32 := Server.Transport.main args
