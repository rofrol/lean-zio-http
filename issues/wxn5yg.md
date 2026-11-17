Check mechanically that pg.c's EKK_MAX_RESULT_BYTES equals Query.maxResultBytes

Seen in 4ia52d: the bound a result is charged against is written twice, `def Query.maxResultBytes : Nat := 1048576` (Server/Query.lean) and `#define EKK_MAX_RESULT_BYTES 1048576` (zig/src/pg.c:19, commented "Query.maxResultBytes in lean/Server/Query.lean"). No test, build step or `lsrv-arch` check compares them (a search for both names finds only their definitions and uses), so changing one leaves the pool enforcing a bound other than the documented one.

Question: should the two be tied mechanically, and how?
Options: pass the Lean value into pg.c (an exported Lean constant the C reads, or a parameter of the pool's setup) so there is one definition | keep both and add a check (a Lean test or a boundary test reading the C value through an exported function) that fails when they differ | leave as is, documented as a duplicate
Recommendation: the second as the smaller change, unless qsqb5f's redesign of how a result is received already moves the bound's enforcement.
