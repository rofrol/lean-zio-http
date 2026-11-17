Decide whether the interim 100 Continue carries the own header fields

Needs a decision from the owner. Item k6oulx added `Server.Response.OwnFields`: header fields the composition root chooses, written on every final response the server writes itself (parser rejections, CONNECT's 501, the 500 replacing an invalid application response; `Server/Response.lean`, `OwnFields`). The interim `HTTP/1.1 100 Continue` (`Server.Response.continueBytes`, sent by `Server.H1Adapter.handle` for `Expect: 100-continue`) stays without them, by the reading that ekklesiai.org's ruling "every response carries X-Robots-Tag" means final responses; Sol (round 20261116-181702-3caa) agreed but advised confirming it with the consumer. An interim response is never indexed and clients drop its fields.
Question: Should the interim 100 Continue also carry the own fields?
Options: no, final responses only, as implemented (record the reading in ekklesiai.org's DECISIONS.md, "Search engine indexing") | yes, write them on 100 Continue too (`continueBytes` becomes a function of `own`)

Recommendation (consult round 20261116-183449-f682, sol, under the user's delegation of 2026-11-16): keep today's behavior (final responses only) pending ekklesiai.org's confirmation; it is not recorded as settled.

Checked 2026-11-17 with sol (consult round 20261117-011832-74e7) under the user's delegation: stays with the user: the consumer's confirmation and its decision record are in ekklesiai.org. Final responses only, as implemented, meanwhile.
