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

# TWO STAGES, and the split is forced by a real incompatibility.
#
# The RUNTIME needs Ubuntu 25.10, because it carries gcc 15 for riscv64 and the
# RISC-V smoke gate pins the RVA23 profile -- whose `zimop` and `zcmop`
# extensions gcc 14 rejects outright. Weakening the -march string to suit an
# older compiler would gut the gate, which exists to prove we never depend on
# something RISC-V does not have. 25.10 also matches the host this was developed
# against (gcc 15, binutils 2.46), so the gas-verified encodings compare against
# the same assembler they always did.
#
# But CHEZ 10.0.0 DOES NOT BUILD under gcc 15: its bundled `zuo` build tool trips
# -Wincompatible-pointer-types, which gcc 15 promotes from warning to error.
# Relaxing that diagnostic would mean compiling our own Scheme with warnings
# suppressed, and bumping Chez would change the compiler underneath a project
# whose numbers are all measured against 10.0.0. So Chez is built in a stage
# that has a compiler it agrees with, and only the installed tree is carried
# over -- byte-identical to what the measurements were taken with.

FROM ubuntu:24.04 AS chez
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git ca-certificates \
        libncurses-dev libx11-dev uuid-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
ARG CHEZ_VERSION=v10.0.0
RUN git clone --depth 1 --branch ${CHEZ_VERSION} \
        https://github.com/cisco/ChezScheme.git /tmp/chez \
    && cd /tmp/chez \
    && ./configure --threads --installprefix=/usr/local \
    && make -j"$(nproc)" \
    && make install \
    && cd / && rm -rf /tmp/chez

FROM ubuntu:25.10
ENV DEBIAN_FRONTEND=noninteractive

# gcc/binutils: the differential assembler oracle for x86-64.
# binutils-riscv64-linux-gnu + qemu-user: the RISC-V smoke gate.
# linux-tools: `perf`, for the instruction counts phases 3 and 4 are built on.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        binutils-riscv64-linux-gnu \
        # gcc 15 here: 13 does not auto-vectorize RVV AT ALL (zero vector
        # instructions at -march=rv64gcv, and -fno-vect-cost-model does not budge
        # it), which costs disasm-test its positive control for
        # `has-packed-arithmetic?` and costs milestone 4 its reference for what
        # good RVV codegen looks like.
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

# Chez comes from the builder stage, installed under an explicit prefix. Its
# `make install` defaults to /usr, not /usr/local, so copying /usr/local without
# setting --installprefix silently carries nothing across and `scheme` is simply
# absent in the final image.
COPY --from=chez /usr/local /usr/local
RUN ldconfig

WORKDIR /work/sonic

# `timeout` as PID 1, so a pass that does not terminate kills its own container
# and exits 124 instead of hanging until someone notices. Docker has no
# run-duration limit of its own -- `--stop-timeout` is the SIGTERM-to-SIGKILL
# grace period and `--health-timeout` bounds a single probe, neither is a
# lifetime -- so this is where wall clock has to come from.
ENTRYPOINT ["timeout", "--signal=KILL", "1800"]
CMD ["make", "test-suite"]
