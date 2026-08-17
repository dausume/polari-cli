#!/bin/bash
# pol node — lifecycle of the STANDALONE PRF node stack (polari-rf-node),
# including the twin/dask/msci-engines companion stacks.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/state.sh"

show_help() {
    pol_box "pol node — standalone PRF node stack"
    echo -e "
${BOLD}COMMANDS${NC}   (all take ${CYAN}--env dev|test|staging|prod|stateless${NC}, default staging)
              dev=docker-compose.yml  test=fullstack-test  staging=nip.io
              prod=real domain        stateless=no persistence
  ${CYAN}up${NC}        ensure setup (env files, .generated), then compose up -d
  ${CYAN}down${NC}      compose down
  ${CYAN}build${NC}     compose build [services...]
  ${CYAN}ps${NC}        compose ps
  ${CYAN}logs${NC}      compose logs -f [service]

${BOLD}COMPANION STACKS${NC} (own compose projects; see rf-node docs)
  twin-b / dask / msci-engines are managed by twin-polari-build.sh — not
  wrapped here yet (bld-5+ folds them into the manifest model).

${BOLD}NOTE${NC} Standalone node and the combined suite share container names —
run ONE of 'pol node up' / 'pol suite up' at a time.
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
        dev)       echo "docker compose -f docker-compose.yml" ;;
        test)      echo "docker compose -f docker-compose.fullstack-test.yml" ;;
        staging)   echo "docker compose -f docker-compose.staging-nip.yml" ;;
        prod)      echo "docker compose -f docker-compose.prod.yml" ;;
        stateless) echo "docker compose -f docker-compose.stateless.yml" ;;
        *)         die "unknown --env '$ENV_MODE' (dev|test|staging|prod|stateless)" ;;
    esac
}

ensure_setup() {
    export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
    # env files are gitignored + generated: heal a fresh clone.
    if [ ! -f "$POL_RF_NODE/prf-mariadb/mariadb.env" ] || \
       { [ "$ENV_MODE" = "staging" ] && [ ! -f "$POL_RF_NODE/.generated/.env.staging" ]; }; then
        log_info "Missing generated files — running staging-setup.sh (LOCAL_IP=$LOCAL_IP)"
        bash "$POL_RF_NODE/staging-setup.sh"
    fi
}

cd "$POL_RF_NODE"
case "$COMMAND" in
    up)    ensure_setup; export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
           # deploy-time security gate: fail closed on placeholder secrets
           # for prod, warn for the other tiers (pol security help).
           case "$ENV_MODE" in
               staging|prod) bash "$SCRIPT_DIR/security.sh" gate "$ENV_MODE" ;;
           esac
           $(compose_cmd) up -d "$@";
           record_build compose node "$ENV_MODE"
           log_success "node up ($ENV_MODE) — 'pol start/rebuild/stop' now shorthand this" ;;
    down)  export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) down "$@" ;;
    build) export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"; $(compose_cmd) build "$@" ;;
    ps)    export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) ps "$@" ;;
    logs)  export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) logs -f "$@" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown node command: $COMMAND"; show_help; exit 1 ;;
esac
