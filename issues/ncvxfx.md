Should a query whose deadline expires during the statement Close keep its known error?

Seen in 7mzw77 (commit b02bac9): when a cached statement fails with 0A000/26000, the pool closes the statement on the server (Close and Sync) before answering. If the query's deadline expires during that Close, the query is answered 57014 although its own error is already known. README "Statements" documents this as conservative. The run left it untested, saying a test would need a race with a 10 ms clock. Policy Rule 10 asks instead for an interleaving forced through a test hook (for example, holding the Close's reply in the fake `ekk_pg_collect` of zig/src/pg_test.zig until the expiry has run).

Options: (a) answer with the known error (and the right `error`/`abandoned` variant) when the expiry finds the query answered-but-closing, with a forced-order test | (b) keep 57014 and add only the forced-order test that pins the documented behaviour | (c) leave it as documented.
