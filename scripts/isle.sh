#!/bin/bash
# pol isle — the isle-mesh convergence namespace (mac arcs).
#
# Isle-mesh (Dustin's networking project, lives on isle-core:
# ~/Isle-Mesh with its own `isle` CLI) is THE network of the merged
# system: genuinely separate vLAN, .isle DNS, per-device nginx
# agents. Polari accepts isle's data (islemesh module, mac-1) and
# will drive placement over it (mac-5); docker swarm rides ON the
# isle network as the dynamic up/down/move layer (handoff §7).
#
# First real verbs (mac-1): status / sync / mock / matrix. sync
# sends REAL device/registry/fragment data and NEVER sets the mock
# flag; mock seeds the built-in mock network whose every payload
# declares mock_network=true — the summary banner makes the
# difference loud. Orchestration verbs still refuse honestly until
# their phase (see MESH_APP_CONVERGENCE_PLAN.md).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/core-api.sh"

show_help() {
    pol_box "pol isle — isle-mesh convergence"
    echo -e "
  ${CYAN}status${NC}          isle summary from the core (devices/apps/permits
                  counts + the MOCK NETWORK banner when mock data is live)
  ${CYAN}sync [host...]${NC}  pull REAL isle data over SSH (device facts, agent
                  registry.json, nginx fragments) and ingest it.
                  Defaults: isle-core + this machine.
  ${CYAN}mock${NC}            seed the built-in MOCK isle network — every row
                  flagged; the page shows the banner at the top
  ${CYAN}matrix${NC}          the protocol matrix (the proxies ARE the policy)
  ${CYAN}retire <device>${NC} drop a device row + its attributed rows (left the
                  mesh, or was ingested under a wrong name)

Not yet implemented (arrive with their mac phase): app packaging
(mac-4), placement apply (mac-5), .isle url ops (mac-10).
Reference implementation: isle-core:~/Isle-Mesh (its own 'isle' CLI).
"
}

# gather_device HOST RSH — emit the /ingest/device payload for one
# machine. REAL data: the mock_network key is never written here.
gather_device() {
    local host=$1 rsh=$2
    local links agent router
    links=$($rsh ip -br link 2>/dev/null | awk '$1!~/^(lo|veth|br-|docker|virbr)/ {print $1" "$2}') || true
    # the agent container is isle-vlan-agent (isle-agent = older name)
    agent=$($rsh docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^isle(-vlan)?-agent$' || true)
    # router VM: detectable where passwordless sudo is granted;
    # 'unknown' (not false) where it is not — never fake a fact.
    # NB grep -c prints 0 AND exits 1 — the exact 0\nunknown trap
    # isle's own join.sh fixed (their commit 8130095); test the
    # virsh call separately.
    local vout
    vout=$($rsh sudo -n virsh list --state-running 2>/dev/null) || vout=""
    if [ -z "$vout" ]; then
        router=unknown
    else
        router=$(printf '%s' "$vout" | grep -c isle-router || true)
    fi
    LINKS="$links" python3 - "$host" "${agent:-0}" "${router:-unknown}" <<'EOF'
import json, os, sys
host, agent, router = sys.argv[1], sys.argv[2].strip(), sys.argv[3].strip()
uplinks = []
for line in os.environ.get('LINKS', '').splitlines():
    parts = line.split()
    if len(parts) < 2:
        continue
    iface, state = parts[0], parts[1]
    if iface.startswith('e'):
        kind = 'ethernet'
    elif iface.startswith('w'):
        kind = 'wifi'
    else:
        continue
    uplinks.append({'interface': iface, 'kind': kind,
                    'link_up': state == 'UP'})
facts = {
    'machine_name': host,
    'agent_present': agent not in ('', '0'),
    'notes': 'pol isle sync: interfaces are CANDIDATE uplinks '
             '(kind guessed from name; isle membership not yet '
             'confirmed)',
}
if router not in ('unknown', ''):
    facts['hosts_router'] = router != '0'
    facts['router_running'] = router != '0'
print(json.dumps({'device': host, 'facts': facts,
                  'uplinks': uplinks}))
EOF
}

# fetch_first HOST FILE — cat a remote file, sudo -n first then
# plain; prints nothing when unreadable.
fetch_remote() {
    ssh -o BatchMode=yes "$1" "sudo -n cat '$2' 2>/dev/null || cat '$2' 2>/dev/null" 2>/dev/null
}

# machine_name_for_local — the polari machine name of THIS host:
# the swarm node's polari.machine label when set, else hostname.
machine_name_for_local() {
    local label
    label=$(docker node inspect "$(hostname)" --format '{{index .Spec.Labels "polari.machine"}}' 2>/dev/null) || true
    echo "${label:-$(hostname)}"
}

sync_host() {
    local host=$1 rsh
    if [ "$host" = "local" ] || [ "$host" = "$(hostname)" ]; then
        rsh=""
        host=$(machine_name_for_local)
    else
        rsh="ssh -o BatchMode=yes -o ConnectTimeout=8 $host"
        $rsh true 2>/dev/null || { log_warn "$host unreachable over SSH — skipped"; return 0; }
    fi
    log_info "sync $host: device facts"
    gather_device "$host" "$rsh" | core_api POST /api/islemesh/ingest/device >/dev/null \
        || log_warn "$host: device ingest failed (core unreachable?)"
    [ -n "$rsh" ] || return 0
    local registry
    registry=$(fetch_remote "$host" /etc/isle-mesh/agent/registry.json) || true
    if [ -n "$registry" ]; then
        log_info "sync $host: agent registry.json"
        REGISTRY="$registry" python3 -c '
import json, os, sys
print(json.dumps({"device": sys.argv[1],
                  "registry": json.loads(os.environ["REGISTRY"])}))' "$host" \
            | core_api POST /api/islemesh/ingest/registry >/dev/null \
            || log_warn "$host: registry ingest failed"
    else
        log_warn "$host: no readable agent registry.json (agent not set up, or needs sudo) — skipped"
    fi
    # fragment dir moved: the vlan-agent renders to nginx/configs
    # (observable path per its own logs); plain configs/ = older
    # layout. First dir with .conf files wins.
    local confdir confs=""
    for confdir in /etc/isle-mesh/agent/nginx/configs /etc/isle-mesh/agent/configs; do
        confs=$($rsh "sudo -n ls $confdir 2>/dev/null || ls $confdir 2>/dev/null" 2>/dev/null | grep '\.conf$' || true)
        [ -n "$confs" ] && break
    done
    if [ -n "$confs" ]; then
        log_info "sync $host: nginx fragments ($(echo "$confs" | wc -l) from $confdir)"
        local tmp; tmp=$(mktemp)
        printf '{"device": "%s", "fragments": {' "$host" > "$tmp"
        local first=1 c body
        for c in $confs; do
            body=$(fetch_remote "$host" "$confdir/$c") || continue
            [ -n "$body" ] || continue
            [ $first -eq 1 ] || printf ',' >> "$tmp"
            first=0
            BODY="$body" python3 -c 'import json,os,sys; print(json.dumps(sys.argv[1])+": "+json.dumps(os.environ["BODY"]), end="")' "$c" >> "$tmp"
        done
        printf '}}' >> "$tmp"
        core_api POST /api/islemesh/ingest/fragments < "$tmp" >/dev/null \
            || log_warn "$host: fragment ingest failed"
        rm -f "$tmp"
    else
        log_warn "$host: no agent fragments found — skipped"
    fi
}

COMMAND="${1:-help}"
case "$COMMAND" in
    help|-h|--help) show_help ;;
    status)
        core_api GET /api/islemesh | python3 -m json.tool \
            || die "no core reachable (start the node/suite or set POLARI_CORE_URL)"
        ;;
    matrix)
        core_api GET /api/islemesh/matrix | python3 -m json.tool \
            || die "no core reachable"
        ;;
    mock)
        log_info "Seeding the built-in MOCK isle network (every row flagged mock_network=true)"
        echo '{}' | core_api POST /api/islemesh/mock | python3 -m json.tool \
            || die "no core reachable"
        log_warn "The summary banner now says MOCK NETWORK — 'pol isle sync' replaces it with real data per device."
        ;;
    sync)
        shift || true
        HOSTS=${*:-"isle-core local"}
        for h in $HOSTS; do sync_host "$h"; done
        log_success "sync done — see /display/isle-mesh or 'pol isle status'"
        ;;
    retire)
        DEV=${2:?usage: pol isle retire <device>}
        printf '{"device": "%s", "retire": true}' "$DEV" \
            | core_api POST /api/islemesh/ingest/device | python3 -m json.tool \
            || die "no core reachable"
        ;;
    *)
        log_warn "'pol isle $COMMAND' — not implemented yet (arrives with its mac phase; see MESH_APP_CONVERGENCE_PLAN.md)."
        show_help
        exit 1
        ;;
esac
