# HttpArena's load generator gcannon with liburing for bench/arena/build.sh,
# which builds it with `docker build --platform linux/amd64 --output` and
# passes the commits it pins as LIBURING_COMMIT and GCANNON_COMMIT. The last
# stage holds only the outputs: gcannon and lib/liburing.so.2.9 with its link
# lib/liburing.so.2. Its build context is bench/arena (gcannon-served.patch).
#
# The base image is linux/Dockerfile's debian:trixie index digest as of
# 2026-11-18 (item ugay7c); linux/Dockerfile is its source of truth: move
# this copy with it (lsrv-test, Test.lean's pinsAgree, checks it). Debian's apt packages still float with the archive.
# A docker build, unlike `docker run`, resolves the index for the requested
# platform: on OrbStack's classic image store, `docker run --platform
# linux/amd64` of this digest fails with "cannot overwrite digest" once the
# arm64 image is pulled under it.
FROM debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS build
ARG LIBURING_COMMIT
ARG GCANNON_COMMIT
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      gcc libc6-dev libssl-dev make git ca-certificates >/dev/null
RUN git clone -q https://github.com/axboe/liburing.git /liburing && cd /liburing \
    && git checkout -q "$LIBURING_COMMIT" \
    && ./configure --prefix=/usr >/dev/null && make -s -j"$(nproc)" -C src && make -s install -C src >/dev/null
# gcannon-served.patch adds the "Connections served" line (its header says why).
COPY gcannon-served.patch /gcannon-served.patch
RUN git clone -q https://github.com/MDA2AV/gcannon /gcannon && cd /gcannon \
    && git checkout -q "$GCANNON_COMMIT" && git apply /gcannon-served.patch \
    && make -s clean && make -s -j"$(nproc)"
RUN mkdir -p /dist/lib && cp /gcannon/gcannon /dist/ && cp /usr/lib/liburing.so.2.9 /dist/lib/ \
    && ln -s liburing.so.2.9 /dist/lib/liburing.so.2

FROM scratch
COPY --from=build /dist/ /
