#!/bin/bash
# faults.sh — `pol faults`: firmware scenario analysis (the sc arc, AI-Notes/plans/FIRMWARE_SCENARIO_PLAN.md; module
# firmwarefaults). Force ONE interleaving on the UNO twin at an exact PC — BEFORE the technique (the fault at a named cycle)
# and AFTER it (the technique holding) — and print the pair with what the technique costs. Runs HERE through the board
# engines seam (local binary → prf-board-engines image → BOARD_ENGINES_URL worker); --api URL runs it on that server instead.
#
#   pol faults help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol faults${NC} — force a firmware fault on purpose, see where it goes wrong, see what the fix costs (sc arc)

  ${CYAN}scenarios${NC}
    list [--api URL]                  the scenarios (runnable or why not), the step kinds the harness can force today
                                      (sc-0: irq-at-pc, irq-at-cycle, corrupt-word; sc-1: respond, drop-nth-frame, inject-bytes,
                                      uart-ber, rx-noise, reset-at, jump-at, eeprom-preload) and why the rest cannot yet, the runs
    run <scenario> [--before|--after|--both|--natural|--control] [--seconds S] [--seed N] [--api URL]
                                      build the variant(s), resolve each step against the build's own disassembly, run the
                                      twin, decode the frames, read the VCD window → outcome (failed | passed | inapplicable |
                                      undetermined), the claim it writes (refuted | witnessed | …), and for --both the cost
                                      of the technique (flash bytes, cycles per call, worst ISR latency). Default --both.
                                      --natural: no forcing, 10 s — the fault's measured rate (written onto the fault row)
                                      --control: brownout-mid-eeprom-write's EEPROM-persistence check (reset AFTER the write)
    stats <scenario> [--seeds N] [--bers 1e-3,1e-4,1e-5] [--verbose] [--api URL]
                                      the statistics tier: uart-residual-frame-loss under --uart-ber (500 commands x N seeds per
                                      BER, BEFORE and AFTER, the residual apart) or torn-millis-read's phase sweep (asynchronous RX
                                      traffic x N seeds → torn reads per carry) — rates with Wilson 95 % intervals, onto the fault row
    show <run> [--api URL]            one run: where it fired, where the interrupt landed, the cycles around the fault, the claim
    engines                           where avr-twin / avr-objdump / avr-nm / vcd-window would run (the board engines seam)

  Seeded: torn-millis-read (scenario 1: the tick ISR forced between the 1st and 2nd lds of g_ms — BEFORE uno-sim-rig-torn,
  AFTER uno-sim-rig), rx-ring-over-256 (1b: refused by hal.c's static guard); sc-1: lost-ack-hang (S2), button-bounce-double-count
  (S3), uart-residual-frame-loss (S4), brownout-mid-eeprom-write (S5), runaway-hang-watchdog (plan §4); priority-inversion-mutex and
  two-lock-deadlock are written down but not-yet-forcible (no RTOS on the UNO). Records: \$POLARI_FAULTS_HOME (~/.cache/polari-faults).
  Page: /display/firmware-faults · Selftest: pol modules selftest firmwarefaults · Probe: tests/firmwarefaults_probe.py (in $FW)
EOF
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
py() { (cd "$FW" && PYTHONPATH=.:modules python3 "$@"); }

case "$cmd" in
    help|-h|--help) usage ;;
    list|engines) py -m firmwarefaults.custom.faults_cli "$cmd" "$@" ;;
    stats) [ -n "${1:-}" ] || die "usage: pol faults stats uart-residual-frame-loss|torn-millis-read [--seeds N]"
          py -m firmwarefaults.custom.faults_cli stats "$@" ;;
    run)  [ -n "${1:-}" ] || die "usage: pol faults run <scenario> [--before|--after|--both|--natural]   (pol faults list names them)"
          py -m firmwarefaults.custom.faults_cli run "$@" ;;
    show) [ -n "${1:-}" ] || die "usage: pol faults show <run>   (pol faults list names the recorded runs)"
          py -m firmwarefaults.custom.faults_cli show "$@" ;;
    *) log_error "unknown verb: pol faults $cmd"; usage; exit 1 ;;
esac
