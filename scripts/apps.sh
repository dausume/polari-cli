#!/usr/bin/env bash
# pol apps — Polari-Apps (tt-12): configurations of modules for a
# particular capability or use-case (a wax 3D-printing shop, a lean
# judicial app, a DMV policy-analysis build). Deployment is PLANNED,
# exportable as a credential-free JSON package, and applied later by
# pointing this CLI at the file — never on the spot. Apply writes
# ModuleAssignment rows only; deploying containers stays
# `pol topology apply` (human-invoked), exactly like topology
# packages.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

usage() {
    pol_box "pol apps — use-case module configurations (Polari-Apps)"
    echo -e "
  ${CYAN}list${NC}                  the apps this core knows
  ${CYAN}plan <app> [topo]${NC}     where each module stands on the topology
                        (already-placed / needs-assignment / missing)
  ${CYAN}export <app> [file]${NC}   write the portable polari-app-package JSON
                        (stdout when no file given)
  ${CYAN}deploy <file|app> [--plan]${NC}
                        apply an exported package (or a known app) to
                        the active topology: upserts the definition,
                        writes ModuleAssignment rows, re-resolves.
                        --plan prints the plan and touches NOTHING.
  ${CYAN}shell <app> [--output <dir>]${NC}
                        sep-3: make an isle app from ANY Polari app —
                        creates/reuses the scope=app AppShellDefinition,
                        fetches the canonical registration, and builds
                        the launcher .deb (materialized NOW, at install
                        time — never a shelf of artifacts).

Backend is reached via \$POLARI_CORE_URL when set, else docker exec
into the local prf-backend. Container deploys stay human-invoked
(pol topology apply)."
}

# be_call METHOD PATH — body on stdin for POST; response on stdout.
be_call() {
    local method=$1 path=$2
    if [ -n "${POLARI_CORE_URL:-}" ]; then
        if [ "$method" = "POST" ]; then
            curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- "$POLARI_CORE_URL$path"
        else
            curl -sk "$POLARI_CORE_URL$path"
        fi
    else
        docker ps --format '{{.Names}}' | grep -qx prf-backend \
            || die "no prf-backend container and POLARI_CORE_URL unset — start the suite (pol suite up) or point POLARI_CORE_URL at the core"
        docker exec -i prf-backend python3 -c "
import sys, urllib.request
method, path = sys.argv[1], sys.argv[2]
data = sys.stdin.buffer.read() if method == 'POST' else None
req = urllib.request.Request('http://localhost:3000' + path,
                             data=data, method=method,
                             headers={'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(req, timeout=120) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
" "$method" "$path"
    fi
}

pretty() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# Service-account bearer for authoring endpoints (same machine path
# as pol shell publish; a browser user does this from the store page).
bearer() {
    local kc_env="$POL_SUITE_ROOT/polari-rf-node/prf-keycloak/prf-keycloak-admin.env"
    [ -f "$kc_env" ] || die "no $kc_env — run pol security setup / staging-setup first"
    local secret kc_host api_base
    api_base="${POLARI_CORE_URL:-https://api.prf.$(lan_ip).nip.io}"
    secret=$(grep '^KEYCLOAK_POLARI_BACKEND_CLIENT_SECRET' "$kc_env" | cut -d= -f2)
    kc_host="${api_base/api.prf./auth.prf.}"
    kc_host="${kc_host/api./auth.}"
    curl -sk -X POST "$kc_host/realms/Polari/protocol/openid-connect/token" \
        -d "grant_type=client_credentials&client_id=polari-backend&client_secret=$secret" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("access_token") or exit("no token: " + json.dumps(d)))'
}

CMD=${1:-help}; shift || true
case "$CMD" in
    list)
        be_call GET /api/apps | pretty "
[print(f\"{a['name']:24} {a['title']:32} modules: {', '.join(a['modules'])}\")
 for a in d.get('apps', [])] or print(d.get('error', 'no apps'))" ;;
    plan)
        APP=${1:-}; [ -n "$APP" ] || die "usage: pol apps plan <app> [topology]"
        TOPO=${2:-}
        QS="name=$APP"; [ -n "$TOPO" ] && QS="$QS&topology=$TOPO"
        be_call GET "/api/apps/plan?$QS" | pretty "
import sys
if not d.get('ok'): sys.exit(print(d.get('error')))
print(f\"{d['title']} on topology '{d['topology']}' — readiness {round(d['readiness']*100)}%\")
print(f\"  use case: {d['useCase']}\")
[print(f\"  [{p['status']:16}] {p['module']:20} \"
       + (', '.join(p['instances']) or p['suggestedCommand']))
 for p in d['placements']]
print(f\"  note: {d['note']}\")" ;;
    export)
        APP=${1:-}; [ -n "$APP" ] || die "usage: pol apps export <app> [file]"
        OUT=${2:-}
        DOC=$(be_call GET "/api/apps/export?name=$APP")
        echo "$DOC" | pretty "
import sys
sys.exit(0) if d.get('ok') else sys.exit(print(d.get('error')) or 1)"
        if [ -n "$OUT" ]; then
            echo "$DOC" | pretty "print(json.dumps(d['document'], indent=2))" > "$OUT"
            log_success "wrote $OUT (polari-app-package — deploy anywhere via 'pol apps deploy $OUT')"
        else
            echo "$DOC" | pretty "print(json.dumps(d['document'], indent=2))"
        fi ;;
    deploy)
        TARGET=${1:-}; [ -n "$TARGET" ] || die "usage: pol apps deploy <file.json|app-name> [--plan]"
        PLAN_ONLY=0; [ "${2:-}" = "--plan" ] && PLAN_ONLY=1
        if [ -f "$TARGET" ]; then
            BODY=$(python3 - "$TARGET" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
print(json.dumps({'document': doc, 'confirm': True}))
PYEOF
)
            APPNAME=$(python3 -c "import json,sys; print(json.load(open('$TARGET'))['app']['name'])")
        else
            BODY="{\"name\": \"$TARGET\", \"confirm\": true}"
            APPNAME=$TARGET
        fi
        if [ "$PLAN_ONLY" = 1 ]; then
            "$0" plan "$APPNAME"
            log_info "--plan: nothing written"
            exit 0
        fi
        echo "$BODY" | be_call POST /api/apps/apply | pretty "
import sys
if not d.get('ok'): sys.exit(print(d.get('error')) or 1)
print(f\"applied '{d['app']}' to topology '{d['topology']}'\")
[print(f\"  + {c['module']} -> {c['instance']}\") for c in d['created']]
[print(f\"  = {s['module']}: {s['reason']}\") for s in d['skipped']]
print(f\"  next (human-run): {d['suggestedCommand']}\")" ;;
    shell)
        # sep-3: the ONE command — app row -> AppShellDefinition
        # (scope=app) -> canonical registration -> launcher .deb.
        APP=${1:-}; [ -n "$APP" ] || die "usage: pol apps shell <app> [--output <dir>]"
        shift || true
        OUT=""
        while [ $# -gt 0 ]; do case "$1" in
            --output) OUT="$2"; shift 2 ;;
            *) die "unknown arg: $1" ;;
        esac; done
        API_BASE="${POLARI_CORE_URL:-https://api.prf.$(lan_ip).nip.io}"
        BUILDER="$POL_SUITE_ROOT/polari-app-shell/shells/build-launcher-deb.sh"
        [ -f "$BUILDER" ] || die "no $BUILDER — is polari-app-shell checked out?"
        TOK=$(bearer)
        CONV=$(curl -sk -X POST "$API_BASE/api/appstore/shell-from-app" \
            -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
            -d "{\"appName\": \"$APP\"}")
        echo "$CONV" | pretty "
import sys
if not d.get('ok'): sys.exit(print(d.get('error', d)) or 1)
print(('created' if d['created'] else 'reusing')
      + f\" shell row '{d['shell']}' (scope=app, startRoute \"
      + repr(d['startRoute'] or '/app/' + d['appName']) + ')')"
        SHELL_NAME=$(echo "$CONV" | pretty "print(d['shell'])")
        REG=$(mktemp --suffix=.json)
        trap 'rm -f "$REG"' EXIT
        curl -sk "$API_BASE/api/appstore/$SHELL_NAME/registration?download=1" -o "$REG"
        python3 - "$REG" <<'PYEOF' || die "registration fetch failed (not a v1 document)"
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc.get('kind') == 'polari-shell-registration', doc
PYEOF
        DEB_OUT="${OUT:-$POL_SUITE_ROOT/polari-app-shell/dist}"
        STAGE_DIR=$(mktemp -d)
        POLARI_SHELL_BUILD="$STAGE_DIR" bash "$BUILDER" \
            --registration "$REG" --kind polari --output "$DEB_OUT"
        rm -rf "$STAGE_DIR"
        log_info "the deb materialized NOW (decision 7) — install with the printed apt line" ;;
    help|*) usage ;;
esac
