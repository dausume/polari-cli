#!/bin/bash
# capability.sh — `pol capability`: hw priorities P1 (AI-Notes/plans/HARDWARE_DEV_PRIORITIES.md §1/§4; module cmod).
# A CapabilityDefinition names ONE goal in a person's words ("read a temp sensor and send it back over USB to the
# OS") — the thread that runs through a Firmware Solution's c-device tasks AND a Cross-Domain Solution's relay AND a
# backend solution's handler. list/prove wrap the EXISTING `cmod.custom.capability_cli` module verbatim; show reads
# the same pure model functions that module already imports (`cmod.custom.capabilities`) — no new framework code.
#
#   pol capability help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol capability${NC} — the thread across a Firmware Solution + a Cross-Domain relay + a backend handler (hw priorities P1)

  ${CYAN}list${NC}                                   every CapabilityDefinition (name, DERIVED status, its goal — never hand-set)
  ${CYAN}show${NC} <name>                             its goal, per-runtime task references, required targets + their
                                       RegisterAssignment state, the validator's own verdict, and its acceptance scenario
  ${CYAN}prove${NC} <name> [--twin|--hardware]         runs its acceptance Scenario (firmwarefaults.custom.acceptance) and
                                       reports the outcome; --hardware is the EXISTING stopgap flash/detect path (hw
                                       priorities P2) — with no board plugged in it REFUSES with the readiness reason,
                                       never a faked pass. Default --twin.

  <name> = temp-sensor-to-os | blink-on-command (the two hw priorities P1 seeds) or a live CapabilityDefinition row.
  Page: /display/firmware-solutions (the Tasks section groups by Capability) · API: /api/capabilities
  Selftest: pol modules selftest cmod · Related: pol firmware (the Firmware Solution a capability's c-device tasks build)
EOF
)"
}

py() { (cd "$FW" && PYTHONPATH=.:modules python3 "$@"); }

cmd_show() {
    local name="$1"
    py -c "
import json, sys
from cmod.custom import capabilities as CAP
cap = CAP.find('$name')
if cap is None:
    print('[REFUSED] no capability %r (pol capability list)' % '$name')
    sys.exit(3)
ok, why = CAP.validate(cap)
status, proof, swhy = CAP.derive_status(cap)
print('%s — %s' % (cap['name'], cap['title']))
print('  goal        %s' % cap['goal'])
print('  purpose     %s' % cap.get('purpose', ''))
print('  status      %-18s %s' % (status, swhy))
print('  last proof  %s' % (proof or '-'))
print('  validator   %s' % ('ok' if ok else why))
print('  targets     %s' % (cap.get('required_targets') or '-'))
print('  exposes     %s' % (cap.get('exposes_fields') or '-'))
print('  acceptance  %s' % cap.get('acceptance_scenario', '-'))
tasks = json.loads(cap.get('tasks_by_runtime_json') or '{}')
for runtime in ('c-device', 'java-bridge', 'python-backend', 'typescript-browser'):
    refs = tasks.get(runtime) or []
    if refs:
        print('  %-11s %s' % (runtime, ', '.join(refs)))
"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
    help|-h|--help) usage ;;
    list) py -m cmod.custom.capability_cli list ;;
    show) [ -n "${1:-}" ] || die "usage: pol capability show <name>   (pol capability list)"
          cmd_show "$1" ;;
    prove) [ -n "${1:-}" ] || die "usage: pol capability prove <name> [--twin|--hardware]   (pol capability list)"
           name="$1"; shift; py -m cmod.custom.capability_cli prove "$name" "$@" ;;
    *) log_error "unknown verb: pol capability $cmd"; usage; exit 1 ;;
esac
