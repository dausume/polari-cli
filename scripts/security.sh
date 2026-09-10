#!/bin/bash
# pol security — credential + cert lifecycle (self-generating substrate).
# All security material is put in AT DEPLOY TIME by the setup shells; this
# verb wraps them for BOTH first deployment and smooth updates:
#   - status: what exists, what's placeholder, last-updated age, STALE flags
#   - gate:   the deploy-time check (fail closed on placeholders for prod)
#   - rotate: keep-or-rotate update + ordered rollout (KC first, then backend)
# The scripts own the generation logic (skip-if-exists, knobs,
# prompts-in-prod); the timestamp ledger lives in
# polari-rf-node/security-ledger.sh. See BUILD_SYSTEM_PLAN.md §0d.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$POL_RF_NODE/security-ledger.sh"

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
        (staging-setup.sh / prod-setup.sh). Existing REAL credentials are
        KEPT (staleness flagged); placeholders are rotated fail-closed.
        Knobs: POLARI_ROTATE_KC=yes|no, POLARI_MARIADB_ROOT_PASS,
        POLARI_KC_DB_PASS, POLARI_OBJECTS_DB_PASS, POLARI_KC_ADMIN_PASS.

  ${CYAN}status${NC}
        Full inventory: which credential files exist / are missing /
        carry placeholder values, when each was last updated (ledger),
        STALE flags past ${SEC_STALE_DAYS}d, cert expiries, and whether the
        RUNNING stack carries placeholder credentials.

  ${CYAN}gate${NC} [staging|prod]
        The deploy-time check (node/suite up runs it for you):
        prod = FAIL CLOSED on missing/placeholder credentials
        (override: POLARI_SKIP_SECURITY_GATE=yes); staging = warnings.
        Stale material always gets a rotation SUGGESTION, never an
        auto-rotate.

  ${CYAN}rotate${NC} [staging|prod]
        Smooth credential update on a LIVE deployment: re-runs the setup
        shell with POLARI_ROTATE_KC=yes, then rolls out in the required
        order — Keycloak first (its entrypoint re-PATCHes the client
        secret), backend second — and verifies the rollout.

  ${CYAN}cleanup${NC}
        Remove ALL generated certs + credential env files (suite script's
        cleanup mode). Asks for confirmation.
"
}

# Inventory: ledger-name|path (path relative to suite root). Files without a
# stamped name fall back to mtime for age.
CRED_FILES=(
    "kc-admin-env|polari-rf-node/prf-keycloak/prf-keycloak-admin.env"
    "mariadb-env|polari-rf-node/prf-mariadb/mariadb.env"
    "suite-kc-admin-env|pol-keycloak/keycloak-admin.env"
    "suite-mariadb-env|pol-mariadb/mariadb.env"
    "suite-minio-env|pol-file-store/minio.env"
    "suite-minio-client-env|pol-file-store/client.env"
    "suite-env|.env"
)

status_one() {  # NAME PATH -> prints a line, returns 1 on missing/placeholder
    local name=$1 rel=$2 path="$POL_SUITE_ROOT/$2" ph age flag=""
    if [ ! -f "$path" ]; then
        log_warn "$rel MISSING — run: pol security setup / node-setup"
        return 1
    fi
    ph=$(sec_placeholders "$path")
    age=$(ledger_age_days "$name" "$path")
    if sec_is_stale "$name" "$path"; then flag=" ${YELLOW}STALE(>${SEC_STALE_DAYS}d)${NC}"; fi
    if [ "${ph:-0}" -gt 0 ]; then
        log_error "$rel — $ph PLACEHOLDER/default secret value(s), last updated ${age:-?}d ago (not deployable)"
        return 1
    fi
    echo -e "  ${GREEN}ok${NC} $rel — last updated ${age:-?}d ago$flag"
}

cert_status() {
    local crt end days
    for crt in "$POL_RF_NODE"/ca/*.crt "$POL_RF_NODE"/ca/*.pem \
               "$POL_RF_NODE"/certs/*.crt "$POL_SUITE_ROOT"/ca/*.crt \
               "$POL_RF_NODE"/.generated/certs/*.crt; do
        [ -f "$crt" ] || continue
        end=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2) || continue
        days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
        if [ "$days" -lt 0 ]; then
            log_error "cert EXPIRED ${days#-}d ago: $crt"
        elif [ "$days" -lt 30 ]; then
            log_warn "cert expires in ${days}d: $crt — pol cert renew"
        else
            echo -e "  ${GREEN}ok${NC} cert $(basename "$crt") — ${days}d to expiry"
        fi
    done
}

live_stack_probe() {  # returns 1 if the RUNNING stack carries placeholders
    local cid env bad=0
    cid=$(docker ps --filter name=prf-keycloak -q 2>/dev/null | head -1)
    [ -n "$cid" ] || return 0
    env=$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)
    if echo "$env" | grep -qE '^KEYCLOAK_POLARI_BACKEND_CLIENT_SECRET=(REPLACE_ME|$)'; then
        log_error "RUNNING Keycloak carries a PLACEHOLDER client secret — rotate + redeploy: pol security rotate"
        bad=1
    fi
    if echo "$env" | grep -qE '^KEYCLOAK_ADMIN_PASSWORD=(admin|)$'; then
        log_error "RUNNING Keycloak admin password is the dev default — rotate + redeploy: pol security rotate"
        bad=1
    fi
    [ "$bad" -eq 0 ] && echo -e "  ${GREEN}ok${NC} running Keycloak carries non-placeholder credentials"
    return $bad
}

status() {
    pol_box "credential + cert status (stale threshold: ${SEC_STALE_DAYS}d)"
    local entry name rel bad=0
    for entry in "${CRED_FILES[@]}"; do
        name="${entry%%|*}"; rel="${entry#*|}"
        status_one "$name" "$rel" || bad=1
    done
    cert_status
    live_stack_probe || bad=1
    return $bad
}

gate() {
    local envmode="${1:-staging}" rc=0
    status || rc=1
    if [ "$rc" -ne 0 ]; then
        case "$envmode" in
            prod|public)
                if [ "${POLARI_SKIP_SECURITY_GATE:-no}" = "yes" ]; then
                    log_warn "security gate FAILED but POLARI_SKIP_SECURITY_GATE=yes — proceeding"
                else
                    die "security gate FAILED for '$envmode' — fix with: pol security node-setup prod (then pol security rotate $envmode if the stack is live). Override (NOT for internet-facing): POLARI_SKIP_SECURITY_GATE=yes"
                fi ;;
            *)
                log_warn "security gate found issues (see above) — tolerated on '$envmode', would BLOCK a prod deploy" ;;
        esac
    else
        log_success "security gate clean for '$envmode'"
    fi
}

wait_healthy() {  # CONTAINER-NAME-FILTER TIMEOUT-SECONDS (swarm task names)
    local name=$1 timeout=${2:-300} waited=0
    log_info "waiting for $name to report healthy (max ${timeout}s)..."
    while [ "$waited" -lt "$timeout" ]; do
        if docker ps --filter "name=$name" --format '{{.Status}}' | grep -q healthy; then
            log_success "$name healthy after ${waited}s"; return 0
        fi
        sleep 5; waited=$((waited + 5))
    done
    die "$name did not report healthy within ${timeout}s — rollout NOT completed"
}

wait_healthy_svc() {  # COMPOSE-FILE SERVICE TIMEOUT — exact container via compose
    local cf=$1 svc=$2 timeout=${3:-300} waited=0 cid state
    cid=$(docker compose -f "$cf" ps -q "$svc" | head -1)
    [ -n "$cid" ] || die "no running container for compose service '$svc'"
    log_info "waiting for $svc ($cid) to report healthy (max ${timeout}s)..."
    while [ "$waited" -lt "$timeout" ]; do
        state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null)
        case "$state" in
            healthy) log_success "$svc healthy after ${waited}s"; return 0 ;;
            running) log_success "$svc running after ${waited}s (no healthcheck defined)"; return 0 ;;
        esac
        sleep 5; waited=$((waited + 5))
    done
    die "$svc did not report healthy within ${timeout}s — rollout NOT completed"
}

rotate() {
    local envmode="${1:-staging}"
    pol_box "credential rotation + ordered rollout ($envmode)"
    export POLARI_ROTATE_KC=yes
    export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
    case "$envmode" in
        staging) bash "$POL_RF_NODE/staging-setup.sh" ;;
        prod)    bash "$POL_RF_NODE/prod-setup.sh" ;;
        *)       die "rotate: staging|prod" ;;
    esac
    # Rollout order matters: Keycloak's entrypoint PATCHes the new client
    # secret into the realm; the backend reads it at boot. KC first, wait
    # healthy, THEN the backend — never both at once.
    if docker service inspect polari-node_prf-keycloak >/dev/null 2>&1; then
        log_info "swarm stack detected — redeploying (stack re-inlines the env files)"
        bash "$SCRIPT_DIR/swarm.sh" deploy node
        wait_healthy prf-keycloak 300
        docker service update --force polari-node_backend >/dev/null
        wait_healthy "polari-node_backend" 300
    else
        cd "$POL_RF_NODE"
        local cf
        case "$envmode" in
            staging) cf=docker-compose.staging-nip.yml ;;
            prod)    cf=docker-compose.prod.yml ;;
        esac
        docker compose -f "$cf" up -d --force-recreate prf-keycloak
        wait_healthy_svc "$cf" prf-keycloak 300
        docker compose -f "$cf" up -d --force-recreate backend
        wait_healthy_svc "$cf" backend 300
    fi
    live_stack_probe || die "rotation rolled out but the running stack STILL shows placeholders — investigate before exposing this deployment"
    log_success "rotation complete — new credentials live, rollout order respected"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    os)
        # sec: the DAC + MAC controls (os-security/): render for a scenario + the apps up, apply, audit, escape-test
        OSD="$POL_SUITE_ROOT/os-security"; V="${1:-help}"; shift || true
        SCN="${OS_SEC_SCENARIO:-}"; REST=()
        while [ $# -gt 0 ]; do case "$1" in --scenario) SCN="$2"; shift 2 ;; *) REST+=("$1"); shift ;; esac; done
        [ -n "$SCN" ] || SCN=$( { docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^isle-(vlan|remote)-agent$' && echo isle; } || { docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx polari-prod && echo swarm-full; } || { docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx polari-lean && echo swarm-lean; } || echo dev )
        case "$V" in
            render)      python3 "$OSD/render.py" --scenario "$SCN" "${REST[@]:---apps-from-manifests}" ;;
            apply)       [ "$(id -u)" = 0 ] && bash "$OSD/apply.sh" --scenario "$SCN" "${REST[@]}" || sudo bash "$OSD/apply.sh" --scenario "$SCN" "${REST[@]}" ;;
            audit)       bash "$OSD/audit.sh" --scenario "$SCN" "${REST[@]}" ;;
            escape-test) [ "$(id -u)" = 0 ] && bash "$OSD/escape-test.sh" --scenario "$SCN" "${REST[@]}" || sudo bash "$OSD/escape-test.sh" --scenario "$SCN" "${REST[@]}" ;;
            *) echo "pol security os render|apply [--complain|--enforce|--dry-run]|audit [--json]|escape-test [--profile P]   [--scenario isle|swarm-lean|swarm-full|dev]  (scenario auto-detected: $SCN)" ;;
        esac ;;
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
    status)     status || true ;;
    gate)       gate "$@" ;;
    rotate)     rotate "$@" ;;
    cleanup)
        read -p "Remove ALL generated certs + credential files? (yes/no): " CONFIRM
        [ "$CONFIRM" = "yes" ] || die "aborted"
        exec bash "$POL_SUITE_ROOT/setup-polari-security.sh" cleanup ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown security command: $COMMAND"; show_help; exit 1 ;;
esac
