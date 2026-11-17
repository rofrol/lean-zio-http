Collect PostgreSQL rows in chunks with libpq 17 as the minimum (xkkwcb)

The user decided on 2026-11-17 for item xkkwcb: raise the minimum libpq to 17. Implement chunked-rows collection (PQsetChunkedRowsMode) in place of single-row mode, under the conditions recorded in xkkwcb (consult round 20261117-065930-4e87):
- a chunk-size policy and tests that establish Query.maxResultBytes' bound, oversized single rows included (rejecting a chunk libpq already built does not keep the bound; state the residual libpq buffering);
- throughput, CPU and peak-memory comparisons with single-row mode on this repository's non-production benchmarks;
- pipeline command-boundary and error tests, as qsqb5f has for single-row mode;
- libpq_supported (zig/src/pg.c) and the start check in zig/src/serve.zig require 17+; README, the libpq matrix script (oruxe4) and its supported lines updated.
If the comparison shows chunked mode is not better, stop before integrating and file a Needs-a-decision item with the numbers. The finish message tells ekklesiai.org (consumer) that its host needs libpq 17 before it moves its pin.

Consumer host checked 2026-11-17 by the ekklesiai.org session: vps.frolow.dev (Debian 13) has libpq5 and libpq-dev 17.12-0+deb13u1, pg_config 17.12, and the production cluster is PostgreSQL 17, so the 17 minimum needs no host upgrade.
