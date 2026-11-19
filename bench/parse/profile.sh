#!/bin/sh
# bench/parse/profile.sh OUT TARGET [SHAPE LEVEL RECEIVES]: a call-graph CPU
# profile of lsrv-parsebench (ParseBench.lean; item r4q3yu, the harness of
# item owgate) running one loop, SHAPE at LEVEL for RECEIVES receives
# (default: pipelined parse 200000; `lsrv-parsebench` with a wrong argument
# lists them). OUT is a new, empty directory. A diagnostic: it measures and
# concludes nothing. The profile covers the whole program, its startup check
# of the shapes included; the measured loop is what runs under `runLevel`.
# Fails, showing the program's output, unless the program printed the
# loop's row.
#
# TARGET m1 (macOS only): builds lsrv-parsebench from the working tree and
# records it with Instruments' Time Profiler (xctrace, Xcode): OUT/m1.trace
# (open it in Instruments), its time-profile table with every sample's
# backtrace (OUT/m1-time-profile.xml) and the program's output (OUT/m1-run.txt).
#
# TARGET linux: builds lsrv-parsebench from the working tree (tracked files
# and untracked ones git does not ignore) in linux/Dockerfile's image, as
# ./linux-check.sh does, then records it with perf (frame-pointer call
# graphs) in bench/parse/Dockerfile's image, which is that image with perf,
# in a privileged container (perf_event_open). OUT/linux-perf.data, its
# reports with and without the callees' samples included
# (OUT/linux-children.txt, OUT/linux-self.txt), the program's output
# (OUT/linux-run.txt), and the binary (OUT/b/lsrv-parsebench) to read the
# data again in an image built as this one (the run's own images are untagged
# when it ends: linux/run-images.sh). perf report's own messages go to
# OUT/linux-report.log. On the M1 (Debian trixie's perf, arm64), item
# owgate's run of 2026-11-19 (pipelined parse, 1,000,000 receives, 42 K
# samples) wrote 168,206 lines of "unwind: get_proc_name unsupported" there
# for its two reports, about two per sample in each, while 99.99 % of the
# samples in OUT/linux-children.txt still had their whole chain up to
# `_lean_main` (99.6 % in the harness's first runs, item r4q3yu, whose count
# of these lines was not recorded): docs/reports/h1-parse-profile.md,
# "Anomalies met". Needs docker and, for a first build of the
# images, network access. Written for the M1's OrbStack, as
# bench/arena/local.sh: on a Linux host's docker, the container's users may
# not be able to write to OUT.
set -eu
usage() { echo "usage: $0 OUT m1|linux [SHAPE LEVEL RECEIVES]"; exit 2; }
[ $# -eq 2 ] || [ $# -eq 5 ] || usage
out=$1 target=$2 shape=pipelined level=parse receives=200000
[ $# -eq 2 ] || { shape=$3 level=$4 receives=$5; }
# Each argument passed on is one of a fixed set, or digits.
case $shape in baseline-get | baseline-post | pipelined) ;; *) usage ;; esac
case $level in parse | step) ;; *) usage ;; esac
case $receives in '' | *[!0-9]*) usage ;; esac
case $receives in *[1-9]*) ;; *) usage ;; esac
[ -d "$out" ] && [ -z "$(ls -A "$out")" ] || { echo "$out must be an empty directory"; exit 2; }
out=$(cd "$out" && pwd)
cd "$(dirname "$0")/../.."
# row FILE: shows the program's output; fails unless it holds the loop's row.
row() {
  cat "$1"
  grep -q "^$shape | $level | " "$1" || { echo "lsrv-parsebench printed no $shape $level row"; exit 1; }
}

case $target in
m1)
  [ "$(uname -s)" = Darwin ] || { echo "the m1 target runs on macOS"; exit 2; }
  . bench/lib.sh
  lake build lsrv-parsebench >"$out/m1-build.log" 2>&1 || { tail -20 "$out/m1-build.log"; exit 1; }
  xctrace record --quiet --template 'Time Profiler' --output "$out/m1.trace" --target-stdout "$out/m1-run.txt" \
    --launch -- "$PWD/.lake/build/bin/lsrv-parsebench" "$shape" "$level" "$receives" || { cat "$out/m1-run.txt"; exit 1; }
  row "$out/m1-run.txt"
  xctrace export --input "$out/m1.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' >"$out/m1-time-profile.xml"
  ;;
linux)
  mkdir "$out/b"
  . linux/run-images.sh
  git ls-files -z --cached --others --exclude-standard >"$tmp/files"
  COPYFILE_DISABLE=1 tar --null -T "$tmp/files" -cf "$tmp/tree.tar"
  # bench/parse/Dockerfile builds on this run's base (BASE_IMAGE).
  base=lsrv-linux-check:$run_tag image=lsrv-parse-profile:$run_tag
  run_image_build "$base" linux
  run_image_build "$image" --build-arg BASE_IMAGE="$base" bench/parse
  docker run --rm -v lsrv-linux-cache:/home/check/.cache -v "$tmp/tree.tar:/tree.tar:ro" -v "$out/b:/out" \
    "$base" sh -c '
    set -eu
    mkdir src && tar --warning=no-unknown-keyword -xf /tree.tar -C src
    cd src && . bench/lib.sh
    lake build lsrv-parsebench >/out/build.log 2>&1 || { tail -20 /out/build.log; exit 1; }
    cp .lake/build/bin/lsrv-parsebench /out/lsrv-parsebench'
  docker run --rm --privileged --user root -v "$out:/out" "$image" \
    sh -c 'set -eu
    perf record -q -F 999 -g -o /out/linux-perf.data -- /out/b/lsrv-parsebench "$@" >/out/linux-run.txt 2>&1 ||
      { cat /out/linux-run.txt; exit 1; }
    perf report -i /out/linux-perf.data --stdio --children >/out/linux-children.txt 2>/out/linux-report.log &&
      perf report -i /out/linux-perf.data --stdio --no-children >/out/linux-self.txt 2>>/out/linux-report.log ||
      { cat /out/linux-run.txt /out/linux-report.log; exit 1; }' \
    sh "$shape" "$level" "$receives"
  row "$out/linux-run.txt"
  ;;
*) usage ;;
esac
