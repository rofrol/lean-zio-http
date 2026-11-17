import Server.Transport
import Server.H1Adapter
import App.Arena

/-! `lsrv-arena`: `lsrv` serving `App.Arena`, HttpArena's HTTP/1.1 endpoints,
for the Linux runs of item 53rwgc (README, "HttpArena on the VPS"). -/

server_exports (Server.H1Adapter.adapter {} App.Arena.app)

def main (args : List String) : IO UInt32 := Server.Transport.main args
