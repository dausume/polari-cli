#!/bin/bash
# pol swarm — docker-swarm orchestration mode (bld-5).
#
# ROLE: swarm is the STAND-IN for isle-mesh — multi-node placement,
# overlay networking and a mesh-ish story TODAY, while the real isle-mesh
# capabilities are built (`pol isle` is the future surface).
#
# STACK RENDERING (v1 mechanism): the rendered compose bundles are
# expanded with `docker compose config`, which INLINES env_file values
# into environment maps (stack deploy ignores env_file) and resolves
# ${VAR} interpolation. The expanded stack file lands in
# .generated/stack-<role>.yml — machine-local, gitignored, contains the
# generated credentials (same trust level as the env files themselves).
# The docker-secrets refinement replaces that inlining later; refusals
# below say so honestly.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/state.sh"

show_help() {
    pol_box "pol swarm — swarm orchestration (isle-mesh stand-in)"
    echo -e "
${BOLD}CLUSTER${NC}
  ${CYAN}init${NC}              docker swarm init on this node (idempotent)
  ${CYAN}status${NC}            swarm state, nodes, stacks, secrets overview
  ${CYAN}join-token${NC}        print worker/manager join commands

${BOLD}STACKS${NC}   (roles: engines | suite | node — see notes)
  ${CYAN}render <role>${NC}     expand the rendered compose bundle into a swarm
                    stack file (.generated/stack-<role>.yml)
  ${CYAN}deploy <role>${NC}     render + docker stack deploy polari-<role>
  ${CYAN}rm <role>${NC}         remove the stack
  ${CYAN}ps [role]${NC}         stack tasks across nodes
  ${CYAN}services${NC}          all swarm services

${BOLD}NOTES${NC}
  engines  safe alongside the compose stacks (own port) — the proving role
  suite    CONFLICTS with a running compose suite (ports 80/443) — stop
           the compose stack first (pol suite down)
  secrets  v1 inlines generated env values via 'docker compose config';
           docker-secrets mounting is the planned refinement
"
}

require_swarm() {
    docker info 2>/dev/null | grep -q "Swarm: active" || \
        die "swarm not active on this node — run: pol swarm init"
}

role_compose_cmd() {
    case "$1" in
        engines) echo "docker compose -f $POL_RF_NODE/docker-compose.msci-engines.yml" ;;
        node)    echo "docker compose -f $POL_RF_NODE/docker-compose.staging-nip.yml" ;;
        suite)   echo "docker compose -f $POL_SUITE_ROOT/docker-compose.staging-nip.yml --env-file $POL_SUITE_ROOT/.generated/.env.staging" ;;
        *) return 1 ;;
    esac
}

render_stack() {
    local role=$1
    local cmd; cmd=$(role_compose_cmd "$role") || die "unknown role '$role' (engines|suite|node)"
    # The compose bundles must exist — they do (they're the repo's root
    # files, themselves generated from pol-services/; see pol build help).
    export LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
    mkdir -p "$POL_SUITE_ROOT/.generated"
    local out="$POL_SUITE_ROOT/.generated/stack-$role.yml"
    # compose config resolves env_files/interpolation; stackify.py then
    # applies the swarm-schema transforms (see its header for the list).
    $cmd config 2>/dev/null | python3 "$POL_SUITE_ROOT/pol-build/tools/stackify.py" > "$out"
    [ -s "$out" ] || die "stack render produced nothing — is the $role compose bundle present? (pol build list / pol build render)"
    log_success "stack rendered: $out"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    init)
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            log_success "swarm already active on this node"
        else
            docker swarm init ${LOCAL_IP:+--advertise-addr "$LOCAL_IP"} >/dev/null || \
                die "swarm init failed — multiple IPs? export LOCAL_IP=<addr> and retry"
            log_success "swarm initialized (single node; 'pol swarm join-token' to add more)"
        fi ;;
    status)
        pol_box "swarm status"
        docker info 2>/dev/null | grep -A2 "Swarm:" | head -3 || true
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            echo; docker node ls; echo; docker stack ls 2>/dev/null || true
        else
            log_warn "swarm not active — pol swarm init"
        fi ;;
    join-token)
        require_swarm
        docker swarm join-token worker; docker swarm join-token manager ;;
    render)
        render_stack "${1:?role required (engines|suite|node)}" ;;
    deploy)
        ROLE=${1:?role required (engines|suite|node)}
        require_swarm
        if [ "$ROLE" != "engines" ] && docker ps --format '{{.Names}}' | grep -qE '^(pol-proxy|prf-proxy)$'; then
            die "a compose $ROLE stack is running — its published ports conflict. Stop it first (pol suite down / pol node down), then re-deploy."
        fi
        render_stack "$ROLE"
        docker stack deploy -c "$POL_SUITE_ROOT/.generated/stack-$ROLE.yml" "polari-$ROLE"
        record_build swarm "$ROLE" staging
        log_success "stack polari-$ROLE deployed — pol swarm ps $ROLE (pol start/rebuild/stop now shorthand this)" ;;
    rm)
        require_swarm
        docker stack rm "polari-${1:?role required}" ;;
    ps)
        require_swarm
        if [ -n "$1" ]; then docker stack ps "polari-$1" --no-trunc | head -20
        else docker stack ls; fi ;;
    services)
        require_swarm
        docker service ls ;;
    secrets)
        die "docker-secrets mounting is the planned refinement — v1 inlines generated env values into the stack file via 'docker compose config' (see pol swarm help, STACKS notes)." ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown swarm command: $COMMAND"; show_help; exit 1 ;;
esac
