#!/bin/bash
# project.sh — `pol project`: work on ONE Polari module/app as its own
# project (its own repo, opened alone in VS Code / VSCodium) and build /
# test / run / deploy / update / remove it from the terminal — the
# "Polari Developer" loop (his ask 2026-09-09). Nothing here needs the
# suite checkout: every tool runs inside the Polari backend IMAGE with the
# project directory mounted, and deploys talk to a Polari instance's API.
#
#   pol project init [<id>] [--kind polari-app|library|isle-app|hardware-app]   make this dir a module project (scaffold + .vscode + .polari)
#   pol project lint            conform: the standard's checks (report, never a gate)
#   pol project test            run the project's *_selftest.py inside the image
#   pol project up|down|logs|status   a LOCAL lean Polari with this module mounted + admitted (http://127.0.0.1:${PORT})
#   pol project build [--offline]     the module deb into ./dist (online or offline flavor)
#   pol project deploy [--api URL] [--ref REF]   admit onto an instance: local (mounted) or remote (fetch-admit from the project's git remote)
#   pol project update [--api URL]    re-fetch + re-admit (same as deploy, said plainly)
#   pol project remove [--api URL]    put-away on the instance
#   pol project open            open the project in codium/code
# Config: .polari/project.json {id, image, api, port}; env POLARI_API / POLARI_IMAGE override.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
VERB="${1:-help}"; shift || true
DIR="${POL_CWD:-$(pwd)}"   # the caller's directory (the pol launcher runs scripts from the suite root)
CFG="$DIR/.polari/project.json"
cfg(){ [ -f "$CFG" ] && python3 -c "import json,sys; print(json.load(open('$CFG')).get('$1',''))" 2>/dev/null || true; }
ID="$(cfg id)"; [ -n "$ID" ] || ID="$(python3 -c "import json; print(json.load(open('$DIR/polari-app.json'))['id'])" 2>/dev/null || true)"
[ -n "$ID" ] || [ "$VERB" = init ] || [ "$VERB" = help ] || die "not a module project: no .polari/project.json or polari-app.json in $DIR (pol project init <id>)"
[ -n "$ID" ] || ID="$(basename "$DIR")"
IMAGE="${POLARI_IMAGE:-$(cfg image)}"; [ -n "$IMAGE" ] || IMAGE="prf-backend:staging"
API="${POLARI_API:-$(cfg api)}"; PORT="$(cfg port)"; [ -n "$PORT" ] || PORT=3300
LOCAL_API="http://127.0.0.1:$PORT"; [ -n "$API" ] || API="$LOCAL_API"
CTR="pol-project-$ID"
REF=""; KIND="polari-app"; OFFLINE=0
while [ $# -gt 0 ]; do case "$1" in --api) API="$2"; shift 2 ;; --ref) REF="$2"; shift 2 ;; --kind) KIND="$2"; shift 2 ;; --offline) OFFLINE=1; shift ;; *) POS="${POS:-} $1"; shift ;; esac; done
# POLARI_TOOLS_DIR (developers of the tools themselves): mount a host polari-framework's moduleService over the image's
TOOLS_MOUNT=(); [ -n "${POLARI_TOOLS_DIR:-}" ] && TOOLS_MOUNT=(-v "$POLARI_TOOLS_DIR/moduleService:/app/moduleService:ro" -v "$POLARI_TOOLS_DIR/polariApiServer:/app/polariApiServer:ro")
in_image(){ # run a python module inside the backend image with the project mounted AS modules/<id>
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e PYTHONPATH=/app:/app/modules "${TOOLS_MOUNT[@]}" -v "$DIR:/app/modules/$ID" -w /app "$@" ; }
requires(){ python3 -c "import json; m=json.load(open('$DIR/polari-app.json')); print(','.join(m.get('requires',{}).get('modules',[])))" 2>/dev/null || true; }
curl_api(){ curl -sk --max-time 120 "$@"; }
case "$VERB" in
    init)
        NEW="$(echo ${POS:-} | awk '{print $1}')"
        if [ -n "$NEW" ]; then mkdir -p "$DIR/$NEW"; DIR="$DIR/$NEW"; ID="$NEW"; fi
        [ -f "$DIR/polari-app.json" ] && die "$DIR is already a module project ($ID)"
        rmdir "$DIR" 2>/dev/null || true    # the scaffold creates it (and refuses an existing one)
        log_info "scaffolding module '$ID' (kind $KIND) with the image's scaffold → $DIR"
        docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e PYTHONPATH=/app:/app/modules "${TOOLS_MOUNT[@]}" -v "$(dirname "$DIR"):/out" -w /app "$IMAGE" \
            python3 -m moduleService.scaffold new "$ID" --kind "$KIND" --root /out >/dev/null || die "scaffold failed (is the image current? pol node build backend)"
        mkdir -p "$DIR/.polari" "$DIR/.vscode"
        printf '{\n  "id": "%s",\n  "image": "%s",\n  "api": "",\n  "port": %s,\n  "note": "pol project reads this; POLARI_API / POLARI_IMAGE override"\n}\n' "$ID" "$IMAGE" "$PORT" > "$DIR/.polari/project.json"
        cat > "$DIR/.vscode/extensions.json" <<'J'
{ "recommendations": ["ms-python.python", "ms-pyright.pyright", "charliermarsh.ruff", "redhat.vscode-yaml", "bierner.markdown-mermaid"],
  "_note": "ids as published on Open VSX (VSCodium / code-server); the same ids exist on the VS Code Marketplace" }
J
        cat > "$DIR/.vscode/settings.json" <<'J'
{ "python.analysis.extraPaths": ["${workspaceFolder}/..", "${workspaceFolder}"],
  "python.analysis.typeCheckingMode": "basic",
  "files.exclude": {"**/__pycache__": true},
  "_note": "the framework itself lives in the Polari image; pol project test/lint run there" }
J
        cat > "$DIR/.vscode/tasks.json" <<'J'
{ "version": "2.0.0", "tasks": [
  {"label": "pol project lint", "type": "shell", "command": "pol project lint", "problemMatcher": []},
  {"label": "pol project test", "type": "shell", "command": "pol project test", "group": "test", "problemMatcher": []},
  {"label": "pol project up",   "type": "shell", "command": "pol project up",   "problemMatcher": []},
  {"label": "pol project deploy", "type": "shell", "command": "pol project deploy", "problemMatcher": []} ] }
J
        printf '__pycache__/\n*.pyc\ndist/\n.polari/local-*.json\n' > "$DIR/.gitignore"
        [ -d "$DIR/.git" ] || git -C "$DIR" init -q
        log_success "module project ready: $DIR  →  pol project lint | test | up | deploy" ;;
    lint)
        in_image "$IMAGE" python3 -m moduleService.manifests conform "$ID" ;;
    test)
        n=0; for st in "$DIR"/*_selftest.py; do [ -f "$st" ] || continue; n=$((n+1)); m="$ID.$(basename "$st" .py)"; log_info "python3 -m $m"; in_image "$IMAGE" python3 -m "$m" || true; done
        [ "$n" -gt 0 ] || die "no *_selftest.py in $DIR (the standard requires one)" ;;
    up)
        MODS="$ID"; R="$(requires)"; [ -n "$R" ] && MODS="$MODS,$R"
        docker rm -f "$CTR" >/dev/null 2>&1 || true
        docker run -d --name "$CTR" -u "$(id -u):$(id -g)" -e HOME=/tmp -e DATABASE_PATH=/tmp/$ID.db -e POLARI_LAZY_BOOT=off -e POLARI_MESH_AUTOCONFIG=false \
            -e "POLARI_MODULES=$MODS" "${TOOLS_MOUNT[@]}" -v "$DIR:/app/modules/$ID" -w /app -p "127.0.0.1:$PORT:3000" --entrypoint python3 "$IMAGE" initLocalhostPolariServer.py >/dev/null
        log_info "booting $CTR (modules: $MODS) …"; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$LOCAL_API/api/health")" = 200 ] && break; sleep 3; done
        curl -s -o /dev/null -w '%{http_code}' "$LOCAL_API/api/health" | grep -q 200 && log_success "up: $LOCAL_API  (module $ID mounted; pol project deploy admits it)" || { docker logs "$CTR" 2>&1 | tail -5; die "did not come up"; } ;;
    down) docker rm -f "$CTR" >/dev/null 2>&1 && log_success "$CTR removed" || log_warn "not running" ;;
    logs) docker logs -f --tail=100 "$CTR" ;;
    status)
        printf 'project %s  image %s  api %s\n' "$ID" "$IMAGE" "$API"
        docker ps --format '{{.Names}} {{.Status}}' | grep "^$CTR" || echo "local instance: not running"
        curl_api "$API/modules/$ID" | python3 -c "import json,sys; d=json.load(sys.stdin); print('on instance:', {k: d.get(k) for k in ('module','downloaded','enabled','active','status','error') if k in d} or d)" 2>/dev/null || echo "instance $API not answering" ;;
    build)
        mkdir -p "$DIR/dist"; FLAVOR=$([ "$OFFLINE" = 1 ] && echo offline || echo online)
        # the image's registry is read-only for the host uid: build against a writable COPY (dist/.registry.json)
        REG="$DIR/dist/.registry.json"
        docker run --rm "$IMAGE" cat /app/modules/polari-modules.json > "$REG" 2>/dev/null || echo '{"modules": []}' > "$REG"
        docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e PYTHONPATH=/app:/app/modules "${TOOLS_MOUNT[@]}" -v "$DIR:/app/modules/$ID" -v "$REG:/app/modules/polari-modules.json" -v "$DIR/dist:/out" -e POLARI_APP_DEBS_DIR=/out -w /app "$IMAGE" sh -c "
python3 - <<'PY'
from moduleService.module_registry import register_module
try: register_module('$ID', 'self', '$ID (pol project)', 'modules/$ID')
except Exception as e: print('registry:', e)
from appstore.custom.app_deb_builder import generate, analyze
r = generate('$ID', analysis=analyze(), flavor='$FLAVOR')   # the pool IS ./dist (POLARI_APP_DEBS_DIR)
print(r if not r.get('ok') else 'built dist/pool/' + r['file'] + ' (%d B)' % r['bytes'])
PY" && ls -la "$DIR/dist/pool"/*.deb 2>/dev/null | awk '{print "  " $9 " " $5 " B"}' ;;
    deploy|update)
        if [ "$API" = "$LOCAL_API" ]; then
            log_info "local instance: POST /modules/$ID/admit (the project is mounted)"
            curl_api -X POST -H 'Content-Type: application/json' -d '{}' "$API/modules/$ID/admit" | python3 -c "import json,sys; d=json.load(sys.stdin); print(('[ OK ] ' if d.get('ok', True) and not d.get('error') else '[FAIL] ') + json.dumps(d)[:300])"
        else
            REMOTE="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"; [ -n "$REMOTE" ] || die "no git remote 'origin' — a remote instance fetches the project from its repository (git push it first)"
            R="$REF"; [ -n "$R" ] || R="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
            log_info "remote instance $API: POST /modules/$ID/fetch-admit from $REMOTE@$R (installDeps on)"
            curl_api -X POST -H 'Content-Type: application/json' -d "{\"sourceRef\": \"$REMOTE\", \"sourceKind\": \"git\", \"ref\": \"$R\", \"installDeps\": true}" "$API/modules/$ID/fetch-admit" | python3 -c "import json,sys; d=json.load(sys.stdin); print(('[ OK ] ' if d.get('ok', True) and not d.get('error') else '[FAIL] ') + json.dumps(d)[:400])"
        fi ;;
    remove)
        curl_api -X POST -H 'Content-Type: application/json' -d '{}' "$API/modules/$ID/put-away" | python3 -c "import json,sys; d=json.load(sys.stdin); print(('[ OK ] ' if d.get('ok', True) and not d.get('error') else '[FAIL] ') + json.dumps(d)[:300])" ;;
    open) command -v codium >/dev/null && codium "$DIR" || command -v code >/dev/null && code "$DIR" || die "neither codium nor code on PATH" ;;
    *) sed -n 2,20p "$0" ;;
esac
