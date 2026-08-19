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
echo "2b. a runaway INSIDE THE GUEST VM dies at the guest's limit"
# ---------------------------------------------------------------------------
# ADDED WHEN THE VM WAS (D145). `harness/vm-perf.sh` boots a KVM guest inside the
# container to reach the hardware counters, and every assertion above predates
# it. A guest is the one thing here that can ask for memory the container would
# then have to find.
#
# It was contained before this ran, by virtme-ng's default of about 960 MiB --
# which is exactly the arrangement the header above objects to. `vm-perf.sh` now
# passes `--memory 1G` explicitly, and this checks that the number takes effect
# rather than merely being written down, the same relationship this whole file
# has to docker-compose.yml.
#
# TWO OUTCOMES ARE CONTAINED AND ONLY ONE IS GOOD. If the guest's own OOM killer
# takes the process, the failure is fast and says which limit stopped it. If
# qemu instead grows until the CONTAINER's cgroup kills it, the workload is
# still contained -- the backstop held -- but the report is a dead container
# rather than a dead program. Both pass; they are distinguished in the message.
# THE BOMB GOES THROUGH A FILE, not nested quoting. `vm-perf.sh`'s own header
# explains why -- "three levels of shell quoting is how a benchmark ends up
# measuring `bash` instead of the program" -- and the first version of this
# assertion proved the point: four levels deep, the payload never ran, the guest
# sat for the full 300s, and the check reported PASS. An assertion that cannot
# fail is worse than none (D138, D140).
# SURVIVAL IS REPORTED ONLY ON A ZERO EXIT, and the first version got this
# wrong too: an OOM-killed python prints nothing and the shell runs the next
# line regardless, so `GUEST-SURVIVED` was echoed for a bomb that HAD been
# killed. The check then read a working limit as a broken one. `|| exit` is the
# whole fix; the lesson is that reaching the next line is not evidence the
# previous one succeeded.
cat > "$here/build/guest-bomb.sh" <<'BOMB'
python3 -c '
buf = []
while True:
    chunk = bytearray(32 * 1024 * 1024)
    for i in range(0, len(chunk), 4096): chunk[i] = 1
    buf.append(chunk)
' 2>&1 | tail -2
rc=${PIPESTATUS[0]}
echo "GUEST-BOMB-EXIT=$rc"
[ "$rc" -eq 0 ] && echo "GUEST-SURVIVED"
BOMB
guest_out=$("$here/tools/container.sh" bash -c '
  cd /work
  timeout 240 vng --memory 1G --force-9p --cpus 1 \
      -r "$(ls -1 /boot/vmlinuz-* | sort -V | tail -1)" -- \
      bash /work/build/guest-bomb.sh 2>&1 | tail -5' 2>&1)
guest_rc=$?
rm -f "$here/build/guest-bomb.sh"

if echo "$guest_out" | grep -qiE "MemoryError|Killed|Out of memory|oom-kill"; then
    ok "guest runaway died inside the guest, at its own 1G limit"
elif echo "$guest_out" | grep -q "GUEST-SURVIVED"; then
    bad "guest runaway COMPLETED -- the guest has no effective memory limit"
elif echo "$guest_out" | grep -q "GUEST-BOMB-EXIT="; then
    ok "guest runaway died inside the guest ($(echo "$guest_out" | grep -o 'GUEST-BOMB-EXIT=[0-9]*'))"
elif [ "$guest_rc" -ne 0 ]; then
    ok "guest runaway was contained, exit $guest_rc (no guest-side report)"
else
    bad "guest runaway result unreadable -- the assertion did not run"
fi

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
