#!/bin/bash
# pol dev — the ISLE-ORIENTED developer workflow (handoff §25.3/§28).
# The main deployment route going forward: build polari here, push
# to the mesh registry, deploy THROUGH the isle. One namespace over
# onboarding + the build→push→deploy loop + teardown.
#
#   pol dev setup [--yes]            onboard THIS machine (registry +
#                                    isle CA trust, dev-loop shortcut)
#   pol dev deploy [backend|frontend]  build → push registry → deploy
#   pol dev teardown [--keep-data]   tear the isle deployment down
#   pol dev status                   isle deployment + registry health
#
# Config (env or ~/.config/polari/isle-dev.env, written by setup):
#   ISLE_HOST (default 192.168.0.24)  REGISTRY_HOST  REGISTRY_PORT
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/log.sh" 2>/dev/null || { CYAN=""; NC=""; }

CONF="$HOME/.config/polari/isle-dev.env"
[ -f "$CONF" ] && . "$CONF"
ISLE_HOST="${ISLE_HOST:-192.168.0.24}"
ISLE_USER="${ISLE_USER:-detts}"
REGISTRY_HOST="${REGISTRY_HOST:-192.168.0.24}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY="$REGISTRY_HOST:$REGISTRY_PORT"

show_help() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

deploy_one() {
    local img="${1:-backend}"
    echo -e "${CYAN}==> pol node build $img${NC}"
    pol node build "$img"
    echo -e "${CYAN}==> push prf-$img:staging -> $REGISTRY${NC}"
    docker tag  "prf-$img:staging" "$REGISTRY/prf-$img:staging"
    docker push "$REGISTRY/prf-$img:staging"
    echo -e "${CYAN}==> deploy on the isle ($ISLE_USER@$ISLE_HOST)${NC}"
    ssh "$ISLE_USER@$ISLE_HOST" isle-polari-deploy --pull
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
        deploy_one "${2:-backend}"
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
