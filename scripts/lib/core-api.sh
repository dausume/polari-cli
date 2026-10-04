# core-api.sh — reach the core Polari instance's API from the CLI.
#
# One transport for every script (topology.sh's be_call now rides
# this): $POLARI_CORE_URL when set, else a LOCAL backend container —
# the compose name (prf-backend) or the swarm task
# (polari-node_backend.*), whichever is running. The in-container
# server listens on :3000.

# THE THREE NAMES A POLARI BACKEND CAN HAVE, and they are three because there
# are three routes onto a machine:
#   prf-backend          compose (pol suite up / pol node up)
#   polari-node_backend  a swarm task (pol swarm deploy node)
#   prf-isle-backend     THE ISLE ROUTE — Isle-Mesh/polari-isle/docker-compose.yml
#                        names it that, and `isle core-install` is how most
#                        people will ever get a Polari.
#
# ci-3, found by building the isle test (2026-09-20): the third was missing, so
# `pol modules selftest <m>` on a machine installed from polari-complete died
# with "no local backend container … pol suite up / pol node up" — advice that
# is wrong there, because an isle is neither. It was never noticed because
# nothing had ever run the CLI on an isle box. The pipeline's own in-guest
# runner (polari-jenkins/isle/guest-selftests.sh) still cannot use this — `pol`
# is not installed by polari-complete at all — but a PERSON on an isle can now.
core_backend_container() {
    docker ps --format '{{.Names}}' | grep -x prf-backend && return 0
    docker ps --format '{{.Names}}' | grep -x prf-isle-backend && return 0
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
    local envline assignedline
    { IFS= read -r envline; IFS= read -r assignedline; } < <(echo "$resp" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if d.get('ok'):
    print(d['env'])
    print(','.join(d.get('assigned') or []))
    for mod, why in sorted((d.get('addedByRequires') or {}).items()):
        print(f'  + {mod} (required by {\", \".join(why)})',
              file=sys.stderr)
else:
    print('REFUSED: ' + str(d.get('refusal') or d), file=sys.stderr)
    sys.exit(2)") || {
        die "topology rows refuse to yield a modules env for '$inst' — assign modules first (pol topology assign <module> $inst) or set POLARI_MODULES explicitly (a warned override)."
    }
    export POLARI_MODULES="$(checkout_closure_union "$envline" "$assignedline")"
    log_info "POLARI_MODULES derived from topology rows ($inst): $POLARI_MODULES"
}

# checkout_closure_union BACKEND_ENV_CSV ASSIGNED_CSV — topo-closure-1: the
# RUNNING backend computes its requires-closure from the manifests baked into
# its OWN (possibly old) image, so a module assigned on a newer checkout but
# absent from that image contributes no requires at all (found live:
# `pol topology modules-env prf-a` missed `grpcbridge`, required by
# `hwnocode`, because the deployed image predated both). This recomputes the
# SAME closure from the checkout currently on disk (modules/polari-modules.json
# + each module's own polari-app.json requires.modules) and unions it with the
# backend's answer, printing a WARN naming every module the checkout adds that
# the running image did not already know about. Prints the final, unioned
# POLARI_MODULES csv on stdout; never fails the caller — a broken/absent
# checkout just contributes nothing and the backend's own env is kept as-is.
checkout_closure_union() {
    local backend_env=$1 assigned=$2
    local modules_dir="$POL_RF_NODE/polari-framework/modules"
    local helper="$SCRIPT_DIR/lib/checkout_module_closure.py"
    [ -f "$helper" ] && [ -d "$modules_dir" ] || { echo "$backend_env"; return 0; }
    local out
    out=$(python3 "$helper" "$modules_dir" "$assigned" "$backend_env" 2>/dev/null) || { echo "$backend_env"; return 0; }
    # NOTE: this function's stdout becomes POLARI_MODULES at the call site
    # ($(...)) — it must print EXACTLY the final csv and nothing else.
    # added_by_checkout is read here, in THIS shell, and WARNed through the
    # real log_warn >&2 (never through this function's own stdout).
    local finalcsv added_json mod chain
    finalcsv=$(python3 -c "
import json, sys
raw, fallback = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    d = {}
full = d.get('full') or [m for m in fallback.split(',') if m]
print(','.join(sorted(full)))
" "$out" "$backend_env")
    added_json=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
for mod, chain in sorted((d.get('added_by_checkout') or {}).items()):
    print('%s\t%s' % (mod, ', '.join(chain)))
" "$out")
    if [ -n "$added_json" ]; then
        while IFS=$'\t' read -r mod chain; do
            [ -n "$mod" ] && log_warn "closure from the checkout: +$mod (required by $chain; not in the running image)" >&2
        done <<< "$added_json"
    fi
    echo "$finalcsv"
}
