# The Linux validation host (item ogcdwm): Debian trixie with the tools
# ./check.sh needs. Pinned by version and SHA-256: Zig (the version the macOS
# runs use), the Lean toolchain named by lean-toolchain and Go
# (bench/*/go.mod). Not pinned: the debian:trixie image and PostgreSQL 17
# (libpq and the server for the private cluster), which come from Debian's
# archive as of the build. ../linux-check.sh builds it, prints those
# versions and runs ./check.sh in it; it checks that lean-toolchain still
# names LEAN_NIGHTLY. Update a version and its sums together. It builds for
# arm64 and x86_64 hosts.
FROM debian:trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils zstd git \
      libpq-dev postgresql-17 postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.17.1
ARG ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
ARG ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
ARG LEAN_NIGHTLY=nightly-2026-11-17
ARG LEAN_VERSION=4.37.0-nightly-2026-11-17
ARG LEAN_SHA256_AARCH64=f6fafd943c4fef50c868311bb710e45d250f94d0c555e324068e75b1cb5c9e46
ARG LEAN_SHA256_X86_64=d058da899c5d2ae4fc2cc4fa7933938b8d7dfc90d06bf8ddf5c29c09f158348a
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
