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
