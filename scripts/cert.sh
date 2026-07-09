#!/bin/bash
# pol cert — CA toolkit wrappers (step-ca centralization plan; see
# CENTRALIZED_CA_PLAN.md at the suite root and the ca/ toolkits in both
# the suite root and polari-rf-node).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol cert — CA toolkit"
    echo -e "
${BOLD}COMMANDS${NC}   (operate on the rf-node ca/ toolkit)
  ${CYAN}setup${NC}      one-command orchestrator (deps → bootstrap → issue → verify)
  ${CYAN}issue${NC}      (re)issue internal certs from the step-ca
  ${CYAN}renew${NC}      renew leaf certs
  ${CYAN}verify${NC}     verify the step-ca + issued certs
  ${CYAN}walkthrough${NC} interactive guided setup
"
}

CA_DIR="$POL_RF_NODE/ca"
COMMAND=$1; shift || true
case "$COMMAND" in
    setup)       exec bash "$CA_DIR/setup-ca.sh" "$@" ;;
    issue)       exec bash "$CA_DIR/issue-internal-certs.sh" "$@" ;;
    renew)       exec bash "$CA_DIR/renew.sh" "$@" ;;
    verify)      exec bash "$CA_DIR/verify-step-ca.sh" "$@" ;;
    walkthrough) exec bash "$CA_DIR/walkthrough.sh" "$@" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown cert command: $COMMAND"; show_help; exit 1 ;;
esac
