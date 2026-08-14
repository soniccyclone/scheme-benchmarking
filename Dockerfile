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
        # INSTRUCTION COUNTS WITHOUT THE PMU. This host runs
        # kernel.perf_event_paranoid=4, under which perf_event_open is denied to
        # every unprivileged process -- and CAP_PERFMON is tested against the
        # INITIAL user namespace, so a rootless container cannot hold it no
        # matter what is added to it (--privileged included; measured). callgrind
        # counts instructions exactly in userspace and needs none of that.
        #
        # It is also the BETTER instrument for this project, not merely the
        # available one: it is deterministic, so it does not have D57's problem
        # where the standing drifted 1% with the code byte-identical.
        #
        # This works only because the runtime no longer emits AVX-512
        # unconditionally (D59) -- valgrind's VEX cannot decode `kmovw` and used
        # to die in the prologue, reporting zero instructions.
        valgrind \
        git \
        make \
        python3 \
        ca-certificates \
        libelf1 \
        # perf's runtime deps.
        # perf itself. `linux-tools-common` pulls `linux-perf`, whose binary
        # works here even though it is built for a different kernel version --
        # the counters we need are the architectural ones. The version wrapper
        # would refuse, so nothing calls `perf` through it.
        # `linux-perf` NAMED EXPLICITLY: linux-tools-common only RECOMMENDS it,
        # and --no-install-recommends drops it -- the same trap that silently
        # left out the riscv64 static libc. Its binary works here despite being
        # built for a different kernel version, because the counters we need are
        # the architectural ones; the version wrapper would refuse, so nothing
        # calls it through the wrapper.
        linux-perf \
        libslang2 \
        libunwind8 \
        libdw1 \
        libcap2 \
        libnuma1 \
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
# and exits 124 instead of hanging until someone notices. Neither docker nor
# podman has a run-duration limit of its own -- `--stop-timeout` is the
# SIGTERM-to-SIGKILL grace period and `--health-timeout` bounds a single probe,
# neither is a lifetime -- so this is where wall clock has to come from.
#
# NO `--signal=KILL`, AND DO NOT ADD IT BACK. It reads like the stronger
# choice and in this image it disables the guard entirely. `timeout` here is
# uutils coreutils 0.2.2, not GNU, and its `--signal=KILL` does not deliver the
# signal -- it waits for the child to exit on its own and only then reports
# 124. Measured in the container:
#
#     timeout 2 sleep 10                 -> 2.0s, exit 124   (works)
#     timeout --signal=KILL 2 sleep 10   -> 10.0s, exit 124   (does not)
#     timeout -k 2 3 <ignores SIGTERM>   -> never returns     (does not)
#
# So this guard silently did nothing for as long as it has existed, which is
# how a miscompiled program that looped for ever wedged the suite instead of
# failing it. The DEFAULT SIGTERM works, and works on a spinning Chez (4.0s,
# exit 124) and on our emitted binaries, which install no signal handlers and
# so cannot decline it.
ENTRYPOINT ["timeout", "1800"]
CMD ["make", "test-suite"]
