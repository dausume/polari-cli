#!/bin/bash
# hwnocode.sh — `pol hwnocode`: hardware as no-code (the hn arc, AI-Notes/plans/HARDWARE_NOCODE_PLAN.md; module hwnocode). ONE
# no-code model across frontend, backend and hardware: a HardwareSolution spans a cmod CGraph (the hardware SUBGRAPH), the
# hw-interface (the split point — a grpcbridge binding), the backend solution and the configured displays. The placement rule
# derives where each node runs and refuses Python on a device (RULE 2); hn-split renders the board half through cmod-glue
# (unchanged output) and the backend half as its own solution; the runtime suggestion is shown, never applied (D-hn-3).
# Placement / render / suggest need no engine; build runs make alone through the board engines seam.
#
#   pol hwnocode help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"

usage() {
printf '%b\n' "$(cat <<EOF2
${BOLD}pol hwnocode${NC} — one no-code graph across a board, the bridge, the backend and a screen (hn arc)

  ${CYAN}solutions${NC}                        the HardwareSolutions: subgraph, interface, firmware_runtime, placement, status
  ${CYAN}place${NC} <solution>                 the placement report: every node → board | twin | bridge | backend | browser, and WHY
                                    (a Python node on the device side is REFUSED, named, with the way to move it)
  ${CYAN}render${NC} <solution> [--work W]     hn-split: the board half through cmod-glue into W/project — its files_sha256 must EQUAL
                                    cmod-1's record (unchanged output); the backend half as <solution>.backend
  ${CYAN}build${NC} <solution> [--work W]      make ALONE in W/project (board engines) → W/out/firmware.hex + W/firmware_build.json, so
                                    ${CYAN}pol board twin uno up --work W${NC} runs exactly that build
  ${CYAN}suggest${NC} <solution>               bare C / FreeRTOS / ESP-IDF / Zephyr with its EVIDENCE rows — SUGGEST ONLY: nothing changes
  ${CYAN}runtime${NC} <solution> <value>       would the firmware_runtime knob accept it? (bare-c accepted; auto / an RTOS refused with why)

  <solution> = uno-temp-split (seeded: the UNO sim-rig subgraph → the bridge → a moving average + threshold → a chart).
  W defaults to \$POLARI_HWNOCODE_HOME/<solution> (~/.cache/polari-hwnocode/<solution>).
  Page: /display/hardware-solutions · API: /api/hwnocode · Selftest: pol modules selftest hwnocode
  Probes (in $FW): tests/hwnocode_probe.py (the twin proof) · tests/hwnocode_liveboot_probe.py (the live boot)
EOF2
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
py() { (cd "$FW" && PYTHONPATH=.:modules python3 "$@"); }

case "$cmd" in
    help|-h|--help) usage ;;
    solutions) py -m hwnocode.custom.hwnocode_cli solutions ;;
    place|render|build|suggest) py -m hwnocode.custom.hwnocode_cli "$cmd" "${1:-uno-temp-split}" "${@:2}" ;;
    runtime) [ -n "${2:-}" ] || die "usage: pol hwnocode runtime <solution> <bare-c|freertos|esp-idf|zephyr>"
             py -m hwnocode.custom.hwnocode_cli runtime "$1" "$2" ;;
    *) log_error "unknown verb: pol hwnocode $cmd"; usage; exit 1 ;;
esac
