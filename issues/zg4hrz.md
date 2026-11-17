Pin the Linux validation container's base image and packages

Follow-up of ogcdwm (commit 264cb53): `./linux-check.sh` builds on `debian:trixie` and installs PostgreSQL 17 from apt, neither pinned, so a rebuild from scratch may test other versions. The script prints the versions and README says so.

Decided 2026-11-17 by the coordinating session under the user's delegation (small, reversible, test tooling only): pin the base image by digest (`debian:trixie@sha256:...`, with the date and tag noted next to it), and fail the run when the installed libpq/PostgreSQL major is not 17 or the Zig version differs from zig/build.zig.zon's minimum, so drift shows as a failure, not silently. Do not pin apt to snapshot.debian.org: that adds an external service to every run for little gain while the digest and the major check catch the drift that matters. Update README "Running".
