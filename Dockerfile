# The toolchain, pinned.
#
# Two reasons this exists, and the second is the one that made it non-optional.
#
# REPRODUCIBILITY. Eighty-one x86-64 instructions are byte-verified against
# `gas`, and the RISC-V smoke gate reads our own output back through
# `riscv64-linux-gnu-objdump`. Those tests are only meaningful if the assembler
# and the disassembler are the same ones everywhere they run -- otherwise a
# green suite on one machine and a red one in CI is a toolchain difference
# wearing a compiler bug's clothes. Pinning them also retires an ugly
# workaround: `perf` and `qemu-user` used to be unpacked by hand with
# `apt-get download` + `dpkg-deb -x` because there was no sudo.
#
# CONTAINMENT. On 2026-08-07 an unguarded loop in a compiler pass consed once
# per iteration until a single Chez process held 31,204,756 kB -- the whole WSL
# VM -- and the OOM killer took everything else down with it. A per-invocation
# `ulimit` would have stopped it, and would also have to be remembered every
# time. A container carries its limits whether anyone remembers or not, which is
# the only kind of guarantee worth having against a class of bug that recurs.
# The limits live in docker-compose.yml.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# gcc/binutils: the differential assembler oracle for x86-64.
# binutils-riscv64-linux-gnu + qemu-user: the RISC-V smoke gate.
# linux-tools: `perf`, for the instruction counts phases 3 and 4 are built on.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        binutils-riscv64-linux-gnu \
        gcc-riscv64-linux-gnu \
        # STATIC cross-libc, and it is not optional: twoaddr-test links a C
        # main against our own object with `riscv64-linux-gnu-gcc -static` and
        # runs it under qemu, so it needs riscv64 `libc.a`. Ubuntu ships that in
        # a package gcc-riscv64-linux-gnu only RECOMMENDS, which
        # --no-install-recommends drops -- the linker then refuses our object
        # and the failure reads like a codegen bug.
        libc6-dev-riscv64-cross \
        qemu-user \
        git \
        make \
        python3 \
        ca-certificates \
        libelf1 \
        libncurses-dev \
        libx11-dev \
        uuid-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Chez Scheme, built from a pinned tag rather than taken from apt, because the
# distro version drifts and `optimize-level 3` behaviour is load-bearing here:
# the whole project measures what a Scheme compiler does with checks.
ARG CHEZ_VERSION=v10.0.0
RUN git clone --depth 1 --branch ${CHEZ_VERSION} \
        https://github.com/cisco/ChezScheme.git /tmp/chez \
    && cd /tmp/chez \
    && ./configure --threads \
    && make -j"$(nproc)" \
    && make install \
    && cd / && rm -rf /tmp/chez

WORKDIR /work/sonic

# `timeout` as PID 1, so a pass that does not terminate kills its own container
# and exits 124 instead of hanging until someone notices. Docker has no
# run-duration limit of its own -- `--stop-timeout` is the SIGTERM-to-SIGKILL
# grace period and `--health-timeout` bounds a single probe, neither is a
# lifetime -- so this is where wall clock has to come from.
ENTRYPOINT ["timeout", "--signal=KILL", "1800"]
CMD ["make", "test-suite"]
