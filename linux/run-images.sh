# Sourced, after `set -eu`, by the scripts that build and run images on this
# machine's docker (linux-check.sh, bench/arena/local.sh, bench/arena/build.sh,
# bench/parse/profile.sh; item amjip6). Several sessions and worktrees run
# them against one docker daemon at once, so an image tag fixed across runs
# lets one run's `docker build` retag the image another run is about to start
# or build on. Each run therefore tags its images NAME:$run_tag, a tag no
# other run uses, runs those tags, passes them on to the Dockerfiles that
# build on them (`ARG BASE_IMAGE`, `FROM ${BASE_IMAGE}`), and removes exactly
# the tags it built when it exits. A tag, not the ID that `docker build`
# prints: BuildKit resolves an ID in FROM as a name on Docker Hub. And the
# tag is set by `docker build -t` itself, not by a later `docker tag` of the
# ID: two runs building the same Dockerfile get the same image, which the
# other run's cleanup deletes when it removes the image's last tag.
#
# It makes the run's temporary directory $tmp; the tag is the directory's
# name, which mktemp draws at random and holds for the run (two runs with
# different TMPDIRs could draw the same name only by chance). It removes $tmp
# on exit and turns SIGINT and SIGTERM into an exit, so the cleanup runs
# once, and is not cut short by another signal. A tag the daemon sets after
# the cleanup, when an interrupt stopped `docker build` as it exported the
# image, is left behind: `docker image ls '*:run-*'` lists them.
tmp=
run_images=
# run_images_cleanup: removes this run's tags and $tmp; returns 0 when it
# could and the run's status was 0, else nonzero.
run_images_cleanup() {
  rib_status=$?
  trap '' INT TERM
  # Newest first: an image built on another goes before it. -f: a container
  # of this run that an interrupt left stopping still holds the image; -f
  # removes only this tag when the image has others.
  for rib_i in $run_images; do
    if docker image inspect "$rib_i" >/dev/null 2>&1; then
      docker image rm -f "$rib_i" >/dev/null || {
        echo "could not remove this run's image tag $rib_i" >&2
        [ "$rib_status" != 0 ] || rib_status=1
      }
    fi
  done
  if [ -n "$tmp" ] && ! rm -rf "$tmp"; then
    echo "could not remove this run's directory $tmp" >&2
    [ "$rib_status" != 0 ] || rib_status=1
  fi
  return "$rib_status"
}
# `exit $?`, not a bare `exit`: in an EXIT trap, bash's bare exit takes the
# status from before the trap.
trap 'run_images_cleanup || exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tmp=$(mktemp -d)
run_tag=run-${tmp##*/}

# run_image_build TAG DOCKER-BUILD-ARGUMENTS...: builds TAG (NAME:$run_tag),
# recorded first so that the cleanup also removes the tag of an interrupted
# build.
run_image_build() {
  rib_tag=$1
  shift
  case $rib_tag in
    *:"$run_tag") ;;
    *) echo "run_image_build: $rib_tag is not tagged with this run's tag $run_tag" >&2; exit 2 ;;
  esac
  run_images="$rib_tag $run_images"
  docker build -q -t "$rib_tag" "$@" >/dev/null
}
