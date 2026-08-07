#!/usr/bin/env bash
# Retired instructions per step, per configuration.
#
# Two N values, and we report the SLOPE. Process startup ranges from ~4ms to
# ~200ms across the runtimes in this matrix and would otherwise dominate at dev
# sizes; differencing two N values cancels it exactly. See LEDGER.md D17 for why
# instruction count and not wall time is the primary instrument here.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/configs.sh"

N1=${N1:-1000000}
N2=${N2:-2000000}
# From PATH inside the `bench` compose service, which carries the
# seccomp exception perf_event_open needs. See docker-compose.yml.
PERF=${PERF:-perf}

count() {  # retired user-space instructions for one run
    $PERF stat -x, -e instructions:u $1 2>&1 >/dev/null | cut -d, -f1
}

printf '%-12s %16s %16s %14s %10s\n' config "N=$N1" "N=$N2" per-step vs-C
printf '%-12s %16s %16s %14s %10s\n' ------ ---------------- ---------------- -------------- ----------

base=""
for c in ${*:-$CONFIGS}; do
    i1=$(count "$(cfg_run "$c" "$N1")")
    i2=$(count "$(cfg_run "$c" "$N2")")
    [ -z "$i1" ] && { printf '%-12s  measurement failed\n' "$c"; continue; }
    per=$(awk -v a="$i1" -v b="$i2" -v n1="$N1" -v n2="$N2" 'BEGIN{printf "%.2f", (b-a)/(n2-n1)}')
    [ -z "$base" ] && base="$per"
    rel=$(awk -v p="$per" -v b="$base" 'BEGIN{printf "%.2fx", p/b}')
    printf '%-12s %16d %16d %14s %10s\n' "$c" "$i1" "$i2" "$per" "$rel"
done
