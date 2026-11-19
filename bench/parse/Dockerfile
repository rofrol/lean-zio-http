# The profiling image of bench/parse/profile.sh (item r4q3yu): linux/Dockerfile's
# image, so the same base, Lean toolchain and glibc, with Debian's perf added.
# BASE_IMAGE is the tag of that image which profile.sh built first for its own
# run (linux/run-images.sh; item amjip6); there is no default, so a build
# without it fails instead of taking another run's image. linux-perf comes
# from Debian's archive as of the build, not pinned, as bench/arena/local.Dockerfile's.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends linux-perf >/dev/null \
    && rm -rf /var/lib/apt/lists/*
