#!/bin/bash
# grpc.sh — `pol grpc`: the gRPC bridge arc's verbs. sim-2: `hosted` — the generated Java bridge run on a worker BESIDE a twin session
# (AI-Notes/plans/HARDWARE_BENCH_CONVERGENCE_PLAN.md), a client of the server's /api/grpc/hosted-bridges doors.
#
#   pol grpc help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FW="$SUITE/polari-rf-node/polari-framework"
API="${POLARI_API:-https://api.polari.isle}"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol grpc${NC} — the gRPC hardware bridge (grpc arc)

  ${CYAN}hosted bridges${NC} (sim-2: the generated bridge, hosted on a worker beside a twin session)
    hosted start <session> [--bridge uno-light] [--ttl S] [--owner O] [--grpc-target HOST:PORT | --log-only] [--wait S] [--api URL]
                                      <session> = a twin session name (pol board twin session list). The worker builds the generated
                                      project (cached by its sha) and runs it with source=twin-tcp: it reads the session's serial port and pushes
                                      the decoded struct to the server's gRPC bridge port (default: port 3002 of the host --api points at), so the
                                      LightState row follows the simulated board and light-toggle reaches it. --log-only = no gRPC, just decode
                                      and log (the proof mode). The bridge ends with its TTL, with its session, or on stop.
    hosted list [--api URL]
    hosted show <id> [--api URL]      state, the jar, the tail of the bridge's output, its RSS and CPU seconds
    hosted stop <id> [--api URL]
    hosted logs <id> [--tail N] [--build] [--api URL]
                                      the bridge's output (--build: the jar build's output)
    hosted engines [--api URL]        where hosted bridges would run (BRIDGE_ENGINES_URL → topology provider grpcbridge.engines → refusal)

  Add --json for the raw answer.  Selftest: pol modules selftest grpcbridge
EOF
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
JSON=0; ARGS=()
while [ $# -gt 0 ]; do case "$1" in --json) JSON=1; shift ;; --api) API="$2"; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
py() { (cd "$FW" && PYTHONPATH=.:modules python3 "$@"); }

case "$cmd" in
    help|-h|--help) usage ;;
    hosted)
        [ -n "${ARGS[0]:-}" ] || die "usage: pol grpc hosted start <session>|list|show <id>|stop <id>|logs <id>|engines [--api URL]"
        py -m grpcbridge.custom.hosted_cli "${ARGS[@]}" --api "$API" $( [ "$JSON" = 1 ] && echo --json ) ;;
    *) die "unknown: pol grpc $cmd (try: pol grpc help)" ;;
esac
