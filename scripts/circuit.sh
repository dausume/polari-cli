#!/bin/bash
# circuit.sh — `pol circuit`: THE CIRCUIT STATES of a firmware config (cst-0/1, AI-Notes/plans/PROTOTYPING_VIEWS_PLAN.md §2/§8; module electrodevice).
# A circuit state is one assignment of every component's electrical mode (button open | closed, LED off | forward, each pin driven-high |
# driven-low | input-pullup | input-hiz | high-z); two states differ when the SPICE netlist differs. Everything is DERIVED from the circuit
# rows, the HAL init (the source), the parsed atoms, the press record and the cited limits — never typed.
#
#   pol circuit help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"

usage() {
printf '%b\n' "$(cat <<USAGE
${BOLD}pol circuit${NC} — the electronic circuit STATES of a firmware config and what moves between them (cst arc)

    states <config> [--spice] [--json]   the reachable states (S1 uno-light: idle-led-off, button-held-led-off, led-on, led-on-button-held,
                                         reset-high-z, reset-button-held) with every part's mode and where it was read; --spice runs one .op
                                         per running state through ngspice (local binary: NGSPICE_BIN, PATH, ~/tools/ngspice) and judges the
                                         currents against the cited limits (I_PIN 40 mA abs-max / 20 mA recommended; VCC/GND 200 mA)
    transitions <config> [--json]        every move: external (press / release), firmware (the writer atom -> the pin reader, timed by the
                                         press record where measured), lifecycle (power/reset -> high-Z; init -> the HAL's modes)
    findings <config> [--json]           what SPICE and the structural floating-input rule flagged
    deck <config> <state> [--rpu 20000]  print the .op deck of one state (what ngspice would run)

  Doors: GET /api/circuit-states/<config>[/states|/transitions|/spice|/findings], POST /api/circuit-states/<config>/run (stores the rows)
  Selftest: pol modules selftest electrodevice  ·  PYTHONPATH=.:modules python3 -m electrodevice.circuit_states_selftest (in \$FW)
USAGE
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
py() { (cd "$FW" && PYTHONPATH=.:modules python3 -m electrodevice.custom.cst_cli "$@"); }
case "$cmd" in
    help|-h|--help) usage ;;
    states|transitions|findings|deck)
        [ -n "${1:-}" ] || die "usage: pol circuit $cmd <config> ...   (e.g. uno-light)"
        py "$cmd" "$@" ;;
    *) log_error "unknown verb: pol circuit $cmd"; usage; exit 1 ;;
esac
