#!/usr/bin/env bash
# Hardware performance counters, by way of a second kernel.
#
# WHY THIS EXISTS. Milestone 5's remaining gap against gcc -O3 -march=native is
# not instruction count -- the counts are flat -- so it is latency and port
# pressure. callgrind counts instructions exactly and models no pipeline at all,
# so it cannot see that gap by construction. Only the hardware counters can.
#
# WHY IT IS A VM. On the host kernel perf is unusable and no flag reaches it:
# kernel.perf_event_paranoid is 4, and CAP_PERFMON is tested against the INITIAL
# user namespace, so a rootless container cannot hold it however it is started.
# D60 recorded that correctly and then concluded the counter route was closed for
# good, which does not follow. `perf_event_paranoid` is a property of A KERNEL,
# not of this machine. Boot a second one under KVM and you are root in its init
# namespace, where the sysctl is yours to set -- and kvm.enable_pmu is Y, so the
# guest's counters are the real hardware counters underneath.
#
# Nothing about the host changes. /dev/kvm carries an ACL granting the invoking
# user rw, so there is no sudo, no group change and no sysctl edit.
#
# virtme-ng boots THIS CONTAINER'S filesystem as the guest root, so the guest has
# our compiler, our binaries and our perf already. There is no second image to
# drift out of sync with this one, which is the same argument that pins the
# toolchain in the first place.
#
#   harness/vm-perf.sh <command...>
#   EVENTS=cycles,instructions harness/vm-perf.sh ./build/sonic 1000000
#
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

# NOTHING RUNS ON THE HOST -- the hard rule in CLAUDE.md. This boots a VM, which
# is emphatically a thing that wants a limit around it.
. "$here/tools/container.sh"

# EVENTS IS FORWARDED EXPLICITLY, and it has to be. `compose run` does not carry
# the caller's environment across, so an EVENTS= set on the command line reached
# the container as unset -- perf then measured the DEFAULT list and printed a
# perfectly well-formed report of counters nobody asked for. An instrument that
# quietly answers a different question than the one put to it is the exact
# failure mode this harness exists to avoid, so the value crosses the boundary
# as an argument rather than as a hope.
EVENTS=${EVENTS:-cycles,instructions,branches,branch-misses}
VMCPUS=${VMCPUS:-2}
sonic_reexec sonic env EVENTS="$EVENTS" VMCPUS="$VMCPUS" \
             bash /work/harness/vm-perf.sh "$@"

[ $# -gt 0 ] || { echo "usage: vm-perf.sh <command...>" >&2; exit 2; }

KERNEL=${KERNEL:-$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)}

# FAIL LOUDLY, NOT QUIETLY INTO A WORSE MEASUREMENT. Without KVM this would still
# "work" -- qemu would fall back to TCG emulation, boot, and report counter values
# that are a software model rather than the silicon. That is precisely the failure
# D60 warns about: an instrument that answers instead of refusing.
[ -c /dev/kvm ] || { echo "vm-perf: /dev/kvm absent -- the counters need KVM, and TCG would silently answer with a simulation" >&2; exit 1; }
[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "vm-perf: /dev/kvm not readable/writable; check the ACL grants this user rw" >&2; exit 1; }
[ -n "$KERNEL" ] && [ -f "$KERNEL" ] || { echo "vm-perf: no guest kernel in /boot" >&2; exit 1; }

# The command goes through a FILE rather than nested -c quoting, which the guest
# reaches because its root IS this filesystem. Three levels of shell quoting is
# how a benchmark ends up measuring `bash` instead of the program.
script=$(mktemp /tmp/vm-perf-cmd.XXXXXX)
trap 'rm -f "$script"' EXIT
{
    echo '#!/bin/bash'
    # Written straight to /proc: `sysctl -w key=-1` parses the leading `-1` as an
    # option and prints its usage instead of setting anything.
    echo 'echo -1 > /proc/sys/kernel/perf_event_paranoid'
    echo 'cd /work || exit 1'
    printf 'exec perf stat -e %s -- %s\n' "$EVENTS" "$*"
} > "$script"
chmod +x "$script"

timeout 900 vng --force-9p --cpus "$VMCPUS" -r "$KERNEL" -- "$script" 2>&1 \
    | grep -vE "^\[ *[0-9]+\.[0-9]+\]|virtme-init:|mount:|dmesg\(1\)"
