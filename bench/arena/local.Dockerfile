# The runtime image of bench/arena/local.sh (item 6p6tu6): HttpArena's load
# generator gcannon with liburing at the commits bench/arena/build.sh pins,
# and the tracing tools (bpftrace, perf), on this machine's architecture.
#
# The base image is linux/Dockerfile's debian:trixie index digest as of
# 2026-11-18 (item ugay7c); linux/Dockerfile is its source of truth: move
# this copy with it (lsrv-test, Test.lean's pinsAgree, checks it, and the
# liburing and gcannon commits against build.sh's). Debian's apt packages still float with the archive.
FROM debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      gcc libc6-dev libssl-dev make git ca-certificates curl procps libpq5 util-linux bpftrace linux-perf >/dev/null
RUN git clone -q https://github.com/axboe/liburing.git /liburing && cd /liburing \
    && git checkout -q 31a41935866867cdfedb4ef5a57ce0d15b50e5b9 \
    && ./configure --prefix=/usr >/dev/null && make -s -j"$(nproc)" -C src && make -s install -C src >/dev/null
RUN git clone -q https://github.com/MDA2AV/gcannon /gcannon && cd /gcannon \
    && git checkout -q fb63bf61387314aaaafe6b1fd890b2efc72f8c33 \
    && make -s clean && make -s -j"$(nproc)" && cp gcannon /usr/local/bin/
