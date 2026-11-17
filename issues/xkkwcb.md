Collect PostgreSQL rows in chunks (PQsetChunkedRowsMode) once libpq 17 is the minimum

qsqb5f collects every result one row at a time (PQsetSingleRowMode), so
that a result over Query.maxResultBytes is refused before it is held whole.
Measured on the M1 with lsrv-db, 8 s runs, two rounds, rows of 100 bytes
from generate_series: server CPU per request rose from about 500 to 600 µs
at 1000 rows and 1 connection (+17-23%) and from about 600 to 750-770 µs at
64 connections (+23-28%), about 0.1-0.17 µs per row; 1 to 10 rows show no
change within noise. Each row costs a PGresult allocation in libpq.

libpq 17 adds PQsetChunkedRowsMode, which returns up to N rows per
PGresult with the same pipeline-mode rules. With it the per-row PGresult
cost is spread over N rows while the bound still holds within one chunk
(rows_take already accepts a result of several rows). It needs libpq 17 as
the minimum (now 14.6/15.1/16), which is the owner's call: a raised
requirement for deployments versus the measured cost on large results.
Option B of qsqb5f's options.

Checked 2026-11-17 with sol (consult round 20261117-065930-4e87): stays with the user, because it raises the libpq minimum ekklesiai.org must deploy (17). Before implementation it also needs a chunk-size policy with tests that establish the memory bound (oversized single rows included; rejecting a chunk libpq already built does not keep the bound), and throughput, CPU and peak-memory comparisons with single-row mode.
Question: Raise the minimum libpq to 17 to collect rows in chunks?
Options: keep single-row mode and the current minimum (14.6/15.1/16+) | raise the minimum to 17 once the VPS has it, then evaluate chunked mode as described
