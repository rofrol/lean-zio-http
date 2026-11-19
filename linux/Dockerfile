# The Linux validation host (item ogcdwm): Debian trixie with the tools
# ./check.sh and ../bench.sh need (bc: bench.sh's CPU per request and
# lean's share of Go; item rqc3ql). Pinned by version and SHA-256: Zig (the version the macOS
# runs use), the Lean toolchain named by lean-toolchain and Go
# (bench/*/go.mod). The base image is pinned by its digest (item zg4hrz).
# PostgreSQL 17 (libpq and the server for the private cluster) comes from
# Debian's archive as of the build, not pinned to a snapshot: a minor
# release may differ between builds, and ../linux-check.sh fails the run when
# libpq's or the server's major is not 17. ../linux-check.sh builds it,
# prints the versions and runs ./check.sh in it; it checks that
# lean-toolchain still names LEAN_NIGHTLY and that Zig is on
# zig/build.zig.zon's minimum_zig_version line. Update a version and its
# sums together. It builds for arm64 and x86_64 hosts.
#
# debian:trixie as of 2026-11-18 (the multi-architecture index; its
# manifests' annotations say created 2026-11-04; Debian 13.7): to update,
# take the index digest that `docker buildx imagetools inspect debian:trixie`
# prints and the date, and move the digest and date of its copies in
# ../bench/arena/local.Dockerfile and ../bench/arena/gcannon.Dockerfile with
# them (item ugay7c).
FROM debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils zstd git bc \
      libpq-dev postgresql-17 postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.17.1
ARG ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
ARG ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ARG LEAN_NIGHTLY=nightly-2026-11-19
ARG LEAN_VERSION=4.38.0-nightly-2026-11-19
ARG LEAN_SHA256_AARCH64=d579a484d419b62d6bb99e43a8a4aeaaebb808564b452fe37919ea74d50cb513
ARG LEAN_SHA256_X86_64=f3db8a88c495a9fd5d9e4f1602036f81d32d6a777ee6bc290a1ace21341f9ce5
ARG GO_VERSION=1.27.3
ARG GO_SHA256_ARM64=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49
ARG GO_SHA256_AMD64=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40

RUN set -eu; \
    case "$(uname -m)" in \
      aarch64) zarch=aarch64; zsum=$ZIG_SHA256_AARCH64; lsuf=_aarch64; lsum=$LEAN_SHA256_AARCH64; garch=arm64; gsum=$GO_SHA256_ARM64 ;; \
      x86_64) zarch=x86_64; zsum=$ZIG_SHA256_X86_64; lsuf=; lsum=$LEAN_SHA256_X86_64; garch=amd64; gsum=$GO_SHA256_AMD64 ;; \
      *) echo "unsupported architecture $(uname -m)"; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLo zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-$zarch-linux-$ZIG_VERSION.tar.xz"; \
    echo "$zsum  zig.tar.xz" | sha256sum -c -; \
    mkdir /opt/zig && tar -xJf zig.tar.xz -C /opt/zig --strip-components=1; \
    curl -fsSLo lean.tar.zst "https://github.com/leanprover/lean4-nightly/releases/download/$LEAN_NIGHTLY/lean-$LEAN_VERSION-linux$lsuf.tar.zst"; \
    echo "$lsum  lean.tar.zst" | sha256sum -c -; \
    mkdir /opt/lean && tar --zstd -xf lean.tar.zst -C /opt/lean --strip-components=1; \
    curl -fsSLo go.tar.gz "https://go.dev/dl/go$GO_VERSION.linux-$garch.tar.gz"; \
    echo "$gsum  go.tar.gz" | sha256sum -c -; \
    tar -xzf go.tar.gz -C /opt; \
    rm zig.tar.xz lean.tar.zst go.tar.gz; \
    echo "$LEAN_NIGHTLY" >/opt/lean/NIGHTLY

# PostgreSQL's server tools (initdb, pg_ctl) are in Debian's versioned
# directory, not on PATH. initdb refuses to run as root: the checks run as
# the user `check`.
ENV PATH=/usr/lib/postgresql/17/bin:/opt/zig:/opt/lean/bin:/opt/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    GOTOOLCHAIN=local
RUN useradd --create-home check
USER check
WORKDIR /home/check
# Zig's and Go's downloads; ../linux-check.sh mounts a volume here, which
# takes this directory's owner.
ENV GOMODCACHE=/home/check/.cache/go-mod
RUN mkdir /home/check/.cache
