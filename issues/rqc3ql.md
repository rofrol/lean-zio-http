Install bc in the Linux validation image, so bench.sh reports CPU per request there

Seen in item wi7efy (2026-11-17): `./bench.sh` run in the `lsrv-linux-check`
image (linux/Dockerfile) prints `./bench.sh: 47: bc: not found` (and at line
79) and an empty `cpu_us_per_req=` for every load run: bench.sh computes CPU
per request and lean's share of Go with `bc`, which the image does not
install. The load runs themselves pass. wi7efy measured both backends with an
awk stand-in for `bc` mounted into the container (outside the repository).

Proposed: add `bc` to linux/Dockerfile's packages (coordinate with item
zg4hrz, which pins that image's packages), or compute those figures in awk
in bench.sh, and say in README "Running" whether bench.sh is meant to run in
the container.

Decided 2026-11-17 by the coordinating session with sol (consult call 0925fa8f) under the user's delegation: approved with changes. Add bc to linux/Dockerfile, together with zg4hrz's pins; do not rewrite bench.sh's arithmetic. Make bench.sh fail clearly when bc is missing, rather than print empty figures. Say in README "Running" that bench.sh runs in the container. Acceptance: in the container, CPU per request and lean's share come out filled in.
