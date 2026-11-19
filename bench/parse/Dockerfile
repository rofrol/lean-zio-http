# The profiling image of bench/parse/profile.sh (item r4q3yu): linux/Dockerfile's
# image (tagged lsrv-linux-check, which profile.sh builds first), so the same
# base, Lean toolchain and glibc, with Debian's perf added. linux-perf comes
# from Debian's archive as of the build, not pinned, as bench/arena/local.Dockerfile's.
FROM lsrv-linux-check
USER root
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends linux-perf >/dev/null \
    && rm -rf /var/lib/apt/lists/*
