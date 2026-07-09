#!/bin/bash
# pol swarm — docker-swarm orchestration mode.
#
# ROLE IN THE ARCHITECTURE: swarm is the STAND-IN for isle-mesh — it gives
# us multi-node placement, overlay networking, secrets and a mesh-ish
# proxy story TODAY, while the real isle-mesh capabilities are still being
# built (`pol isle` is the future surface). The swarm variant set is being
# DEFINED NOW from the many variations already encoded in the compose
# family (BUILD_SYSTEM_PLAN.md bld-5: topology=swarm blocks in the
# per-service annotated files, secrets synced from the generated env
# files, overlay networks, generated swarm proxy).
#
# HONEST ABSENCE: subcommands that need the bld-5 renderer refuse with the
# exact missing piece rather than pretending.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol swarm — swarm orchestration (isle-mesh stand-in)"
    echo -e "
${BOLD}WORKING TODAY${NC}
  ${CYAN}init${NC}            docker swarm init on this node (idempotent)
  ${CYAN}status${NC}          swarm state, nodes, stacks, secrets overview
  ${CYAN}join-token${NC}      print worker/manager join commands

${BOLD}ARRIVES WITH bld-5${NC} (BUILD_SYSTEM_PLAN.md §3 — swarm output mode)
  ${CYAN}render${NC}          render stack files (topology=swarm) from pol-services/
  ${CYAN}secrets sync${NC}    create/rotate docker secrets from generated env files
  ${CYAN}deploy${NC} <role>   docker stack deploy of a rendered stack
  ${CYAN}rm${NC} <role>       remove a deployed stack
  ${CYAN}ps${NC} [role]       stack tasks across nodes

Swarm stands in for isle-mesh until 'pol isle' is real: placement across
isle-core/lightweight/this box, overlay networks instead of macvlan,
docker secrets instead of mounted env files, swarm proxy instead of the
isle-agent nginx.
"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    init)
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            log_success "swarm already active on this node"
        else
            docker swarm init ${LOCAL_IP:+--advertise-addr "$LOCAL_IP"} || \
                die "swarm init failed — multiple IPs? export LOCAL_IP=<addr> and retry"
            log_success "swarm initialized"
        fi ;;
    status)
        pol_box "swarm status"
        docker info 2>/dev/null | grep -A2 "Swarm:" || true
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            echo; docker node ls; echo; docker stack ls 2>/dev/null; echo; docker secret ls 2>/dev/null
        else
            log_warn "swarm not active — run: pol swarm init"
        fi ;;
    join-token)
        docker swarm join-token worker; docker swarm join-token manager ;;
    render|deploy|rm|ps|secrets)
        die "'pol swarm $COMMAND' needs the bld-5 swarm renderer (topology=swarm output from the per-service annotated files) — not built yet. See BUILD_SYSTEM_PLAN.md §3. Working today: init, status, join-token." ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown swarm command: $COMMAND"; show_help; exit 1 ;;
esac
