#!/usr/bin/env bash
# Refresh the committed FET data snapshot (modules/{cntfet,sifet}/initialData/*.json)
# from a live node — the libraries / derived devices / open-library rows
# that code cannot regenerate. Plain JSON, deduped, small. Review the
# diff, then commit in polari-framework.
#   snapshot-cntfet-data.sh [api-base]   (default: prf-a on pol-core)
set -euo pipefail
API="${1:-${POLARI_API:-https://api.prf.192.168.0.210.nip.io}}"
FW="$(cd "$(dirname "$0")/../../polari-rf-node/polari-framework" && pwd)"
cd "$FW/modules"
echo "== snapshot from $API → modules/{cntfet,sifet}/initialData/"
PYTHONPATH=..:../polariApiServer python3 -m cntfet.cnt_snapshot "$API"
echo "== selftest"
PYTHONPATH=..:../polariApiServer python3 -m cntfet.selftest_snapshot | tail -3
echo "== git status (polari-framework)"
git -C "$FW" status --short modules/cntfet/initialData modules/sifet/initialData
