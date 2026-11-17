# The runtime image of bench/arena/local.sh (item 6p6tu6): HttpArena's load
# generator gcannon with liburing at the commits bench/arena/build.sh pins,
# and the tracing tools (bpftrace, perf), on this machine's architecture.
FROM debian:trixie
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      gcc libc6-dev libssl-dev make git ca-certificates curl procps libpq5 util-linux bpftrace linux-perf >/dev/null
RUN git clone -q https://github.com/axboe/liburing.git /liburing && cd /liburing \
    && git checkout -q 31a41935866867cdfedb4ef5a57ce0d15b50e5b9 \
    && ./configure --prefix=/usr >/dev/null && make -s -j"$(nproc)" -C src && make -s install -C src >/dev/null
RUN git clone -q https://github.com/MDA2AV/gcannon /gcannon && cd /gcannon \
    && git checkout -q fb63bf61387314aaaafe6b1fd890b2efc72f8c33 \
    && make -s clean && make -s -j"$(nproc)" && cp gcannon /usr/local/bin/
