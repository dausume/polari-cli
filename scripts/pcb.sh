#!/bin/bash
# pcb.sh — `pol pcb`: PCB from scratch (the pcb arc, AI-Notes/plans/PCB_FROM_SCRATCH_PLAN.md). KiCad is the RELAY
# ENGINE (headless kicad-cli, a separate process — never linked); Polari holds the design as rows and writes
# .kicad_sch/.kicad_pcb itself. pcb-0: the rows, the prf-pcb-engines worker, ingesting a real open KiCad board
# (parts/nets/footprints/placements + ERC/DRC/Gerbers), DKRed's fab rules cited, and the UNO shield schematic
# skeleton rendered from brd-bo's rows (no PCB yet — that is pcb-2).
#
#   pol pcb help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"
API="${POLARI_API:-https://api.polari.isle}"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol pcb${NC} — PCB from scratch: KiCad as the relay engine, rows as the design (pcb arc)

  engines                               where kicad-cli WOULD run (PCB_ENGINES_URL → local binary → the local
                                        image prf-pcb-engines:trixie → topology provider pcb.engines → refusal)
  ingest <path> [--board B] [--no-engine] [--api URL]
                                        a KiCad project directory → Part/Symbol/Footprint/PcbBoard/Placement/
                                        BoardNet/Route rows; with the engine reachable, also ERC + DRC (kind erc /
                                        drc / fab-rule) and every export (Gerbers, drill, pos, BOM, netlist, SVG,
                                        STEP) as FabricationExport rows, checked against DKRed's naming. --api
                                        posts to a running server's /api/pcb/ingest instead of printing locally.
  render-schematic uno-shield [--out FILE] [--api URL]
                                        THE UNO SHIELD schematic skeleton from brd-bo's rows (TMP36 on A0, LED +
                                        220 Ω on D6, the four headers) — writes a .kicad_sch directly and runs
                                        sch erc through the engine; unconnected header pins are reported, never
                                        hidden. --api posts to /api/pcb/render/uno-shield instead.

  No PCB yet (a person places/routes in KiCad, then \`pol pcb ingest\` reads it back — pcb-2).
  Selftest: pol modules selftest pcb  ·  PYTHONPATH=.:modules python3 -m pcb.pcb_selftest (in \$FW)
EOF
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
ARGS=(); API_SET=0
while [ $# -gt 0 ]; do case "$1" in --api) API="$2"; API_SET=1; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
py() { (cd "$FW" && PYTHONPATH=.:modules python3 "$@"); }
CURL="curl -sk --max-time 300 --resolve api.polari.isle:443:127.0.0.1"

case "$cmd" in
    help|-h|--help) usage ;;
    engines) py -m pcb.custom.pcb_cli engines ;;
    ingest)
        [ -n "${ARGS[0]:-}" ] || die "usage: pol pcb ingest <path> [--board B] [--no-engine] [--api URL]"
        if [ "$API_SET" = 1 ]; then
            board=""; for i in "${!ARGS[@]}"; do [ "${ARGS[$i]}" = "--board" ] && board="${ARGS[$((i+1))]}"; done
            python3 -c "import json,sys; print(json.dumps({'path': sys.argv[1], 'board': sys.argv[2] or None}))" "${ARGS[0]}" "$board" \
                | $CURL -X POST -H 'Content-Type: application/json' --data-binary @- "$API/api/pcb/ingest" \
                | python3 -c 'import json,sys; d=json.load(sys.stdin); print(("[ OK ] stored " + json.dumps(d.get("stored")) if d.get("ok") else "[FAIL] " + str(d.get("error"))))'
        else
            py -m pcb.custom.pcb_cli ingest "${ARGS[@]}"
        fi ;;
    render-schematic)
        [ -n "${ARGS[0]:-}" ] || die "usage: pol pcb render-schematic uno-shield [--out FILE] [--api URL]"
        if [ "$API_SET" = 1 ]; then
            $CURL -X POST -H 'Content-Type: application/json' --data '{}' "$API/api/pcb/render/uno-shield" \
                | python3 -c 'import json,sys; d=json.load(sys.stdin); print(("[ OK ] %d components, %d connections, %d unconnected pins, erc violations %s" % (d.get("components",0), d.get("connections",0), d.get("unconnectedPins",0), d.get("ercViolations"))) if d.get("ok") else "[FAIL] " + str(d.get("error")))'
        else
            py -m pcb.custom.pcb_cli render-schematic "${ARGS[@]}"
        fi ;;
    *) log_error "unknown verb: pol pcb $cmd"; usage; exit 1 ;;
esac
