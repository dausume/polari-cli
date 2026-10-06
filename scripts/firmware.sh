#!/bin/bash
# firmware.sh — `pol firmware`: Firmware Solutions (fs-0 arc, AI-Notes/plans/DEMONSTRABLES_PLAN.md §9; module cmod).
# A FirmwareSolution takes a CGraph (its tasks = the graph's c-atoms) and a board (fixed, or a run-time variable
# validated it still exists) and DERIVES its schedule (D-fs-1: from the atoms' own ISR/tick/loop/init annotations,
# never authored) and register map (D-fs-2: bound/unbound/conflict against the board's own BoardPin rows). build/run
# reuse cmod-glue and the board installer/twin — nothing reimplemented here.
#
#   pol firmware help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"

usage() {
printf '%b\n' "$(cat <<EOF2
${BOLD}pol firmware${NC} — a CGraph + a board in, a firmware build out (fs-0 arc)

  ${CYAN}list${NC}                                   every FirmwareSolution row
  ${CYAN}show${NC} <solution>                        its DERIVED schedule (lane/order/trigger) + register map (bound/unbound/conflict)
  ${CYAN}validate${NC} <solution>                     board exists + usable, targets named, no pin conflicts
  ${CYAN}build${NC} <solution>                        cmod-glue render+build (reused) — refuses if validate() fails first
  ${CYAN}run${NC} <solution> [--mode digital-twin|hardware]
                                       validate -> the twin's equivalence proof, or the detected board's flash route
  ${CYAN}assign${NC} <solution> --task T [--port P] --pin <BoardPin>
                                       the door the pin-map drag (fs-1) will call (live server only — prints the
                                       equivalent POST /api/firmware/solutions/<solution>/assign here)

  <solution> = uno-sim-rig (seeded: the sim-rig firmware as a FirmwareSolution) or a FirmwareSolution row's name.
  Page: /display/firmware-solutions · API: /api/firmware/solutions · Selftest: pol modules selftest cmod
EOF2
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
py() { (cd "$FW" && PYTHONPATH=.:modules python3 -m cmod.custom.firmware_cli "$@"); }

case "$cmd" in
    help|-h|--help) usage ;;
    list) py list ;;
    show|validate|build) [ -n "${1:-}" ] || die "usage: pol firmware $cmd <solution>   (pol firmware list)"
          py "$cmd" "$1" ;;
    run) [ -n "${1:-}" ] || die "usage: pol firmware run <solution> [--mode digital-twin|hardware]"
         t="$1"; shift; py run "$t" "$@" ;;
    assign) [ -n "${1:-}" ] || die "usage: pol firmware assign <solution> --task T [--port P] --pin <BoardPin>"
            t="$1"; shift; py assign "$t" "$@" ;;
    *) log_error "unknown verb: pol firmware $cmd"; usage; exit 1 ;;
esac
