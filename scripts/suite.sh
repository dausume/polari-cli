#!/bin/bash
# pol suite — lifecycle of the COMBINED suite stack (pol-* infra + prf +
# psc behind pol-proxy). Wraps the suite-root compose files; self-heals
# missing generated config by running the setup chain first.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/remote-hint.sh"

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
  staging on a custom domain: export POLARI_STAGING_DOMAIN=your.domain before
  'up' once to switch; after that it's remembered from .generated/.env.staging
  (no need to keep re-exporting it every run).
  cold prf-backend DB seed can take ~10-15 min; its healthcheck start_period
  (900s) covers this so pol-proxy's dependency wait resolves in one pass.
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
        test)    die "no suite-level test stack exists — the rf-node has one: pol node up --env test (fullstack-test). A suite test stack would be a new compose variant (registry first)." ;;
        staging) echo "docker compose -f docker-compose.staging-nip.yml --env-file .generated/.env.staging" ;;
        prod)    echo "docker compose -f docker-compose.prod.yml --env-file .generated/.env.prod" ;;
        *)       die "unknown --env '$ENV_MODE' (dev|staging|prod; test = rf-node only)" ;;
    esac
}

ensure_staging_setup() {
    export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
    # Re-run setup when there's no env-file yet, or when the operator EXPLICITLY
    # asks for a different base domain via POLARI_STAGING_DOMAIN this run.
    # IMPORTANT: if POLARI_STAGING_DOMAIN is unset, "want" must default to
    # whatever domain is ALREADY configured (not LOCAL_IP.nip.io) — otherwise a
    # plain `pol suite up` in a fresh shell (no env var re-exported) silently
    # looks like a domain change, re-runs setup, and reverts a custom domain
    # (e.g. polari-staging.test) back to nip.io, force-recreating everything.
    local have=""
    [ -f "$POL_SUITE_ROOT/.generated/.env.staging" ] && \
        have="$(grep -E '^BASE_DOMAIN=' "$POL_SUITE_ROOT/.generated/.env.staging" | cut -d= -f2)"
    local want="${POLARI_STAGING_DOMAIN:-${have:-${LOCAL_IP}.nip.io}}"
    if [ ! -f "$POL_SUITE_ROOT/.generated/.env.staging" ] || [ "$want" != "$have" ]; then
        log_info "Generating staging config for base domain: $want"
        POLARI_STAGING_DOMAIN="$want" bash "$POL_SUITE_ROOT/nip-staging-setup.sh" "$LOCAL_IP"
    fi
}

cd "$POL_SUITE_ROOT"
case "$COMMAND" in
    up)
        [ "$ENV_MODE" = "staging" ] && ensure_staging_setup
        [ "$ENV_MODE" = "dev" ] && [ ! -f .env ] && { log_info "No suite .env — running security setup"; bash setup-polari-security.sh dev --env-only --skip-subs; }
        export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
        $(compose_cmd) up -d "$@"
        record_build compose suite "$ENV_MODE"
        log_success "suite up ($ENV_MODE). 'pol suite ps' to check health; 'pol start/rebuild/stop' now shorthand this."
        [ "$ENV_MODE" = "staging" ] && remote_access_hint || true ;;
    down)  export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) down "$@" ;;
    build) export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"; $(compose_cmd) build "$@" ;;
    ps)    export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) ps "$@" ;;
    logs)  export LOCAL_IP="${LOCAL_IP:-127.0.0.1}"; $(compose_cmd) logs -f "$@" ;;
    urls)
        DOM="$(grep -E '^BASE_DOMAIN=' "$POL_SUITE_ROOT/.generated/.env.staging" 2>/dev/null | cut -d= -f2)"
        DOM="${DOM:-${LOCAL_IP:-$(lan_ip)}.nip.io}"
        echo "  https://$DOM               (hub)"
        echo "  https://prf.$DOM      https://api.prf.$DOM"
        echo "  https://psc.$DOM      https://api.psc.$DOM"
        echo "  https://auth.$DOM     https://files.$DOM" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown suite command: $COMMAND"; show_help; exit 1 ;;
esac
