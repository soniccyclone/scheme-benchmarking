#!/usr/bin/env bash
# Does the containment actually contain?
#
# D30 put the resource limits in docker-compose.yml and nothing has ever checked
# that they take effect. That gap is not hypothetical: the Dockerfile records
# `timeout --signal=KILL` having silently done nothing for as long as it existed
# -- a guard that read as the STRONGER choice and was in fact no guard at all,
# found only when a miscompiled program looped forever and wedged the suite
# instead of failing it. A declared limit and an applied limit look identical
# right up to the moment they differ, and that moment is a runaway pass.
#
# So this asserts the four properties the whole arrangement exists to provide,
# from the outside, by trying to violate each one.
#
# RUNS FROM THE HOST -- it is testing the thing that puts you in a container, so
# it cannot be inside one to start with.
#
#   ./tools/test-containment.sh

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$here/tools/container.sh"

if sonic_in_container; then
    echo "REFUSED: run this from the HOST. It tests the host-to-container path."
    exit 2
fi

pass=0 fail=0
ok()   { echo "  [PASS] $1"; pass=$((pass + 1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail + 1)); }

# ---------------------------------------------------------------------------
echo "1. the limits are present in the cgroup"
# ---------------------------------------------------------------------------
read -r mem pids < <("$here/tools/container.sh" bash -c \
    'echo "$(cat /sys/fs/cgroup/memory.max) $(cat /sys/fs/cgroup/pids.max)"' 2>/dev/null | tail -1)

[ "$mem" = "$((8 * 1024 * 1024 * 1024))" ] \
    && ok "memory.max is 8g ($mem)" \
    || bad "memory.max is '$mem', expected $((8 * 1024 * 1024 * 1024))"
[ "$pids" = 512 ] \
    && ok "pids.max is 512" \
    || bad "pids.max is '$pids', expected 512"

# ---------------------------------------------------------------------------
echo "2. a memory runaway dies in the container, not on the host"
# ---------------------------------------------------------------------------
# THE ONE THAT MATTERS. This is the D30 incident in miniature: allocate without
# bound and confirm the cgroup OOM killer takes the process. Safe to run on a
# workstation precisely BECAUSE the limit works -- if it does not, this test is
# how you find out, and it is bounded by the host's own OOM killer rather than
# by hope. Touches each page so the memory is resident, not just mapped.
before=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
"$here/tools/container.sh" python3 -c '
buf = []
while True:
    chunk = bytearray(64 * 1024 * 1024)
    for i in range(0, len(chunk), 4096): chunk[i] = 1
    buf.append(chunk)
' >/dev/null 2>&1
rc=$?
after=$(awk '/SwapFree/ {print $2}' /proc/meminfo)

# 137 = 128 + SIGKILL, which is what the cgroup OOM killer produces. Python
# raising MemoryError first (exit 1) is also containment working -- the
# allocation was refused. What must NOT happen is exit 0.
case $rc in
    137) ok "runaway was SIGKILLed by the cgroup OOM killer (137)" ;;
    1)   ok "runaway was refused before it could allocate (MemoryError)" ;;
    0)   bad "runaway COMPLETED -- there is no memory limit" ;;
    *)   ok "runaway died, exit $rc (contained)" ;;
esac

# The host must not have paid for it. Slack for ordinary desktop churn.
swapped=$(( (before - after) / 1024 ))
[ "$swapped" -lt 512 ] \
    && ok "host swap barely moved during the runaway (${swapped} MiB)" \
    || bad "host swapped ${swapped} MiB -- the runaway reached the host's swap"

# ---------------------------------------------------------------------------
echo "3. a fork bomb hits the pid limit"
# ---------------------------------------------------------------------------
"$here/tools/container.sh" bash -c '
n=0
while [ $n -lt 2000 ]; do sleep 30 & n=$((n+1)); done
echo REACHED-2000-PROCS' 2>/dev/null | grep -q REACHED-2000-PROCS \
    && bad "forked 2000 processes -- pids_limit is not applied" \
    || ok "fork bomb stopped short of 2000 processes"

# ---------------------------------------------------------------------------
echo "4. the ENTRYPOINT's wall clock actually fires"
# ---------------------------------------------------------------------------
# Not the real 1800s -- that would take half an hour. This proves the mechanism:
# `timeout` in this image is uutils, not GNU, and the Dockerfile documents its
# --signal=KILL being inert. A spinning process must still be killed, and the
# exit code must be 124.
start=$(date +%s)
timeout 60 "$here/tools/container.sh" \
    bash -c 'exec timeout 5 bash -c "while :; do :; done"' >/dev/null 2>&1
rc=$?; elapsed=$(( $(date +%s) - start ))
[ "$rc" = 124 ] \
    && ok "a spinning process was killed and reported 124 (${elapsed}s)" \
    || bad "spinning process returned $rc after ${elapsed}s, expected 124"

# ---------------------------------------------------------------------------
echo
echo "containment: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
