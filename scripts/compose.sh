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
  ${CYAN}livekit${NC}   pol-livekit media server           (docker-compose.livekit.yml)
  ${CYAN}reticulum${NC} pol-reticulum mesh sidecar         (docker-compose.reticulum.yml)
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
    livekit)
        # mtg-1: self-hosted LiveKit media server (LIVEKIT_COLLABORATION_
        # PLAN.md v2). Deliberate placement on a host with the bandwidth;
        # never part of the default up. Media = direct /udp publish;
        # signalling TLS terminates at prf-proxy (livekit.prf.<ip>.nip.io).
        ACTION=$1; shift || true
        cd "$POL_RF_NODE"
        # first up: generate the API key/secret (gitignored — public repos)
        if [[ ! -f livekit/keys.env ]]; then
            echo "LIVEKIT_KEYS=LK$(openssl rand -hex 6): $(openssl rand -hex 24)" > livekit/keys.env
            chmod 600 livekit/keys.env
            log_success "generated livekit/keys.env (gitignored — rotate by deleting it)"
        fi
        # ICE must advertise the HOST LAN IP, not the container (mtg-0).
        # NOT `hostname -I` — docker bridges list first there (172.20.0.1
        # was advertised on the first live up; caught by the log line).
        # The default-route source address is the honest LAN answer.
        export LIVEKIT_NODE_IP="${LIVEKIT_NODE_IP:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')}"
        [[ -n "$LIVEKIT_NODE_IP" ]] || die "cannot derive the LAN IP (no default route?) — export LIVEKIT_NODE_IP"
        # polari-link is external-by-declaration but only the twin builder
        # creates it — ensure it here so livekit stands alone honestly
        docker network inspect polari-link >/dev/null 2>&1 \
            || docker network create polari-link >/dev/null
        CMD="docker compose -p pol-livekit -f docker-compose.livekit.yml"
        case "$ACTION" in
            up)    $CMD up -d "$@"; record_build compose livekit staging; log_success "pol-livekit up (node-ip $LIVEKIT_NODE_IP; media 50000-50049/udp direct)" ;;
            down)  $CMD down "$@" ;;
            ps)    $CMD ps "$@" ;;
            logs)  $CMD logs -f "$@" ;;
            *)     die "pol compose livekit: up|down|ps|logs" ;;
        esac ;;
    reticulum)
        # ret-2: pol-reticulum mesh sidecar (RETICULUM_TRANSPORT_PLAN.md).
        # Fifth walk of the optional-worker pattern; never in the default
        # up. THE LICENCE BOUNDARY: rns/lxmf (pinned to the last MIT
        # releases — RETICULUM_LICENCE_GATE.md) exist only inside this
        # container. No LAN-IP knob needed: no ICE, no advertised
        # addresses — peers dial the published 4242 directly.
        ACTION=$1; shift || true
        cd "$POL_RF_NODE"
        # polari-link is external-by-declaration — ensure it here so the
        # sidecar stands alone honestly (the livekit precedent).
        docker network inspect polari-link >/dev/null 2>&1 \
            || docker network create polari-link >/dev/null
        CMD="docker compose -p pol-reticulum -f docker-compose.reticulum.yml"
        case "$ACTION" in
            up)    $CMD up -d --build "$@"; record_build compose reticulum staging; log_success "pol-reticulum up (RNS TCP :4242, status :4285 — set RETICULUM_URL=http://<host>:4285 on the backend)" ;;
            down)  $CMD down "$@" ;;
            build) $CMD build "$@" ;;
            ps)    $CMD ps "$@" ;;
            logs)  $CMD logs -f "$@" ;;
            *)     die "pol compose reticulum: up|down|build|ps|logs" ;;
        esac ;;
    dask)
        ACTION=$1; shift || true
        cd "$POL_RF_NODE"
        # -p matches the project the original dask deploy created —
        # without it compose defaults to the directory name and
        # collides with the running containers' fixed names.
        CMD="docker compose -p polari-dask -f docker-compose.dask.yml"
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
