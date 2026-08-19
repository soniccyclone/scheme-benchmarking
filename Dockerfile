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
# valgrind: the instruction counts phases 3 and 4 are built on, counted by
#   simulation because this host has no usable PMU (D58/D60).
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
        # THE OTHER TEN nbody CONFIGURATIONS. Oracle check 2 is eleven-way
        # bit-exact cross-agreement, which D24 calls the strongest correctness
        # evidence this project has -- an unsound abstract domain shows up as a
        # value that is only slightly wrong, and agreement across independent
        # implementations is what catches that. Pinning the toolchain silently
        # cut that check to the nine configurations whose compilers happened to
        # already be here (sonic, two C builds, six Chez variants); the other
        # ten could not run at all. The SOURCES were never missing, only the
        # compilers, so this is the whole fix.
        racket \
        sbcl \
        ecl \
        clisp \
        # gnat-15 EXPLICITLY, not the `gnat` metapackage: that one pulls 14, and
        # harness/configs.sh calls `gnatmake-15` by version on purpose -- the
        # same pinning argument the rest of this file rests on. Unversioned
        # `gnatmake` would build against whatever happened to be installed,
        # which is the drift the container exists to prevent. 15 also matches
        # the gcc the C configurations are built with.
        gnat-15 \
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
        # A PIPELINE MODEL, WHICH callgrind IS NOT. Milestone 5 sits ~5% behind
        # gcc -O3 -march=native, and the instruction counts say that gap is not
        # instruction count -- so it is latency and port pressure, which callgrind
        # cannot see and a hardware counter would have shown. perf is denied here
        # for the reasons above and no flag fixes it, so the counter route is
        # closed for good.
        #
        # llvm-mca models the scheduler STATICALLY: it reads assembly, not a
        # running process, so it needs no PMU, no privileges and no relaxed
        # sysctl. It reports per-instruction latency, port occupancy and the
        # critical path through a loop body -- the diagnosis M5 was missing.
        # Being static it is also deterministic, the same property that made
        # callgrind the better instrument in D60.
        llvm \
        git \
        make \
        python3 \
        ca-certificates \
        libelf1 \
        # PERF, AND WHY IT IS HERE AFTER D60 SAID IT COULD NEVER WORK.
        #
        # D60 was right about the host and wrong in its conclusion. On the HOST
        # kernel perf is genuinely unusable: kernel.perf_event_paranoid is 4, and
        # CAP_PERFMON is tested against the INITIAL user namespace, so no flag and
        # no amount of rootless privilege reaches it. From that I concluded the
        # hardware-counter route was closed for good, which does not follow --
        # `perf_event_paranoid` is a property of A kernel, not of this machine.
        #
        # Boot a second kernel under KVM and you are root in ITS init namespace,
        # where the sysctl is yours to set. /dev/kvm carries an ACL granting the
        # invoking user rw (no sudo, no group change), and kvm.enable_pmu is Y, so
        # the guest gets a virtual PMU backed by the real hardware counters.
        #
        # This is what callgrind cannot give at any price: a PIPELINE. Instruction
        # counts between us and gcc -O3 are flat, so milestone 5's remaining gap is
        # latency and port pressure, which a counting simulator cannot see.
        #
        # virtme-ng boots the CURRENT filesystem as the guest root -- no disk
        # image, no cloud image, no second copy of the toolchain to drift out of
        # sync with this one. The guest is this container.
        #
        # perf still must not be run in the container itself, where it will fail
        # with a bare EPERM three layers from its cause. harness/vm-perf.sh is the
        # only entry point and it refuses outside the guest.
        qemu-system-x86 \
        virtme-ng \
        # virtme-ng BUILDS AN INITRAMFS at boot and shells out to busybox to
        # populate it; without this it refuses with `initramfs is needed, and no
        # busybox was found`. -static because the initramfs has no libc yet.
        busybox-static \
        # Kernel modules ship zstd-compressed, and the initramfs build shells out
        # to decompress them. Missing, it fails as a wall of `sh: 1: zstd: not
        # found` and then a socket error that names nothing relevant.
        zstd \
        # WHAT virtme-init NEEDS AND A MINIMAL IMAGE DOES NOT HAVE. The guest boots
        # fine without these; it is init that then falls over, and the message you
        # get is `Attempted to kill init` rather than the name of anything missing.
        # `ip` to bring up the console interface, `poweroff` to shut down (without
        # it init RETURNS, which is what the panic actually is), udev because
        # virtme-init looks for udevd before settling devices, and kmod to load the
        # virtio-serial module that carries the command's output back to us.
        iproute2 \
        systemd-sysv \
        udev \
        kmod \
        # The guest root IS this container's filesystem. virtiofsd is how it gets
        # there; the 9p fallback works and is markedly slower, which matters when
        # the thing being measured is a benchmark.
        virtiofsd \
        linux-image-generic \
        # THE perf BINARY ITSELF, and note the package name: this file used to carry
        # a comment forbidding `linux-perf` by name. It was right for the host and
        # wrong for the guest. `linux-tools-generic` ships cpupower and friends but
        # NOT perf; `linux-perf` is the standalone build, versioned to match the
        # kernel above, and linux-tools-common carries the /usr/bin/perf dispatcher
        # that picks a build by `uname -r`.
        linux-perf \
        linux-tools-common \
        # The libraries below predate all of this: they are small and
        # binutils/objdump link several of them.
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
# FAIL AT BUILD TIME IF THE PIPELINE MODEL IS NOT THERE. Ubuntu ships llvm-mca
# under /usr/lib/llvm-N/bin, which is not on PATH; the `llvm` metapackage does
# not always symlink it. A missing analyser must not turn into a mysteriously
# empty report three layers away, so it is resolved and checked here.
RUN set -eu; \
    mca="$(ls -1 /usr/lib/llvm-*/bin/llvm-mca 2>/dev/null | sort -V | tail -1 || true)"; \
    if [ -z "$mca" ]; then command -v llvm-mca >/dev/null && mca="$(command -v llvm-mca)"; fi; \
    [ -n "$mca" ] || { echo "llvm-mca absent after installing llvm" >&2; exit 1; }; \
    ln -sf "$mca" /usr/bin/llvm-mca; \
    llvm-mca --version | head -2

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
