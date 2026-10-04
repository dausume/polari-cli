#!/bin/bash
# board.sh — `pol board`: boards programmed over USB from Polari (the brd arc,
# AI-Notes/plans/BOARD_PROGRAMMING_PLAN.md). detect runs ON THIS HOST (host python:
# hwmap's scanner + the board definitions, no server needed); --push upserts the
# result as BoardInstance rows through the API. brd-1: gen / build / flash / twin / cost for the UNO —
# flash is a DRY-RUN unless the board is detected AND --yes is given. brd-fi: firmware VARIANTS (gen --variant) and the
# installer (install / variants / result) — the same doors as /display/firmware-installer. brd-wire (grpc-j4): the
# computer<->firmware mapping — gen --instance-index, twin --tag (several twins side by side), interface <instance>.
# sc-3: the ESP32-C3 — gen / build / flash / twin / cost c3 (ESP-IDF + FreeRTOS through prf-esp-engines; the QEMU twin).
# brd-bo: THE BOARD OBJECT — pins / render / ingest / conflicts / assign (one board shared by KiCad, Zephyr, ESP-IDF, bare C).
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

  ${CYAN}the UNO end to end${NC} (brd-1; plain C on avr-libc — RULE 2)
    gen uno [--variant V | --class C] [--api URL] [--rig-name N] [--device-id N] [--u2x 0|1] [--out DIR]
            [--instance-index K]
                                      render the variant's project around the generated header(s) (target=avr, wire
                                      v2; live from --api, else the pinned contract) → FirmwareBuild state generated,
                                      with header_sha256, the wire order and hash v2 (no --variant = uno-sim-rig);
                                      --instance-index = this build's index among its bridge's bound interfaces
    build uno [--work DIR]            avr-gcc + avr-objcopy + avr-size through the engines ladder (local avr-gcc
                                      → the prf-board-engines image → BOARD_ENGINES_URL worker); REFUSED past
                                      32256 B flash / 2048 B RAM; the .hex sha256 + engine versions + repro block
    flash uno [--port P] [--yes] [--api URL]
                                      DRY-RUN (default): prints the exact avrdude argv. A real flash needs the UNO
                                      detected on THIS host AND --yes; verified by read-back; stamps firmware_sha
    twin uno up|down|status [--adc0-mv 750 | --adc0-ramp LO,HI,MS] [--tcp 9831] [--link /tmp/polari-uno-twin-uart]
            [--work DIR --tag T]
                                      the SAME .hex in simavr; its UART at a pty link — point a bridge at it:
                                      source=serial, serialDevice=<link>. --tag runs another twin beside the first
                                      (its own --work, --tcp, --link: uno-pair = tags 0 and 1)
    cost uno [--write]                re-measure the twin's object cost (rows, simavr state bytes, cycles/s)

  ${CYAN}the ESP32-C3${NC} (sc-3; D-sc-4 ruled — ESP-IDF v5.5.5 C, FreeRTOS; the prf-esp-engines worker; twin-first)
    gen c3 [--variant V] [--api URL] [--rig-name N] [--device-id N] [--out DIR]
                                      the ESP-IDF C project around the generated header (c_twin target=host — the
                                      UNO's wire v2, so the SAME bridge attaches); variants: c3-sim-rig (default),
                                      c3-prio-inversion[-mutex], c3-two-lock[-ordered|-backoff] (SCENARIO ONLY)
    build c3 [--work DIR] [--force]   idf.py build through the engines ladder (ESP_ENGINES_URL → local → the
                                      prf-esp-engines image → board.esp-engines); idf.py size; reproducible images;
                                      the build cache (same sources + image = no rebuild)
    flash c3 [--port P] [--yes]       DRY-RUN (default): the exact esptool write_flash argv from idf.py's flash_args
    twin c3 up|down|status [--tcp 9832] [--link /tmp/polari-c3-twin-uart]
                                      the SAME merged image in Espressif's QEMU fork (-machine esp32c3); UART0 at a pty
                                      link (source=serial), UART1 = the FreeRTOS trace (status shows its tail)
    cost c3 [--write]                 re-measure the C3 twin's cost (QEMU RSS, virtual instructions/s, wall-time ratio)

  ${CYAN}THE BOARD OBJECT${NC} (brd-bo; one board shared by KiCad, Zephyr, ESP-IDF/FreeRTOS, bare C and Polari — no server needed)
    pins <board>                      the pin assignment (pins named ONCE: D6, A0, GPIO21 …) ↔ SoC pin ↔ net ↔ connector
                                      pin ↔ function / peripheral ↔ C symbol, the runtime profiles, the rules, the board sha
    render <board> --as kicad|zephyr|esp-idf|bare-c [--out DIR]
                                      the view generated FROM the rows (header names the board sha); a board a world
                                      cannot target is REFUSED with why (the UNO in Zephyr: no AVR arch) — a BoardView row
    ingest <path> --as KIND [--board B]
                                      read a view back (KiCad .net, Zephyr overlay/dts, ESP-IDF board_pins.h + sdkconfig,
                                      bare-C board_config.h): disagreements become BoardConflict rows; the rows never change
    conflicts [<board>]               the conflicts (shown, never auto-resolved)
    assign <board> <net> <pin>        THE FLIP: move a net (e.g. uno PWM_LED D5) and print every view's changed lines
    (with a server: GET /api/board/<board>/pins|views|conflicts, POST /api/board/<board>/render|ingest)

  ${CYAN}the firmware installer${NC} (brd-fi; different things to test on the one UNO)
    variants [--api URL]              the firmware variants: what each tests, what to watch for (offline: the seeded five
                                      — uno-sim-rig, uno-blink-only, uno-adc-sweep, uno-pair, uno-echo)
    install uno [--variant V] [--twin] [--dry-run | --yes] [--api URL]
                                      plan + run + attach in one, through the server on the host holding the port:
                                      picks (or builds) the variant's compatible build, prints the plan's argv (the
                                      DRY-RUN, the default); --yes installs, attaches the bridge, prints the first
                                      frames. --twin = the simavr twin. Exit 3 = refused (stale-header /
                                      unknown-class firmware, no board, the wrong host)
    result [RECORD] [--api URL]       an install's result: verdict, read-back, bridge, frames/s, the row now

  ${CYAN}the computer↔firmware mapping${NC} (brd-wire / grpc-j4)
    interface <instance> [--api URL]  the binding chain of a board instance: row → class → contract (hash v1) → wire
                                      contract (hash v2, index width / representation) → binding (index, port) →
                                      instance → board definition → cited facts (e.g. twin:arduino-uno-r3#1)

  The two rules: USB from the host (directly or through a known adapter); C / Verilog / SystemVerilog only.
  Selftest: pol modules selftest board  ·  PYTHONPATH=.:modules python3 -m board.board_selftest (in $FW)
EOF
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
PUSH=0; JSON=0; ARGS=()
API_SET=0
while [ $# -gt 0 ]; do case "$1" in --push) PUSH=1; shift ;; --json) JSON=1; shift ;; --api) API="$2"; API_SET=1; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
api_arg() { [ "$API_SET" = 1 ] && printf -- '--api\n%s\n' "$API"; return 0; }
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
    gen)   [ -n "${ARGS[0]:-}" ] || die "usage: pol board gen uno [--class SimRigState] [--api URL]"
           mapfile -t A < <(api_arg); py -m board.custom.gen "${ARGS[@]}" "${A[@]}" ;;
    build) [ -n "${ARGS[0]:-}" ] || die "usage: pol board build uno"
           py -m board.custom.build "${ARGS[@]}" ;;
    flash) [ -n "${ARGS[0]:-}" ] || die "usage: pol board flash uno [--port P] [--yes]"
           mapfile -t A < <(api_arg); py -m board.custom.flash "${ARGS[@]}" "${A[@]}" ;;
    twin)  [ -n "${ARGS[1]:-}" ] || die "usage: pol board twin uno up|down|status"
           py -m board.custom.twin "${ARGS[@]}" ;;
    cost)  py -m board.custom.sim_cost "${ARGS[@]}" ;;   # sc-3: `cost uno` | `cost c3` (the board word is read by sim_cost)
    pins|render|ingest|conflicts|assign)   # brd-bo: THE BOARD OBJECT (rows = the seeds offline; views/conflicts in the local ledger)
           py -m board.custom.board_object_cli "$cmd" "${ARGS[@]}" ;;
    variants) mapfile -t A < <(api_arg); py -m board.custom.install_cli variants "${A[@]}" ;;
    install) [ -n "${ARGS[0]:-}" ] || die "usage: pol board install uno [--variant V] [--twin] [--dry-run|--yes] [--api URL]"
             py -m board.custom.install_cli install "${ARGS[@]}" --api "$API" ;;
    result)  py -m board.custom.install_cli result "${ARGS[@]}" --api "$API" ;;
    interface) [ -n "${ARGS[0]:-}" ] || die "usage: pol board interface <instance>   (e.g. twin:arduino-uno-r3#1)"
             inst=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${ARGS[0]}")
             $CURL "$API/api/board/instances/$inst/interface" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    print("[REFUSED] " + str(d.get("error"))); sys.exit(3)
print("[ OK ] " + d["plain"])
for l in d["links"]:
    w, b = l["wire"], l["binding"]
    print("       row      %s %s  (id %s)" % (l["object"]["class"], l["object"]["name"], l["object"]["id"] or "-"))
    print("       contract v%s  hash v1 %s   wire hash v2 %s  index %s (%s bit(s) packed, %s byte(s) explicit; suggested %s)  prelude %s B" % (l["contract"]["version"], l["contract"]["contract_hash_v1"] or "-", w.get("contract_hash_v2", "-"), w.get("index_repr", "-"), w.get("index_width", "-"), w.get("index_bytes", "-"), w.get("suggested_index_width", "-"), w.get("prelude_bytes", "-")))
    print("       binding  %s  index %s on bridge %s  %s %s at %s  frames %s (refused %s)" % (b["name"], b["instance_index"], b["bridge_name"], b["interface_kind"], b.get("interface_name", ""), l["port"]["path"], b["frames_seen"], b["refused_frames"]))
    print("       board    %s  facts %d  missing: %s" % (l["board_definition"]["name"], len(l["datasheet_facts"]), "; ".join(l["missing"]) or "none"))
' ;;
    *) log_error "unknown verb: pol board $cmd"; usage; exit 1 ;;
esac
