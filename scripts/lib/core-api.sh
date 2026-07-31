# core-api.sh — reach the core Polari instance's API from the CLI.
#
# One transport for every script (topology.sh's be_call now rides
# this): $POLARI_CORE_URL when set, else a LOCAL backend container —
# the compose name (prf-backend) or the swarm task
# (polari-node_backend.*), whichever is running. The in-container
# server listens on :3000.

core_backend_container() {
    docker ps --format '{{.Names}}' | grep -x prf-backend && return 0
    docker ps --format '{{.Names}}' | grep '^polari-node_backend' | head -1
}

# core_api METHOD PATH — body on stdin for POST; response on stdout.
# Returns 1 (silently) when no core is reachable — callers decide
# whether that refuses or falls back.
core_api() {
    local method=$1 path=$2
    if [ -n "${POLARI_CORE_URL:-}" ]; then
        if [ "$method" = "POST" ]; then
            curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- "$POLARI_CORE_URL$path"
        else
            curl -sk "$POLARI_CORE_URL$path"
        fi
        return
    fi
    local container
    container=$(core_backend_container) || true
    [ -n "$container" ] || return 1
    docker exec -i "$container" python3 -c "
import sys, urllib.request
method, path = sys.argv[1], sys.argv[2]
data = sys.stdin.buffer.read() if method == 'POST' else None
req = urllib.request.Request('http://localhost:3000' + path,
                             data=data, method=method,
                             headers={'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
" "$method" "$path"
}

# resolve_polari_modules INSTANCE — mod-env-3: POLARI_MODULES comes
# from topology ModuleAssignment ROWS. A hand-set env var still wins
# but is loudly named an OVERRIDE; unset, the core derives the env
# (requires-closure included). No rows / no core = an honest die
# naming every knob — never a silent monolithic boot on staging.
resolve_polari_modules() {
    local inst=${1:-prf-a}
    if [ -n "${POLARI_MODULES:-}" ]; then
        log_warn "POLARI_MODULES is set in the environment — OVERRIDING the topology rows for '$inst'. Rows are the truth; unset it to derive (pol topology modules-env $inst)."
        return 0
    fi
    local resp
    resp=$(core_api GET "/api/topology/modules-env/$inst") || {
        die "POLARI_MODULES unset and no core reachable to derive it from ModuleAssignment rows — start the core, set POLARI_CORE_URL, or (bootstrap only) set POLARI_MODULES explicitly."
    }
    local parsed
    parsed=$(echo "$resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if d.get('ok'):
    print(d['env'])
    for mod, why in sorted((d.get('addedByRequires') or {}).items()):
        print(f'  + {mod} (required by {\", \".join(why)})',
              file=sys.stderr)
else:
    print('REFUSED: ' + str(d.get('refusal') or d), file=sys.stderr)
    sys.exit(2)") || {
        die "topology rows refuse to yield a modules env for '$inst' — assign modules first (pol topology assign <module> $inst) or set POLARI_MODULES explicitly (a warned override)."
    }
    export POLARI_MODULES="$parsed"
    log_info "POLARI_MODULES derived from topology rows ($inst): $POLARI_MODULES"
}
