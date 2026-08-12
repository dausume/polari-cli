#!/bin/bash
# pol security — credential + cert setup (self-generating substrate).
# Thin wrapper over the suite's setup scripts; the scripts own the logic
# (skip-if-exists, knobs, prompts-in-prod). See BUILD_SYSTEM_PLAN.md §0d.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol security — credentials + certificates"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}setup${NC} [dev|prod] [--auto] [--env-only|--certs-only|--skip-subs]
        Generate every credential env file + certs.
        ${BOLD}dev${NC}          random values, no prompts (safe for scripts)
        ${BOLD}prod${NC}         YOUR CHOICE per password: type one manually, or
                     press Enter to auto-generate it
        ${BOLD}prod --auto${NC}  no prompts — every password auto-generated
        Knobs (win over both modes): POLARI_KC_ADMIN_USER/_PASS,
        POLARI_MYSQL_ROOT_PASS, POLARI_KC_DB_PASS, POLARI_PSC_DB_PASS,
        POLARI_MINIO_ROOT_USER/_PASS.
        SKIP-IF-EXISTS: volume-baked passwords are never regenerated —
        delete the file (+ fresh DB volume) to rotate.

  ${CYAN}node-setup${NC} [staging|prod]
        Generate the PRF-node standalone env files + .generated configs
        (staging-setup.sh / prod-setup.sh). Needs LOCAL_IP for staging
        (auto-detected if unset).
        Knobs: POLARI_MARIADB_ROOT_PASS, POLARI_KC_DB_PASS,
        POLARI_OBJECTS_DB_PASS, POLARI_KC_ADMIN_PASS, POLARI_BE_SECRET.

  ${CYAN}status${NC}
        Show which credential files exist, which are missing, and which
        still carry legacy default values.

  ${CYAN}cleanup${NC}
        Remove ALL generated certs + credential env files (suite script's
        cleanup mode). Asks for confirmation.
"
}

status() {
    pol_box "credential file status"
    local f legacy
    for f in pol-keycloak/keycloak-admin.env pol-mariadb/mariadb.env \
             pol-file-store/minio.env pol-file-store/client.env .env \
             polari-rf-node/prf-keycloak/prf-keycloak-admin.env \
             polari-rf-node/prf-mariadb/mariadb.env; do
        if [ -f "$POL_SUITE_ROOT/$f" ]; then
            legacy=$(grep -cE '=(admin|rootpassword|kcpassword|pscpassword|polaripassword|polari-file-store-password)$' "$POL_SUITE_ROOT/$f" 2>/dev/null || true)
            if [ "${legacy:-0}" -gt 1 ]; then
                log_warn "$f exists but has $legacy legacy default value(s)"
            else
                log_success "$f"
            fi
        else
            log_warn "$f MISSING — run: pol security setup"
        fi
    done
}

COMMAND=$1; shift || true
case "$COMMAND" in
    setup)      exec bash "$POL_SUITE_ROOT/setup-polari-security.sh" "${1:-dev}" "${@:2}" ;;
    node-setup)
        MODE="${1:-staging}"
        export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
        log_info "LOCAL_IP=$LOCAL_IP"
        case "$MODE" in
            staging) exec bash "$POL_RF_NODE/staging-setup.sh" ;;
            prod)    exec bash "$POL_RF_NODE/prod-setup.sh" ;;
            *)       die "unknown node-setup mode '$MODE' (staging|prod)" ;;
        esac ;;
    status)     status ;;
    cleanup)
        read -p "Remove ALL generated certs + credential files? (yes/no): " CONFIRM
        [ "$CONFIRM" = "yes" ] || die "aborted"
        exec bash "$POL_SUITE_ROOT/setup-polari-security.sh" cleanup ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown security command: $COMMAND"; show_help; exit 1 ;;
esac
