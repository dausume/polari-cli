#!/bin/bash
# pol suite — lifecycle of the COMBINED suite stack (pol-* infra + prf +
# psc behind pol-proxy). Wraps the suite-root compose files; self-heals
# missing generated config by running the setup chain first.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol suite — combined prf+psc stack"
    echo -e "
${BOLD}COMMANDS${NC}   (all take ${CYAN}--env dev|staging|prod${NC}, default staging)
  ${CYAN}up${NC}        ensure setup (credentials + .generated), then compose up -d
  ${CYAN}down${NC}      compose down
  ${CYAN}build${NC}     compose build [services...]
  ${CYAN}ps${NC}        compose ps
  ${CYAN}logs${NC}      compose logs -f [service]
  ${CYAN}urls${NC}      print the stack's URLs (staging)

${BOLD}NOTES${NC}
  staging GOTCHA: prf-backend's healthcheck start_period is shorter than a
  cold seed — if pol-proxy stays blocked on first 'up', re-run 'pol suite
  up' once prf-backend is healthy (see NEXT_AGENT_HANDOFF.md §1).
"
}

ENV_MODE="staging"
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --env) ENV_MODE="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"
COMMAND=$1; shift || true

compose_cmd() {
    case "$ENV_MODE" in
        dev)     echo "docker compose -f docker-compose.yml" ;;
        staging) echo "docker compose -f docker-compose.staging-nip.yml --env-file .generated/.env.staging" ;;
        prod)    echo "docker compose -f docker-compose.prod.yml --env-file .generated/.env.prod" ;;
        *)       die "unknown --env '$ENV_MODE' (dev|staging|prod)" ;;
    esac
}

ensure_staging_setup() {
    export LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
    if [ ! -f "$POL_SUITE_ROOT/.generated/.env.staging" ]; then
        log_info "No .generated/.env.staging — running nip-staging-setup.sh $LOCAL_IP"
        bash "$POL_SUITE_ROOT/nip-staging-setup.sh" "$LOCAL_IP"
    fi
}

cd "$POL_SUITE_ROOT"
case "$COMMAND" in
    up)
        [ "$ENV_MODE" = "staging" ] && ensure_staging_setup
        [ "$ENV_MODE" = "dev" ] && [ ! -f .env ] && { log_info "No suite .env — running security setup"; bash setup-polari-security.sh dev --env-only --skip-subs; }
        export LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
        $(compose_cmd) up -d "$@"
        log_success "suite up ($ENV_MODE). 'pol suite ps' to check health." ;;
    down)  export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) down "$@" ;;
    build) export LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"; $(compose_cmd) build "$@" ;;
    ps)    export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) ps "$@" ;;
    logs)  export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) logs -f "$@" ;;
    urls)
        IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
        echo "  https://prf.$IP.nip.io      https://api.prf.$IP.nip.io"
        echo "  https://psc.$IP.nip.io      https://api.psc.$IP.nip.io"
        echo "  https://auth.$IP.nip.io     https://files.$IP.nip.io" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown suite command: $COMMAND"; show_help; exit 1 ;;
esac
