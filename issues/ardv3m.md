Fix the stale server_exports example in OwnFields' docstring

Seen by the coordinating session on 2026-11-17 after kvnm3u: Server/Response.lean:163 shows `server_exports (Server.H1Adapter.handle { fields := ... } app)`, but `server_exports` takes an adapter since daaqgn (`Server.H1Adapter.adapter own app`, Server/H1Adapter.lean:186-187; Server/Transport.lean:46). Correct the example to `Server.H1Adapter.adapter`; check the other docstrings and README for the same stale form. Approved 2026-11-17 by the coordinating session under the user's delegation (documentation only, no consult round).
