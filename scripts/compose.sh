#!/bin/bash
# pol compose — docker-compose orchestration mode. The compose family is
# LARGELY DEFINED by the existing hand-written compose files; this
# namespace fronts them per ROLE, and any service kind can be brought up
# independently (engines especially, but also any single service inside
# a role by naming it).
#
# Orchestration-mode siblings: `pol swarm` (isle-mesh stand-in, being
# defined now), `pol isle` (the real isle-mesh integration, future).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/state.sh"

show_help() {
    pol_box "pol compose — compose-file orchestration"
    echo -e "
${BOLD}USAGE${NC}  pol compose <role> <action> [services...] [--env E]

${BOLD}ROLES${NC}
  ${CYAN}suite${NC}     combined pol-* infra + prf + psc   (suite root compose trio)
  ${CYAN}node${NC}      standalone PRF node                (rf-node compose family)
  ${CYAN}engines${NC}   msci-engines worker, independent   (docker-compose.msci-engines.yml)
  ${CYAN}dask${NC}      dask scheduler + workers           (docker-compose.dask.yml)
  ${CYAN}twin${NC}      instance-B twin                    (via twin-polari-build.sh)
  ${CYAN}remote-worker${NC} engines/dask worker for ANOTHER machine (remote-worker.yml)

${BOLD}ACTIONS${NC}  up | down | build | ps | logs   (role-dependent extras noted below)

${BOLD}INDEPENDENT SERVICE DEPLOYS${NC}
  Any single service kind deploys on its own by naming it:
    pol compose node up backend          just the PRF backend
    pol compose suite build psc-backend  rebuild one image
    pol compose engines up               the engines worker alone
  (compose starts declared dependencies automatically.)

${BOLD}SHORTCUTS${NC}  'pol node …' ≡ 'pol compose node …',  'pol suite …' ≡ 'pol compose suite …'
"
}

ROLE=$1; shift || true
case "$ROLE" in
    suite)  exec bash "$SCRIPT_DIR/suite.sh" "$@" ;;
    node)   exec bash "$SCRIPT_DIR/node.sh" "$@" ;;
    engines)
        ACTION=$1; shift || true
        cd "$POL_RF_NODE"
        CMD="docker compose -f docker-compose.msci-engines.yml"
        case "$ACTION" in
            up)    $CMD up -d "$@"; record_build compose engines staging; log_success "engines worker up (independent deploy)" ;;
            down)  $CMD down "$@" ;;
            build) $CMD build "$@" ;;
            ps)    $CMD ps "$@" ;;
            logs)  $CMD logs -f "$@" ;;
            *)     die "pol compose engines: up|down|build|ps|logs" ;;
        esac ;;
    dask)
        ACTION=$1; shift || true
        cd "$POL_RF_NODE"
        CMD="docker compose -f docker-compose.dask.yml"
        case "$ACTION" in
            up)    $CMD up -d "$@" ;;
            down)  $CMD down "$@" ;;
            ps)    $CMD ps "$@" ;;
            logs)  $CMD logs -f "$@" ;;
            *)     die "pol compose dask: up|down|ps|logs" ;;
        esac ;;
    twin)
        # twin-b needs the peer network + token handshake — the existing
        # builder script owns that; don't fork its logic here.
        exec bash "$POL_RF_NODE/twin-polari-build.sh" "$@" ;;
    remote-worker)
        # Runs the engines/dask worker bundle on ANOTHER machine, pointing
        # back at this node's scheduler. Local actions manage the bundle
        # here (e.g. a second box you've ssh'd into with this repo).
        ACTION=$1; shift || true
        cd "$POL_RF_NODE"
        CMD="docker compose -f docker-compose.remote-worker.yml --profile dask"
        case "$ACTION" in
            up)    $CMD up -d "$@"; log_success "remote-worker bundle up (profile dask)" ;;
            down)  $CMD down "$@" ;;
            ps)    $CMD ps "$@" ;;
            logs)  $CMD logs -f "$@" ;;
            *)     die "pol compose remote-worker: up|down|ps|logs (run ON the worker machine; CORE_IP env points at the scheduler node)" ;;
        esac ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown compose role: $ROLE"; show_help; exit 1 ;;
esac
