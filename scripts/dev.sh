#!/bin/bash
# pol dev — the ISLE-ORIENTED developer workflow (handoff §25.3/§28).
# The main deployment route going forward: build polari here, push
# to the mesh registry, deploy THROUGH the isle. One namespace over
# onboarding + the build→push→deploy loop + teardown.
#
#   pol dev setup [--yes]            onboard THIS machine (registry +
#                                    isle CA trust, dev-loop shortcut)
#   pol dev deploy [backend|frontend]  build → push registry → deploy
#   pol dev deploy <worker>          board-engines | formal-engines | esp-engines
#                                    | pcb-engines | bridge-engines | msci-engines
#                                    | cad-engines: build its image (compose build
#                                    in polari-rf-node), tag + push it to the mesh
#                                    registry under its own tag, then on the isle
#                                    core `sudo isle store install <name> --yes`
#                                    (needs the core polari up — isle-polari-deploy
#                                    provides it, so deploy backend first).
#                                    bridge-engines builds ON the isle host
#                                    (prf-bridge-engines/build.sh), no push.
#   pol dev deploy all               backend, frontend, then every worker
#   --dry-run (anywhere in the args) print each command instead of running it
#   pol dev teardown [--keep-data]   tear the isle deployment down
#   pol dev status                   isle deployment + registry health
#
# Config (env or ~/.config/polari/isle-dev.env, written by setup):
#   ISLE_HOST (default: the `ssh` target of node isle-core in
#   pol-build/manifests/nodes.yml, else the ssh alias `isle-core`)
#   ISLE_USER  REGISTRY_HOST (default registry.isle)  REGISTRY_PORT (5000)
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || { CYAN=""; NC=""; }

CONF="$HOME/.config/polari/isle-dev.env"
[ -f "$CONF" ] && . "$CONF"
_nodes_field() {  # _nodes_field <field> -> nodes.yml value for node isle-core ("" if absent/unreadable)
    python3 - "$SUITE_ROOT/pol-build/manifests/nodes.yml" "$1" 2>/dev/null <<'PYEOF' || true
import sys, yaml
n = (yaml.safe_load(open(sys.argv[1])).get("nodes") or {}).get("isle-core") or {}
print(n.get(sys.argv[2], ""))
PYEOF
}
ISLE_HOST="${ISLE_HOST:-$(_nodes_field ssh)}"
ISLE_HOST="${ISLE_HOST:-isle-core}"
ISLE_USER="${ISLE_USER:-$(_nodes_field user)}"
ISLE_USER="${ISLE_USER:-detts}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.isle}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY="$REGISTRY_HOST:$REGISTRY_PORT"

DRY=0
_args=()
for _a in "$@"; do [ "$_a" = "--dry-run" ] && DRY=1 || _args+=("$_a"); done
set -- "${_args[@]}"
run() { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }

WORKERS="board-engines formal-engines esp-engines pcb-engines bridge-engines msci-engines cad-engines"
_worker_image() {  # name -> image:tag (the compose file's own tag)
    case "$1" in
        board-engines)  echo prf-board-engines:trixie ;;
        formal-engines) echo prf-formal-engines:trixie ;;
        esp-engines)    echo prf-esp-engines:noble ;;
        pcb-engines)    echo prf-pcb-engines:trixie ;;
        bridge-engines) echo prf-bridge-engines:trixie ;;
        msci-engines)   echo prf-msci-engines:staging ;;
        cad-engines)    echo prf-cad-engines:staging ;;
    esac
}

show_help() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

deploy_one() {
    local img="${1:-backend}"
    echo -e "${CYAN}==> pol node build $img${NC}"
    run pol node build "$img"
    echo -e "${CYAN}==> push prf-$img:staging -> $REGISTRY${NC}"
    run docker tag  "prf-$img:staging" "$REGISTRY/prf-$img:staging"
    run docker push "$REGISTRY/prf-$img:staging"
    echo -e "${CYAN}==> deploy on the isle ($ISLE_USER@$ISLE_HOST)${NC}"
    run ssh "$ISLE_USER@$ISLE_HOST" isle-polari-deploy --pull
}

deploy_worker() {
    local name="$1" image; image="$(_worker_image "$name")"
    if [ "$name" = bridge-engines ]; then
        echo -e "${CYAN}==> build $image ON the isle host (prf-bridge-engines/build.sh)${NC}"
        BRIDGE_BUILD_HOST="$ISLE_HOST" run bash "$SUITE_ROOT/polari-rf-node/prf-bridge-engines/build.sh"
    else
        echo -e "${CYAN}==> build $image (compose -p $name)${NC}"
        run docker compose -p "$name" -f "$SUITE_ROOT/polari-rf-node/docker-compose.$name.yml" \
            --project-directory "$SUITE_ROOT/polari-rf-node" build
        echo -e "${CYAN}==> push $image -> $REGISTRY${NC}"
        run docker tag  "$image" "$REGISTRY/$image"
        run docker push "$REGISTRY/$image"
    fi
    echo -e "${CYAN}==> isle store install $name ($ISLE_USER@$ISLE_HOST)${NC}"
    run ssh "$ISLE_USER@$ISLE_HOST" sudo isle store install "$name" --yes
}

deploy_target() {
    case "$1" in
        backend|frontend) deploy_one "$1" ;;
        all) deploy_one backend; deploy_one frontend
             for w in $WORKERS; do deploy_worker "$w"; done ;;
        *) if [ -n "$(_worker_image "$1")" ]; then deploy_worker "$1"
           else echo "unknown deploy target: $1" >&2
                echo "valid: backend frontend all $WORKERS" >&2; exit 1; fi ;;
    esac
}

case "${1:-help}" in
    help|-h|--help) show_help ;;

    setup)
        shift || true
        # persist config for later `pol dev` calls
        mkdir -p "$(dirname "$CONF")"
        cat > "$CONF" <<EOF
ISLE_HOST=$ISLE_HOST
ISLE_USER=$ISLE_USER
REGISTRY_HOST=$REGISTRY_HOST
REGISTRY_PORT=$REGISTRY_PORT
EOF
        exec bash "$SUITE_ROOT/polari-cli/shells/isle-dev-setup.sh" \
            --isle-host "$ISLE_HOST" \
            --registry-host "$REGISTRY_HOST" \
            --registry-port "$REGISTRY_PORT" "$@"
        ;;

    deploy)
        deploy_target "${2:-backend}"
        ;;

    teardown)
        shift || true
        ssh "$ISLE_USER@$ISLE_HOST" isle-polari-teardown "$@"
        ;;

    status)
        echo "isle host:  $ISLE_USER@$ISLE_HOST"
        echo "registry:   $REGISTRY"
        echo "--- registry catalog ---"
        curl -sk "https://$REGISTRY/v2/_catalog" 2>/dev/null | python3 -m json.tool 2>/dev/null \
            || echo "  (registry unreachable / not trusted — pol dev setup)"
        echo "--- prf-isle health (via the isle) ---"
        ssh -o ConnectTimeout=6 "$ISLE_USER@$ISLE_HOST" \
            'curl -sk -o /dev/null -w "polari.isle -> %{http_code}\n" --resolve polari.isle:443:127.0.0.1 https://polari.isle/ 2>/dev/null' \
            2>/dev/null || echo "  (isle host unreachable)"
        ;;

    *)
        echo "unknown: pol dev $1"; show_help; exit 1 ;;
esac
