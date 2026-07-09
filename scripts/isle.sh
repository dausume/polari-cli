#!/bin/bash
# pol isle — the FUTURE isle-mesh orchestration mode.
#
# Isle-mesh (Dustin's networking project, lives on isle-core:
# ~/Isle-Mesh with its own `isle` CLI) will eventually provide the real
# mesh capabilities: macvlan/vLAN placement, router join protocol,
# mDNS/.isle dual-domain DNS, per-app nginx agents with mTLS
# re-encryption. Until then `pol swarm` is the deliberate STAND-IN.
#
# This namespace exists so the mode model is visible from day one
# (compose | swarm | isle); every action refuses honestly and points at
# the plan. The polari build system (jinja-script per-service files,
# generated proxies) is being built AS the guidepost for isle-mesh-apps,
# so the seam is designed, not bolted on.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol isle — isle-mesh mode (future)"
    echo -e "
Not implemented yet — ${CYAN}pol swarm${NC} is the stand-in orchestration
mode until isle-mesh capabilities land here.

What will arrive (per BUILD_SYSTEM_PLAN.md + the isle-mesh project):
  isle-mesh app packaging of polari services (isle-mesh-apps)
  mesh placement + join (router protocol, macvlan, .isle DNS)
  per-app proxy agents with mTLS cert interlinking

Reference implementation: isle-core:~/Isle-Mesh (its own 'isle' CLI).
"
}

case "${1:-help}" in
    help|-h|--help) show_help ;;
    *) log_warn "'pol isle $1' — isle-mesh mode is not implemented yet; 'pol swarm' is the stand-in."; show_help; exit 1 ;;
esac
