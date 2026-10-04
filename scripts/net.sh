#!/bin/bash
# pol net — firewall-handshake plumbing shared by swarm/engine bindings:
# what a binding needs open (pol net needs) and the hand-back journal of
# every rule pol ever applied with consent (pol net handback). The
# handshake itself — turning CLOSED ports into consented, source-scoped
# ufw rules — lives in `pol swarm ports --apply` / `pol swarm join`
# (see pol swarm help); this module is the data table + the undo ledger.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/net-needs.sh"
source "$SCRIPT_DIR/lib/fw-handshake.sh"

NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"

# resolve_host_alias <name> — a nodes.yml machine name resolves to its ssh
# alias (possibly "" = this host); anything else is used as a literal ssh
# alias (so an ad-hoc ~/.ssh/config host still works for handback).
resolve_host_alias() {
    local name=$1
    [ -n "$name" ] || { echo ""; return 0; }
    if [ -f "$NODES_FILE" ]; then
        local a
        a=$(python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
n = (d.get('nodes') or {}).get(sys.argv[2])
print(n['ssh'] if n and 'ssh' in n else '__notfound__')
" "$NODES_FILE" "$name" 2>/dev/null || echo __notfound__)
        if [ "$a" != "__notfound__" ]; then echo "$a"; return 0; fi
    fi
    echo "$name"
}

show_help() {
    pol_box "pol net — firewall-handshake plumbing"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}needs <binding> [port]${NC}
                    the port-needs table for a binding kind:
                      swarm-manager          accepts from a worker joining
                      swarm-worker           accepts from the manager
                      engine-worker <port>   accepts a direct caller (not
                                             mesh) — 9830|9840|9850|9860
  ${CYAN}handback [<node>] [--peer <label>] [--apply] [--yes]${NC}
                    list (default) or, with --apply, REPLAY IN REVERSE and
                    shrink, the firewall hand-back journal: every rule pol
                    ever applied with consent, read from the host where it
                    applied it (~/.polari/handback/firewall.jsonl).
                    <node> is a nodes.yml machine name or a raw ssh alias;
                    omitted = this host. --peer filters to rules opened
                    for one node/binding (e.g. the node pol swarm leave
                    is about to drop).

${BOLD}THE HANDSHAKE ITSELF${NC} (see 'pol swarm help')
  pol swarm ports <node> --apply   open closed swarm-manager ports, with consent
  pol swarm join  <node>           does the same by default (--no-apply to
                                    only print, the old behaviour)
  pol swarm leave <node>           hands back what join opened, then leaves

${BOLD}THE RULES${NC}
  - ingress is closed by default; every rule is SOURCE-SCOPED
    (allow from <peer ip> to any port <p> proto <tcp|udp>) — never a
    blanket 'allow <port>'
  - nothing is ever applied without a real sudo password or a typed y/N —
    never in a pipeline/CI, never without a TTY (POL_ASSUME_NO=1 or any
    CI env also refuses, for scripting a dry run on purpose)
  - ufw only; firewalld/nftables get the equivalent command PRINTED, never
    applied
  - every applied rule is journaled on the host it touched and can be
    handed back later (pol net handback --apply)
"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    needs)
        BINDING=${1:?usage: pol net needs <swarm-manager|swarm-worker|engine-worker> [port]}
        net_needs_print "$BINDING" "${2:-}" ;;
    handback)
        NODE=""; PEER=""; APPLY=0; YES=0
        while [ $# -gt 0 ]; do case "$1" in
            --peer) PEER="$2"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            --yes) YES=1; shift ;;
            --host) NODE="$2"; shift 2 ;;   # accepted alongside the positional form
            *) NODE="$1"; shift ;;
        esac; done
        ALIAS=$(resolve_host_alias "$NODE")
        if [ "$APPLY" = 1 ]; then
            fw_handback_apply "$ALIAS" "$PEER" "$YES"
        else
            fw_handback_list "$ALIAS" "$PEER"
        fi ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown net command: $COMMAND"; show_help; exit 1 ;;
esac
