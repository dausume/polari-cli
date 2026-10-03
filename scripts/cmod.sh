#!/bin/bash
# cmod.sh — `pol cmod`: C modularization (the cmod arc, AI-Notes/plans/C_MODULARIZATION_PLAN.md; module cmod). A firmware
# project stays a NORMAL C project that builds with make alone; Polari DERIVES its atoms — C functions with declared ports,
# the registers/globals/ISRs they touch, pure / ISR-safe verdicts, their cost — by parsing (pycparser), into the conformed
# polari-firmware.json beside the Makefile. Parsing runs here with no engine; the cost and the make-alone proof run through
# the board engines seam (local avr-gcc → prf-board-engines image → BOARD_ENGINES_URL worker).
#
#   pol cmod help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"

usage() {
printf '%b\n' "$(cat <<EOF2
${BOLD}pol cmod${NC} — C functions as Polari atoms: ports, resources, cost — the C stays a normal C project (cmod arc)

  ${CYAN}atoms${NC} <project>                  parse NOW (pycparser, no engine): one entry per atom — kind, signature, ports
                                    (in/out/inout with the Polari type), what it touches, pure, ISR-safe (and why not)
  ${CYAN}conform${NC} <project> [--no-measure] parse + measure (avr-gcc -fstack-usage, avr-nm, make alone per configuration)
                                    → polari-firmware.json in the project root; written ONLY when something derived
                                    changed (a second conform: unchanged); title / description / notes are yours
  ${CYAN}show${NC} <atom> [--project P]        one atom of the committed manifest: ports, resources, ISR-safety, cost
  ${CYAN}drift${NC} <project>                  the committed manifest vs the sources (nothing measured, nothing written)
  ${CYAN}registers${NC} [--refresh]            the register snapshot (avr-libc <avr/io.h> via avr-gcc -E -dM)
  ${CYAN}engines${NC}                          where avr-gcc / avr-nm / make would run

  <project> = uno (the UNO firmware template in the board module) or a DIRECTORY with *.c and a Makefile — your own
  project, untouched except for the polari-firmware.json it gains.
  Annotate (optional, changes no byte): POLARI_NODE(fn, in(x, "unit", "meaning"), out(return, "unit"), uses(PIN), role("…"))
  right above the function, with  #define POLARI_NODE(...)  in your header — or /* @polari-node(fn, …) */ in a comment.
  Page: /display/c-atoms · API: /api/cmod · Selftest: pol modules selftest cmod · Probe: tests/cmod_liveboot_probe.py (in $FW)
EOF2
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
py() { (cd "$FW" && PYTHONPATH=.:modules python3 "$@"); }
abs() { case "${1:-}" in ""|uno) echo "${1:-uno}" ;; /*) echo "$1" ;; *) [ -d "$1" ] && (cd "$1" && pwd) || echo "$1" ;; esac; }

case "$cmd" in
    help|-h|--help) usage ;;
    atoms|conform|drift) [ -n "${1:-}" ] || die "usage: pol cmod $cmd uno|<dir>   (pol cmod help)"
          p="$(abs "$1")"; shift; py -m cmod.custom.cmod_cli "$cmd" "$p" "$@" ;;
    show) [ -n "${1:-}" ] || die "usage: pol cmod show <atom> [--project uno|<dir>]   (pol cmod atoms uno names them)"
          py -m cmod.custom.cmod_cli show "$@" ;;
    registers|engines) py -m cmod.custom.cmod_cli "$cmd" "$@" ;;
    *) log_error "unknown verb: pol cmod $cmd"; usage; exit 1 ;;
esac
