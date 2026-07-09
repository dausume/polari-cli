#!/bin/bash
# pol cert — certificates per environment tier.
# dev/test/staging: self-signed / internal step-ca (no public trust needed).
# prod: YOUR CHOICE of self-signed (internal/LAN prod) or a Let's Encrypt
# walkthrough (browser-trusted, open-source certbot + DNS-01) with
# open-source auto-renew (cron + ca/renew.sh).
# The ca/ toolkit (polari-rf-node/ca/ + suite ca/) owns the logic; see
# CENTRALIZED_CA_PLAN.md.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

CA_DIR="$POL_RF_NODE/ca"

show_help() {
    pol_box "pol cert — certificates per environment"
    echo -e "
${BOLD}ENVIRONMENT TIERS${NC}
  dev / test    self-signed via the setup scripts (automatic, no action)
  staging       self-signed or internal step-ca (setup below)
  prod          CHOOSE: ${CYAN}prod self-signed${NC} or ${CYAN}prod letsencrypt${NC}

${BOLD}COMMANDS${NC}
  ${CYAN}setup${NC}               step-ca orchestrator (deps → bootstrap → issue → verify)
  ${CYAN}issue${NC}               (re)issue internal certs from the step-ca
  ${CYAN}verify${NC}              verify step-ca + issued certs
  ${CYAN}walkthrough${NC}         interactive guided CA setup

  ${CYAN}prod self-signed${NC}    production on self-signed/internal CA certs
                      (LAN prod, or import the root on clients)
  ${CYAN}prod letsencrypt${NC} [--dry-run]
                      guided walkthrough → browser-trusted cert via
                      certbot DNS-01 (all open source). Needs:
                      LE_DOMAIN, LE_EMAIL, DO_API_TOKEN (prompted).
  ${CYAN}renew${NC}               renew leaf certs now (LE + internal)
  ${CYAN}auto-renew${NC} install|status|remove
                      open-source auto-renewal: a cron entry running
                      ca/renew.sh weekly (certbot also self-no-ops
                      when the cert isn't near expiry)
"
}

CRON_TAG="# pol-cert-auto-renew"
CRON_LINE="17 3 * * 1 $CA_DIR/renew.sh >> $HOME/.pol-cert-renew.log 2>&1 $CRON_TAG"

COMMAND=$1; shift || true
case "$COMMAND" in
    setup)       exec bash "$CA_DIR/setup-ca.sh" "$@" ;;
    issue)       exec bash "$CA_DIR/issue-internal-certs.sh" "$@" ;;
    verify)      exec bash "$CA_DIR/verify-step-ca.sh" "$@" ;;
    walkthrough) exec bash "$CA_DIR/walkthrough.sh" "$@" ;;
    renew)       exec bash "$CA_DIR/renew.sh" "$@" ;;
    prod)
        CHOICE=$1; shift || true
        case "$CHOICE" in
            self-signed)
                log_info "Production on self-signed/internal CA certs."
                log_info "Generating via the prod setup path (generate-prf-certs.sh + step-ca)."
                bash "$CA_DIR/setup-ca.sh" "$@"
                log_success "internal CA certs ready. Clients must trust the root: $CA_DIR/root_ca.crt" ;;
            letsencrypt|le)
                log_info "Let's Encrypt walkthrough (open source: certbot + DNS-01)."
                log_info "Idempotent — a valid existing cert is skipped."
                bash "$CA_DIR/setup-letsencrypt.sh" "$@"
                echo
                log_info "Enable auto-renew (open-source cron): pol cert auto-renew install" ;;
            *) die "choose one: pol cert prod self-signed | pol cert prod letsencrypt" ;;
        esac ;;
    auto-renew)
        SUB=${1:-status}
        case "$SUB" in
            install)
                ( crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_LINE" ) | crontab -
                log_success "auto-renew installed (weekly cron; log: ~/.pol-cert-renew.log)"
                crontab -l | grep "$CRON_TAG" ;;
            status)
                if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
                    log_success "auto-renew ACTIVE:"; crontab -l | grep "$CRON_TAG"
                else
                    log_warn "auto-renew not installed — pol cert auto-renew install"
                fi ;;
            remove)
                crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
                log_success "auto-renew removed" ;;
            *) die "auto-renew: install | status | remove" ;;
        esac ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown cert command: $COMMAND"; show_help; exit 1 ;;
esac
