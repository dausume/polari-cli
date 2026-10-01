#!/bin/bash
# board.sh — `pol board`: boards programmed over USB from Polari (the brd arc,
# AI-Notes/plans/BOARD_PROGRAMMING_PLAN.md). detect runs ON THIS HOST (host python:
# hwmap's scanner + the board definitions, no server needed); --push upserts the
# result as BoardInstance rows through the API. Nothing here flashes a chip.
#
#   pol board help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"
API="${POLARI_API:-https://api.polari.isle}"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol board${NC} — boards programmed over USB / USB-C from Polari (brd arc)

  ${CYAN}see what is plugged in${NC}
    detect [--json]                   scan THIS host (hwmap's scanner) and match every USB device against the
                                      board + adapter definitions: board present | adapter present, target
                                      unknown | unadmitted (never guessed, never stored)
    detect --push [--api URL]         the same scan, POSTed to /api/board/detect — matched devices become
                                      BoardInstance rows (default API: \$POLARI_API or the local isle api)

  ${CYAN}what is tracked${NC} (the register as rows; works with no server)
    list                              every device: kind, programmer, USB rule, simulated, twin, road status;
                                      then every adapter with its VID:PIDs
    roads                             each device's road (todo | in-progress | done per step)
    facts <board>                     the cited datasheet facts of one board (the UNO has them first)
    engines                           where avr-gcc / avrdude / simavr / … WOULD run (BOARD_ENGINES_URL →
                                      local binary → topology provider board.engines → refusal)

  The two rules: USB from the host (directly or through a known adapter); C / Verilog / SystemVerilog only.
  Selftest: pol modules selftest board  ·  PYTHONPATH=.:modules python3 -m board.board_selftest (in $FW)
EOF
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
PUSH=0; JSON=0; ARGS=()
while [ $# -gt 0 ]; do case "$1" in --push) PUSH=1; shift ;; --json) JSON=1; shift ;; --api) API="$2"; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
py() { (cd "$FW" && PYTHONPATH=.:modules python3 "$@"); }
CURL="curl -sk --max-time 30 --resolve api.polari.isle:443:127.0.0.1"

case "$cmd" in
    help|-h|--help) usage ;;
    detect)
        if [ "$PUSH" = 1 ]; then
            py -m board.custom.detect --snapshot | $CURL -X POST -H 'Content-Type: application/json' --data-binary @- "$API/api/board/detect" \
                | python3 -c 'import json,sys; d=json.load(sys.stdin); print(("[ OK ] stored %s instance(s); " % d.get("stored") if d.get("ok") else "[FAIL] ") + json.dumps(d.get("summary") or d))'
        elif [ "$JSON" = 1 ]; then
            py -m board.custom.detect --json
        else
            py -m board.custom.detect
        fi ;;
    list|roads|engines) py -m board.custom.board_cli "$cmd" ;;
    facts)
        [ -n "${ARGS[0]:-}" ] || die "usage: pol board facts <board>   (e.g. arduino-uno-r3; pol board list names them)"
        py -m board.custom.board_cli facts "${ARGS[0]}" ;;
    *) log_error "unknown verb: pol board $cmd"; usage; exit 1 ;;
esac
