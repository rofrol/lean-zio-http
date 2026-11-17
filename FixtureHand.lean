import Server.Transport
import Server.HandParser
import App.Fixture

/-! `lsrv-fixture-hand`: `lsrv-fixture` with the hand-written parser
(`-fixture .lake/build/bin/lsrv-fixture-hand`). -/

server_exports (Server.HandParser.adapter { fields := #[("X-Robots-Tag", "noindex, nofollow")] } App.Fixture.app)

def main (args : List String) : IO UInt32 := Server.Transport.main args
