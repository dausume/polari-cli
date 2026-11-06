#!/bin/bash
# plans.sh — `pol plans`: the plans a person manipulates from the CLI (cis arc). An UMBRELLA with aliases only:
# the two task-plan doors are the only ones it owns; everything else forwards to the verb that already exists.
#
#   pol plans help
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/pol-api.sh"

usage() {
printf '%b\n' "$(cat <<USAGE
${BOLD}pol plans${NC} — mission task plans, app plans and bench specs from one place (cis arc; aliases, no logic of its own)

  Shared flags: ${CYAN}--api URL${NC}  ${CYAN}--json${NC}   Exit: 0 ok · 1 refused (backend's words on stderr) · 2 unreachable / usage

  ${CYAN}task show <mission>${NC}                     the recorded task plan             GET  /api/missions/<m>/task-plan
  ${CYAN}task set <mission> --file plan.json${NC}     record / derive it                 POST /api/missions/<m>/task-plan   (body = the file)
  ${CYAN}task also-runs-on <plan> --file b.json${NC}  the plan also runs on …            POST /api/task-plans/<p>/also-runs-on
  ${CYAN}app <name> [...]${NC}                        = pol apps plan <name> …           (forwards)
  ${CYAN}spec list${NC} / ${CYAN}spec apply <bench> [--spec N]${NC}   = pol bench specs / apply-spec  (forwards)
USAGE
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in
    help|-h|--help) usage ;;
    task)
        sub=${1:-}; shift || true
        pol_api_flags "$@" || exit 2; set -- "${ARGS[@]+"${ARGS[@]}"}"
        case "$sub" in
            show) [ -n "${1:-}" ] || die "usage: pol plans task show <mission>"
                  rc=0; RESP=$(pol_api GET "/api/missions/$(pol_api_enc "$1")/task-plan") || rc=$?
                  [ $rc -eq 0 ] || { [ "$JSON" = 1 ] && printf '%s\n' "$RESP"; exit $rc; }
                  if [ "$JSON" = 1 ]; then printf '%s\n' "$RESP"; else printf '%s' "$RESP" | pretty 'print(json.dumps(d, indent=2)[:4000])'; fi ;;
            set|also-runs-on)
                  [ -n "${1:-}" ] || die "usage: pol plans task $sub <name> --file plan.json"
                  name=$1; shift; f=''; while [ $# -gt 0 ]; do case "$1" in --file) f=$2; shift 2 ;; *) shift ;; esac; done
                  [ -f "$f" ] || die "pol plans task $sub needs --file <json>"
                  if [ "$sub" = set ]; then p="/api/missions/$(pol_api_enc "$name")/task-plan"; else p="/api/task-plans/$(pol_api_enc "$name")/also-runs-on"; fi
                  rc=0; RESP=$(pol_api POST "$p" "$(cat "$f")") || rc=$?
                  [ $rc -eq 0 ] || { [ "$JSON" = 1 ] && printf '%s\n' "$RESP"; exit $rc; }
                  if [ "$JSON" = 1 ]; then printf '%s\n' "$RESP"; else printf '%s' "$RESP" | pretty 'print("  [ OK ] " + json.dumps(d)[:300])'; fi ;;
            *) log_error "unknown: pol plans task $sub"; usage; exit 2 ;;
        esac ;;
    app)  exec bash "$SCRIPT_DIR/apps.sh" plan "$@" ;;
    spec)
        sub=${1:-}; shift || true
        case "$sub" in
            list)  exec bash "$SCRIPT_DIR/bench.sh" specs "$@" ;;
            apply) exec bash "$SCRIPT_DIR/bench.sh" apply-spec "$@" ;;
            *) log_error "unknown: pol plans spec $sub"; usage; exit 2 ;;
        esac ;;
    *) log_error "unknown verb: pol plans $cmd"; usage; exit 2 ;;
esac
