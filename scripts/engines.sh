#!/bin/bash
# engines.sh — `pol engines`: the engines a Polari backend knows from the isle (fix 11), over its HTTP API (cis arc).
# Thin client over the EXISTING doors: GET /api/islemesh/engines and POST /api/islemesh/engines/sync. No root, no isle.
#
#   pol engines help
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/pol-api.sh"

usage() {
printf '%b\n' "$(cat <<USAGE
${BOLD}pol engines${NC} — the engines this backend has bound from the isle's registry (fix 11)

  Shared flags: ${CYAN}--api https://api.<name>.isle${NC} (else \$POL_API / \$POLARI_API, else the local docker backend)  ${CYAN}--json${NC}
  Exit: 0 ok · 1 refused (the backend said no; words on stderr) · 2 unreachable / usage.
        For ${CYAN}sync${NC}, exit 1 also means the isle registry could not be read (HTTP 502 + words; nothing changed).

  ${CYAN}list${NC}            every IsleEngine row: name, kind, url, device, bound -> bound_to, note     GET  /api/islemesh/engines
  ${CYAN}sync${NC}            pull the isle core's registry NOW (what boot does) and bind / retire     POST /api/islemesh/engines/sync
                  needs ISLE_CORE_API set in the backend's environment; unset = "no isle registry configured"

  Selftest: scripts/bench-selftest.sh (covers lib/pol-api.sh) + scripts/engines-selftest.sh (fake curl, no network)
USAGE
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
pol_api_flags "$@" || exit 2
set -- "${ARGS[@]+"${ARGS[@]}"}"
call() { local rc=0; RESP=$(pol_api "$@") || rc=$?; if [ $rc -ne 0 ]; then [ "$JSON" = 1 ] && printf '%s\n' "$RESP"; exit $rc; fi; }
out() { if [ "$JSON" = 1 ]; then printf '%s\n' "$1"; else printf '%s' "$1" | pretty "$2"; fi; }

case "$cmd" in
    help|-h|--help) usage ;;
    list) call GET /api/islemesh/engines
        out "$RESP" '
rows = d.get("engines", [])
for r in rows:
    print("  %-28s %-12s %-34s device %-12s %s %s  %s" % (r.get("name"), r.get("provides"), r.get("url"), r.get("device") or "unknown",
          "bound  ->" if r.get("bound") else "UNBOUND  ", r.get("bound_to") or "-", (r.get("note") or "")[:70]))
if not rows: print("  (no engines recorded on this backend)")' ;;
    sync) call POST /api/islemesh/engines/sync '{}'
        out "$RESP" '
print("  [ OK ] " + d.get("words", ""))
for b in d.get("bound") or []: print("   bound   %-28s -> %s  (%s, device %s)" % (b.get("engine"), b.get("bound_to"), b.get("url"), b.get("device")))
for u in d.get("unbound") or []: print("   unbound %-28s %s" % (u.get("engine"), u.get("note")))
for m in d.get("skipped_mock") or []: print("   mock    %-28s skipped" % m)
for r in d.get("retired") or []: print("   retired %s" % r)' ;;
    *) log_error "unknown verb: pol engines $cmd"; usage; exit 2 ;;
esac
