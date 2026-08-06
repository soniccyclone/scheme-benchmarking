#!/usr/bin/env bash
# Ahead-of-time compile one configuration, or all of them.
#   ./compile.sh            all configurations
#   ./compile.sh chez-2a    just that one
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/configs.sh"

targets="${*:-$CONFIGS}"
for c in $targets; do
    printf '%-12s ' "$c"
    if cfg_compile "$c" 2>&1 | tail -3; then echo "[built]"; else echo "[FAIL]"; exit 1; fi
done
