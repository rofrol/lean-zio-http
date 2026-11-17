Should the server enforce 504 for a query that expired, whatever the handler answers?

Seen in 3jnkx5 (commit 4fb22cc): a query's expiry reaches the handler as its
result (`abandoned 57014` or `error 57014`), and the 504 is the example app's
mapping (App/Db.lean, `status`). A handler may catch it and answer 200, or ask
another query. The design consultation (round 20261117-135106-f8bb, sol) said
an application mapping is not enforcement: if "expiry answers 504 when no header
was sent" is a server contract, the server must enforce it at the handler
boundary while still delivering the result. Decision needed: keep it as the
handler's policy (documented), or have the transport override the handler's
response after an expiry.
