Run the PostgreSQL glue tests against every supported libpq line, not only the installed one

qsqb5f made the pool depend on libpq's single-row mode in pipeline mode,
which earlier releases got wrong (the pool now requires libpq 14.6, 15.1 or
16 and later, zig/src/pg.c libpq_supported, checked in zig/src/serve.zig
ekk_serve). check.sh runs zig/src/pg_glue_test.c only against the libpq
`pg_config` names (18.6 on the development machine).

For qsqb5f the tests were run once by hand against libpq REL_14_6, REL_15_1,
REL_16_0 and REL_17_0, built from the PostgreSQL git tags with
`./configure --without-readline --without-icu --without-zlib --without-openssl`
and `make -C src/include install && make -C src/interfaces/libpq install`
into /tmp, then `zig build test -Dpq-include=... -Dpq-lib=...`; all four
passed and loaded the built library (checked with DYLD_PRINT_LIBRARIES).
Nothing keeps this true: a later change to pg.c's command-boundary state can
break an older line unseen.

Proposed: a script (or an optional check.sh stage) that builds libpq at the
lowest supported tag of each line (and the newest of each) into a cache
directory and runs `zig build test` against each, with the decision of
whether it is part of every item's gate or run at dependency updates only.
