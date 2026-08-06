#!/usr/bin/env bash
# Run one configuration at a given N. Prints the two energy lines.
#   ./run.sh chez-2a 1000
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/configs.sh"
exec $(cfg_run "$1" "$2")
