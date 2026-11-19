#!/bin/sh
# linux/run-images-test.sh: two overlapping runs of the image steps of
# bench/parse/profile.sh (item amjip6; linux/run-images.sh), each building
# linux/Dockerfile with its own marker appended (marker-a, marker-b) and
# bench/parse/Dockerfile on that base; each run's two containers must report
# that run's own marker, and each run's tags must be gone after it. The
# interleaving is forced, not hoped for: run A builds its base, then waits
# until run B has built its own base and its profiling image on it, run both,
# and ended (removing its tags); only then does A build its profiling image on
# its base and run its two images, which B's cleanup must have left alone.
# With a tag fixed across runs, A would run B's base (B retagged it) and
# build on it. Needs docker and, for a first build of the images, network
# access; later runs take every layer from docker's build cache.
set -eu
cd "$(dirname "$0")/.."

# expect FD WORD: reads the next line from FD; fails unless it is WORD.
expect() {
  read -r line <&"$1"
  [ "$line" = "$2" ] || { echo "expected '$2' from the other run, got '$line'" >&2; exit 1; }
}

# `run NAME WORK` (this script, started by itself in its own shell, so
# `set -e` holds in it): one run, as bench/parse/profile.sh's image steps,
# with marker-NAME appended to its copy of linux/Dockerfile; writes NAME.tag,
# NAME.base and NAME.profile in WORK. Run a writes `built` on FD 3 once its
# base is built and waits for run b's end on FD 4; run b waits for that
# `built` first. Each run writes `end STATUS` on its own FD (a: 3, b: 4) as
# it exits, after removing its tags, so a run that ends early wakes the run
# waiting on it instead of leaving it blocked.
if [ "${1-}" = run ]; then
  name=$2 work=$3
  case $name in a) fd=3 ;; *) fd=4 ;; esac
  . linux/run-images.sh
  # run_images_cleanup first, so it reads the run's status in $?.
  trap 'if run_images_cleanup; then s=0; else s=$?; fi; echo "end $s" >&$fd; exit "$s"' EXIT
  echo "$run_tag" >"$work/$name.tag"
  mkdir "$tmp/linux"
  cp linux/Dockerfile "$tmp/linux/Dockerfile"
  echo "RUN echo marker-$name >/home/check/marker" >>"$tmp/linux/Dockerfile"
  base=lsrv-linux-check:$run_tag image=lsrv-parse-profile:$run_tag
  [ "$name" = a ] || expect 3 built
  run_image_build "$base" "$tmp/linux"
  if [ "$name" = a ]; then echo built >&3; expect 4 "end 0"; fi
  run_image_build "$image" --build-arg BASE_IMAGE="$base" bench/parse
  docker run --rm --network none "$base" cat /home/check/marker >"$work/$name.base"
  docker run --rm --network none "$image" cat /home/check/marker >"$work/$name.profile"
  exit 0
fi

# On an early exit (an interrupt, say), each run still going is sent SIGTERM,
# which it turns into its own cleanup (linux/run-images.sh) once its current
# docker command ends, and is reaped before $work goes. The runs ignore
# SIGINT: they are started in the background.
work= pid_a= pid_b=
stop() {
  trap '' INT TERM
  for p in $pid_a $pid_b; do kill -TERM "$p" 2>/dev/null || true; done
  wait
  [ -z "$work" ] || rm -rf "$work"
}
trap stop EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d)
# One FIFO per run, held open for reading and writing here and in the runs,
# so a write never blocks and a line waits in it until read.
mkfifo "$work/a" "$work/b"
exec 3<>"$work/a" 4<>"$work/b"

sh linux/run-images-test.sh run a "$work" &
pid_a=$!
sh linux/run-images-test.sh run b "$work" &
pid_b=$!
status=0
wait "$pid_a" || { echo "run a failed"; status=1; }
pid_a=
wait "$pid_b" || { echo "run b failed"; status=1; }
pid_b=
[ "$status" = 0 ] || exit 1

for r in a b; do
  for i in base profile; do
    got=$(cat "$work/$r.$i")
    [ "$got" = "marker-$r" ] || { echo "run $r's $i image reports '$got', not marker-$r"; status=1; }
  done
  tag=$(cat "$work/$r.tag")
  for name in lsrv-linux-check lsrv-parse-profile; do
    if docker image inspect "$name:$tag" >/dev/null 2>&1; then
      echo "run $r left $name:$tag behind"; status=1
    fi
  done
done
[ "$status" = 0 ] && echo "overlapping runs: each ran its own images and removed only its own tags"
exit "$status"
