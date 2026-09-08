#!/bin/bash
# jenkins.sh — `pol jenkins`: the host-tier build + publish controller
# (polari-jenkins/ sub-project; CICD_PIPELINE_PLAN.md). Loopback-only UI,
# polls GitHub, publishes only with DRY_RUN=false + a present secret.
#   pol jenkins up|down|restart|status|logs|build|secrets
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"; J="$ROOT/polari-jenkins"
cd "$J"
ensure_env(){
    [ -f .env ] || { sed "s#^POLARI_SUITE=.*#POLARI_SUITE=$ROOT#; s#^UID=.*#UID=$(id -u)#; s#^GID=.*#GID=$(id -g)#; s#^DOCKER_GID=.*#DOCKER_GID=$(getent group docker | cut -d: -f3)#" .env.example > .env; log_info "wrote polari-jenkins/.env (gitignored)"; }
    mkdir -p jenkins_home pool
    if [ ! -s secrets/admin/jenkins_admin_password ]; then
        PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24); printf '%s' "$PW" > secrets/admin/jenkins_admin_password; chmod 0600 secrets/admin/jenkins_admin_password
        log_warn "generated the local admin password → polari-jenkins/secrets/admin/jenkins_admin_password (gitignored). Shown once: $PW"
    fi
    chmod -R go-rwx secrets 2>/dev/null || true
}
compose(){ docker compose -p polari-jenkins "$@"; }
secrets_status(){
    echo "secrets present (names only — values are never printed):"
    find secrets -type f ! -name '*.example' ! -name '.gitkeep' ! -name README.md ! -name ROTATION.log | sort | sed 's#^#  present  #'
    echo "secrets missing (routes that need them refuse by name):"
    for ex in $(find secrets -name '*.example' | sort); do [ -s "${ex%.example}" ] || echo "  missing  ${ex%.example}"; done
    echo "git status of secrets/: $(git -C "$ROOT" status --porcelain polari-jenkins/secrets | grep -v '\.example\|README\|\.gitkeep' | wc -l) tracked-or-untracked real files (must be 0)"
}
case "${1:-help}" in
    up)      ensure_env; compose up -d --build; log_success "polari-jenkins up → http://127.0.0.1:$(grep ^JENKINS_PORT .env | cut -d= -f2)  (admin / secrets/admin/jenkins_admin_password)" ;;
    down)    compose down ;;
    restart) compose restart ;;
    build)   compose build ;;
    logs)    compose logs -f --tail=200 ;;
    status)  compose ps; C=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${JENKINS_PORT:-8080}/login || true); echo "UI: HTTP $C"; secrets_status ;;
    secrets) secrets_status ;;
    *)       sed -n 2,6p "$0" ;;
esac
