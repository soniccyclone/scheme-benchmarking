#!/usr/bin/env bash
# Container plumbing, shared by everything that has to run inside one.
#
# The limits still live in ../docker-compose.yml -- see D30. This file exists
# because the host moved to podman and two things about that are not
# interchangeable with docker (D58):
#
#   1. `docker compose` is `podman compose` here, and podman needs a compose
#      PROVIDER installed before that subcommand does anything at all.
#   2. There is no /.dockerenv under podman. Docker writes that file; podman
#      writes /run/.containerenv. Six guards in this tree tested only the first,
#      which meant that on the new host they all inverted: the suite refused to
#      run INSIDE a container, and the re-exec'ing harness scripts would have
#      re-entered a container from within one for ever.
#
# Sourced by a script that must re-exec itself inside:
#   . "$root/tools/container.sh"
#   sonic_reexec sonic /work/harness/whatever.sh "$@"
#
# Executed as a command:
#   tools/container.sh --assert-inside       exit 0 iff in a container
#   tools/container.sh --preflight-exec CMD  verify the limits, then exec CMD
#   tools/container.sh --shell               interactive shell in the container

set -uo pipefail

sonic_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); }

# Both markers. Deliberately a FILE test rather than an environment variable we
# export: the files are written by the engine, so nothing on the host can spoof
# its way past the guard by exporting a variable.
sonic_in_container() { [ -f /.dockerenv ] || [ -f /run/.containerenv ]; }

# podman first -- it is what this host has. docker for CI, which has that.
sonic_compose() {
    if [ -n "${SONIC_COMPOSE:-}" ]; then echo "$SONIC_COMPOSE"
    elif command -v podman >/dev/null 2>&1; then echo "podman compose"
    elif command -v docker >/dev/null 2>&1; then echo "docker compose"
    else
        echo "no container engine: install podman (or docker)." >&2
        echo "NOTHING IN THIS TREE RUNS ON THE HOST -- see CLAUDE.md." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Inside the container: prove the limits applied, then exec.
# ---------------------------------------------------------------------------
# D30 records being bitten by a limit key that parsed, validated, and did
# nothing (`deploy.resources.limits.memory`, ignored outside Swarm). The answer
# to a class of bug whose whole character is silence is to read the limit back
# out of the kernel rather than trust that the config was honoured. Cheap: two
# file reads, once per container start.
#
# Fail fast over fail silently -- an unverifiable limit is treated as absent,
# because "I could not check" and "it is not there" have the same blast radius.
sonic_assert_limits() {
    local mem pids where
    if [ -r /sys/fs/cgroup/memory.max ]; then                       # cgroup v2
        mem=$(cat /sys/fs/cgroup/memory.max)
        pids=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo max)
        where=v2
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then   # cgroup v1
        mem=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        pids=$(cat /sys/fs/cgroup/pids/pids.max 2>/dev/null || echo max)
        where=v1
    else
        echo "REFUSED: no readable cgroup memory interface in this container." >&2
        echo "The memory cap is what stands between a non-terminating pass and" >&2
        echo "the host (D30). Unverifiable is treated as absent." >&2
        return 1
    fi

    # Not an equality test: the point is that SOMETHING capped this, and a
    # future edit to docker-compose.yml should not have to be mirrored here.
    # 32g is far above the 8g we ask for and far below a host worth protecting.
    if [ "$mem" = max ] || [ "$mem" -gt $((32 * 1024 * 1024 * 1024)) ] 2>/dev/null; then
        echo "REFUSED: memory limit reads '$mem' (cgroup $where)." >&2
        echo "This container started WITHOUT the limits in docker-compose.yml." >&2
        echo "A runaway pass here would eat the host. Check that the compose" >&2
        echo "provider honoured mem_limit -- see D58." >&2
        return 1
    fi
    if [ "$pids" = max ]; then
        echo "REFUSED: pids limit is unset (cgroup $where); expected 512." >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Host side.
# ---------------------------------------------------------------------------
# $1 is the compose SERVICE. There is only `sonic` now -- `bench` existed for
# perf's seccomp exception and nothing opens a perf event any more (D60) -- but
# it stays a parameter rather than being inlined, so adding a service later does
# not mean rewriting every call site.
#
# The ENTRYPOINT (`timeout 1800`) is NOT overridden. The old call sites passed
# `--entrypoint bash` and silently gave up the wall-clock guard along with it,
# so a pass that did not terminate wedged them instead of failing them. The
# command runs through --preflight-exec so the limits are checked first.
#
# `-T` allocates no tty, which matters both ways: the emitted programs write raw
# doubles to stdout (sonic/src/sonic/runtime.ss) and a tty would mangle them,
# while diff-run.sh needs stdin to carry the program under test.
# The harness scripts document knobs -- `N=11 REPS=9 harness/measure-fannkuch.sh`
# -- and neither `docker compose run` nor `podman compose run` forwards the
# caller's environment. So those knobs silently did nothing across the container
# boundary: the script re-exec'd inside and read its own defaults, and the run
# LOOKED fine while ignoring what was asked for. Forwarded explicitly, and only
# these, so the container's environment stays a known quantity.
SONIC_ENV_FORWARD="N N1 N2 REPS WARMUP TOP NBODY BASELINE CONFIGS EVENT SONIC_INSTRUMENT PARALLEL_MAX"

# THE CPU SHARE HAS TO FIT THE MACHINE, or no container starts at all.
#
# docker-compose.yml asks for `cpus: ${SONIC_CPUS:-8}`, and Docker REFUSES a value
# above the host's core count rather than clamping it:
#
#   Error response from daemon: range of CPUs is from 0.01 to 4.00,
#   as there are only 4 CPUs available
#
# That is what kept CI from starting a container for five days (D194), and the
# fix there was to set SONIC_CPUS=4 in the workflow -- which fixes CI and leaves
# the same trap for anyone cloning this onto a machine with fewer than eight
# cores. A default is not a fix when the correct value is a property of the host.
#
# So it is computed rather than defaulted: whatever the machine has, capped at 8,
# which is the number docker-compose.yml documents as the intended share. Nothing
# to configure, and an explicit SONIC_CPUS still wins.
#
# Not a containment limit -- memory, swap and pids are, and are asserted by
# tools/test-containment.sh. This one only has to be legal.
if [ -z "${SONIC_CPUS:-}" ]; then
    _sonic_cores=$( (nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8) )
    case "$_sonic_cores" in
        ''|*[!0-9]*) _sonic_cores=8 ;;
    esac
    [ "$_sonic_cores" -lt 1 ] && _sonic_cores=1
    [ "$_sonic_cores" -gt 8 ] && _sonic_cores=8
    export SONIC_CPUS="$_sonic_cores"
    unset _sonic_cores
fi

sonic_run() {
    local service=$1; shift
    local compose; compose=$(sonic_compose) || return 1
    local envs=() v
    for v in $SONIC_ENV_FORWARD; do
        [ -n "${!v:-}" ] && envs+=(-e "$v=${!v}")
    done
    exec $compose -f "$(sonic_root)/docker-compose.yml" run --rm -T "${envs[@]}" \
        "$service" /work/tools/container.sh --preflight-exec "$@"
}

# Returns (does nothing) when already inside, so the caller falls through to its
# real work.
sonic_reexec() {
    sonic_in_container && return 0
    sonic_run "$@"
}

sonic_main() {
    case "${1:---help}" in
        --assert-inside)
            sonic_in_container && exit 0
            echo "REFUSED: this runs in a container. Use 'make test', so that a" >&2
            echo "runaway pass dies at 8g instead of taking the host with it." >&2
            echo "(Checked /.dockerenv AND /run/.containerenv -- see D58.)" >&2
            exit 1 ;;
        --preflight-exec)
            shift
            sonic_assert_limits || exit 1
            exec "$@" ;;
        --shell)
            local compose; compose=$(sonic_compose) || exit 1
            # The one place a tty is wanted and no doubles are parsed.
            exec $compose -f "$(sonic_root)/docker-compose.yml" run --rm \
                 --entrypoint /bin/bash sonic ;;
        --help|-h)
            sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)
            sonic_run sonic "$@" ;;
    esac
}

# Sourced (for sonic_reexec) or executed (as the runner)?
if [ "${BASH_SOURCE[0]}" = "$0" ]; then sonic_main "$@"; fi
