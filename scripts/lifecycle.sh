#!/bin/bash
# pol start|rebuild|stop — shorthands for the MOST RECENT configured build
# approach (recorded by every 'up'-style command into .generated/pol-last-build).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/state.sh"

VERB=$1; shift || true

route() {   # route <action> [extra...] — dispatch to the recorded approach
    local action=$1; shift || true
    case "$POL_LAST_MODE:$POL_LAST_ROLE" in
        compose:suite) exec bash "$SCRIPT_DIR/suite.sh" "$action" --env "$POL_LAST_ENV" "$@" ;;
        compose:node)  exec bash "$SCRIPT_DIR/node.sh"  "$action" --env "$POL_LAST_ENV" "$@" ;;
        compose:*)     exec bash "$SCRIPT_DIR/compose.sh" "$POL_LAST_ROLE" "$action" "$@" ;;
        swarm:*)
            # bld-5: will route to swarm deploy/rm of the rendered stack.
            die "recorded approach is a swarm build, and swarm deploys aren't rendered yet — the pipeline will be: edit pol-services/ -> pol build render --topology swarm -> jinja-build/ stack files -> pol swarm deploy (bld-5, BUILD_SYSTEM_PLAN.md §3)" ;;
        *) die "unrecognized recorded approach '$POL_LAST_MODE:$POL_LAST_ROLE' — re-run an up command to re-record" ;;
    esac
}

is_up() {   # any containers for the recorded approach?
    case "$POL_LAST_MODE:$POL_LAST_ROLE" in
        compose:suite) docker ps --format '{{.Names}}' | grep -qE '^(pol-proxy|pol-keycloak|prf-backend)$' ;;
        compose:node)  docker ps --format '{{.Names}}' | grep -qE '^prf-backend$' ;;
        compose:engines) docker ps --format '{{.Names}}' | grep -q msci ;;
        compose:dask)  docker ps --format '{{.Names}}' | grep -q dask ;;
        *) return 1 ;;
    esac
}

case "$VERB" in
    start)
        read_build || exit 1
        log_info "Last configured build: $POL_LAST_MODE/$POL_LAST_ROLE (env $POL_LAST_ENV, $POL_LAST_WHEN)"
        if is_up; then
            log_success "already up — nothing to do ('pol rebuild' to force a rebuild)"
        else
            route up
        fi ;;
    rebuild)
        read_build || exit 1
        log_info "Rebuilding from scratch: $POL_LAST_MODE/$POL_LAST_ROLE (env $POL_LAST_ENV)"
        case "$POL_LAST_MODE:$POL_LAST_ROLE" in
            compose:suite) bash "$SCRIPT_DIR/suite.sh" build --env "$POL_LAST_ENV" && exec bash "$SCRIPT_DIR/suite.sh" up --env "$POL_LAST_ENV" ;;
            compose:node)  bash "$SCRIPT_DIR/node.sh" build --env "$POL_LAST_ENV" && exec bash "$SCRIPT_DIR/node.sh" up --env "$POL_LAST_ENV" ;;
            compose:*)     bash "$SCRIPT_DIR/compose.sh" "$POL_LAST_ROLE" build 2>/dev/null || true
                           exec bash "$SCRIPT_DIR/compose.sh" "$POL_LAST_ROLE" up ;;
            swarm:*)       route rebuild ;;
        esac ;;
    stop)
        read_build || exit 1
        log_info "Stopping: $POL_LAST_MODE/$POL_LAST_ROLE (env $POL_LAST_ENV)"
        route down ;;
    last|status)
        read_build || exit 1
        sed 's/^POL_LAST_/  /' "$POL_STATE_FILE" | grep -v '^#' ;;
    *)
        pol_box "pol start|rebuild|stop — last-build shorthands"
        echo -e "
  ${CYAN}pol start${NC}     bring the most recent configured build up (no-op if up)
  ${CYAN}pol rebuild${NC}   rebuild its images and recreate it from scratch
  ${CYAN}pol stop${NC}      take it down
  ${CYAN}pol last${NC}      show what's recorded

  Every 'up'-style command records its approach (mode/role/env) into
  .generated/pol-last-build; these verbs replay it.
" ;;
esac
