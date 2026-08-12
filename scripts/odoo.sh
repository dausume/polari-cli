#!/bin/bash
# pol odoo — Odoo ERP service pair (odoo + odoo-postgres), the backbone of
# business SIMULATIONS (odoo_sim) and REAL business ops (odoo_ops).
# Plan: ODOO_INTEGRATION_PLAN.md (od-1). Both services sit behind the
# compose profile 'odoo', so a plain `pol suite up` never starts them.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/odoo-sso.sh"

show_help() {
    pol_box "pol odoo — ERP: business sims + real business ops"
    echo -e "
${BOLD}COMMANDS${NC}   (all take ${CYAN}--env dev|staging|prod${NC}, default staging)
  ${CYAN}up${NC}               ensure credentials, then start odoo-postgres + odoo
  ${CYAN}down${NC}             stop + remove the two containers (volumes KEPT)
  ${CYAN}build${NC}            (re)build the two images
  ${CYAN}status${NC}           containers, health, databases, backup receipts
  ${CYAN}logs [service]${NC}   follow logs (default: odoo)
  ${CYAN}init-db <sim|ops>${NC} create odoo_sim / odoo_ops (base modules, no
                   demo data) and set a fresh admin password (printed ONCE)
  ${CYAN}backup <sim|ops>${NC} pg_dump receipt -> .generated/backups/ (the ONLY
                   sanctioned way to touch ops data before od-6 guardrails)
  ${CYAN}sso-setup${NC}        od-2: ensure KC client 'odoo' (realm Polari) +
                   install auth_oidc + provider row in every odoo_% DB
                   — idempotent, needs pol-keycloak running
  ${CYAN}scenario-init <db>${NC} od-5: create a THROWAWAY scenario DB
                   (odoo_scn_* only) [--modules m1,m2] [--admin-pass p]
  ${CYAN}scenario-drop <db>${NC} od-5: pg_dump receipt, then DROP the
                   scenario DB (odoo_scn_* only — never sim/ops)
  ${CYAN}backup-cron <install|remove|status>${NC} od-6: nightly pg_dump
                   receipts for sim+ops (03:17, keep last 14) on THIS
                   host's crontab
  ${CYAN}restore-drill <sim|ops>${NC} od-6: restore the LATEST receipt
                   into a throwaway DB, verify table+row counts, drop
                   — backups you have not restored are hopes, not
                   backups
  ${CYAN}urls${NC}             where to log in

${BOLD}NOTES${NC}
  sim vs ops NEVER blur: odoo_sim is free to write, odoo_ops is real
  business data. The web database manager is disabled (list_db=False) —
  pick the DB via /web/login?db=odoo_sim. Intended host: econ-core.
  Credential drift trap + rescue: pol-odoo/README.md.
"
}

ENV_MODE="staging"
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --env) ENV_MODE="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"
COMMAND=$1; shift || true

compose_cmd() {
    case "$ENV_MODE" in
        dev)     echo "docker compose -f docker-compose.yml --profile odoo" ;;
        staging) echo "docker compose -f docker-compose.staging-nip.yml --env-file .generated/.env.staging --profile odoo" ;;
        prod)    echo "docker compose -f docker-compose.prod.yml --env-file .generated/.env.prod --profile odoo" ;;
        *)       die "unknown --env '$ENV_MODE' (dev|staging|prod)" ;;
    esac
}

ensure_credentials() {
    if [ ! -f "$POL_SUITE_ROOT/pol-odoo-postgres/odoo-postgres.env" ] || \
       [ ! -f "$POL_SUITE_ROOT/pol-odoo/odoo.env" ]; then
        log_info "Missing Odoo credential files — running setup-polari-security.sh dev --env-only --skip-subs"
        bash "$POL_SUITE_ROOT/setup-polari-security.sh" dev --env-only --skip-subs
    fi
}

ensure_env_file() {
    # staging/prod compose files need their generated --env-file; odoo rides
    # the suite's config (nip-staging-setup.sh / prod-setup.sh own it).
    case "$ENV_MODE" in
        staging) [ -f "$POL_SUITE_ROOT/.generated/.env.staging" ] || \
            die "no .generated/.env.staging — run 'pol suite up --env staging' once (odoo rides the suite config)" ;;
        prod)    [ -f "$POL_SUITE_ROOT/.generated/.env.prod" ] || \
            die "no .generated/.env.prod — run ./prod-setup.sh once" ;;
    esac
}

db_name_for() {
    case "$1" in
        sim) echo "odoo_sim" ;;
        ops) echo "odoo_ops" ;;
        *)   die "expected 'sim' or 'ops' (the two-database invariant), got: '$1'" ;;
    esac
}

# Run a shell line inside a service container (compose exec, no TTY).
odoo_exec() { local svc="$1"; shift; $(compose_cmd) exec -T "$svc" sh -c "$*"; }

base_domain() {
    grep -E '^BASE_DOMAIN=' "$POL_SUITE_ROOT/.generated/.env.staging" 2>/dev/null | cut -d= -f2
}

cd "$POL_SUITE_ROOT"
export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
case "$COMMAND" in
    up)
        ensure_credentials
        ensure_env_file
        $(compose_cmd) up -d odoo-postgres odoo "$@"
        log_success "odoo up ($ENV_MODE). 'pol odoo status' for health; 'pol odoo init-db sim' to create the first database."
        ;;
    down)
        $(compose_cmd) rm -sf odoo odoo-postgres
        log_success "odoo containers stopped + removed (volumes odoo-db-data / odoo-filestore kept)" ;;
    build)
        $(compose_cmd) build odoo-postgres odoo "$@" ;;
    logs)
        SVC="${1:-odoo}"
        $(compose_cmd) logs -f "$SVC" ;;
    status)
        ensure_env_file
        $(compose_cmd) ps odoo-postgres odoo || true
        echo ""
        if odoo_exec odoo 'python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen(\"http://localhost:8069/web/health\", timeout=5).status==200 else 1)"' 2>/dev/null; then
            log_success "odoo /web/health OK"
        else
            log_warn "odoo /web/health not answering (booting, unhealthy, or not up)"
        fi
        echo ""
        echo "  databases:"
        odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT datname FROM pg_database WHERE datname LIKE '"'"'odoo_%'"'"'"' 2>/dev/null \
            | sed 's/^/    /' || echo "    (postgres not answering)"
        echo ""
        echo "  backup receipts (.generated/backups/):"
        ls -lh "$POL_SUITE_ROOT/.generated/backups/" 2>/dev/null | grep -E '^-.*odoo-' | awk '{print "    "$9"  ("$5")"}' \
            || echo "    (none yet)"
        ;;
    init-db)
        DB=$(db_name_for "${1:-}")
        ensure_env_file
        if odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='"'"''"$DB"''"'"'"' 2>/dev/null | grep -q 1; then
            die "$DB already exists — refusing to re-init (drop it deliberately first if that is really what you want)"
        fi
        log_info "Creating $DB (base modules, no demo data) — takes a minute or two"
        odoo_exec odoo 'odoo --no-http --stop-after-init -d '"$DB"' -i base --without-demo=all --db_host "$HOST" --db_port "$PORT" --db_user "$USER" --db_password "$PASSWORD"'
        ADMIN_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
        printf 'u = env["res.users"].search([("login","=","admin")]); u.write({"password": "%s"}); env.cr.commit()\n' "$ADMIN_PASS" | \
            odoo_exec odoo 'odoo shell --no-http -d '"$DB"' --db_host "$HOST" --db_port "$PORT" --db_user "$USER" --db_password "$PASSWORD"' >/dev/null
        log_success "$DB created."
        echo ""
        echo "  login:    admin"
        echo "  password: $ADMIN_PASS"
        log_warn "shown ONCE, not stored anywhere — save it now (SSO via Keycloak lands in od-2)"
        ;;
    backup)
        DB=$(db_name_for "${1:-}")
        ensure_env_file
        BAKDIR="$POL_SUITE_ROOT/.generated/backups"; mkdir -p "$BAKDIR"
        BAK="$BAKDIR/odoo-${1}-$(date +%Y%m%d-%H%M%S).sql"
        odoo_exec odoo-postgres 'pg_dump -U "$POSTGRES_USER" '"$DB" > "$BAK" || { rm -f "$BAK"; die "pg_dump failed for $DB"; }
        BAKSZ=$(du -k "$BAK" | awk '{print $1}')
        [ "$BAKSZ" -gt 0 ] || { rm -f "$BAK"; die "dump file is empty"; }
        log_success "receipt: $BAK (${BAKSZ}K) — gitignored; NEVER commit dumps (public repos)" ;;
    sso-setup)
        ensure_env_file
        DOM="$(base_domain)"; DOM="${DOM:-${LOCAL_IP}.nip.io}"
        odoo_sso_setup "$DOM" ;;
    scenario-init)
        DB="${1:-}"; shift || true
        MODULES="base"; ADMIN_PASS="${POLARI_ODOO_SCENARIO_ADMIN_PASS:-}"
        while [ $# -gt 0 ]; do case "$1" in
            --modules) MODULES="$2"; shift 2 ;;
            --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
            *) shift ;;
        esac; done
        case "$DB" in odoo_scn_*) ;; *)
            die "scenario DBs are odoo_scn_* ONLY (got '$DB') — the throwaway discipline protects odoo_sim/odoo_ops" ;;
        esac
        ensure_env_file
        if odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='"'"''"$DB"''"'"'"' 2>/dev/null | grep -q 1; then
            log_info "$DB already exists — leaving it (scenario engine is idempotent)"
        else
            log_info "Creating $DB with modules: $MODULES (takes a few minutes)"
            odoo_exec odoo 'odoo --no-http --stop-after-init -d '"$DB"' -i '"$MODULES"' --without-demo=all --db_host "$HOST" --db_port "$PORT" --db_user "$USER" --db_password "$PASSWORD"'
        fi
        if [ -n "$ADMIN_PASS" ]; then
            printf 'u = env["res.users"].search([("login","=","admin")]); u.write({"password": "%s"}); env.cr.commit()\n' "$ADMIN_PASS" | \
                odoo_exec odoo 'odoo shell --no-http -d '"$DB"' --db_host "$HOST" --db_port "$PORT" --db_user "$USER" --db_password "$PASSWORD"' >/dev/null
            log_success "$DB ready; admin password set (match it to the backend's ODOO_SIM_RPC_PASSWORD so the scenario engine can drive)"
        else
            log_success "$DB ready"
            log_warn "admin password is the fresh-install default — pass --admin-pass (or POLARI_ODOO_SCENARIO_ADMIN_PASS) matching the backend's ODOO_SIM_RPC_PASSWORD"
        fi ;;
    scenario-drop)
        DB="${1:-}"
        case "$DB" in odoo_scn_*) ;; *)
            die "scenario-drop refuses '$DB' — odoo_scn_* ONLY (sim/ops are never dropped from here)" ;;
        esac
        ensure_env_file
        BAKDIR="$POL_SUITE_ROOT/.generated/backups"; mkdir -p "$BAKDIR"
        BAK="$BAKDIR/${DB}-final-$(date +%Y%m%d-%H%M%S).sql"
        odoo_exec odoo-postgres 'pg_dump -U "$POSTGRES_USER" '"$DB" > "$BAK" || { rm -f "$BAK"; die "pg_dump failed for $DB — NOT dropping"; }
        BAKSZ=$(du -k "$BAK" | awk '{print $1}')
        [ "$BAKSZ" -gt 0 ] || { rm -f "$BAK"; die "empty dump — NOT dropping"; }
        odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='"'"''"$DB"''"'"'" -c "DROP DATABASE '"$DB"'"' >/dev/null
        log_success "dropped $DB; final receipt: $BAK (${BAKSZ}K)" ;;
    backup-cron)
        SUB="${1:-status}"
        MARK="# polari-odoo-backup (pol odoo backup-cron)"
        case "$SUB" in
            install)
                LINE="17 3 * * * POL_SUITE_ROOT=$POL_SUITE_ROOT $(command -v pol || echo pol) odoo backup sim >/dev/null 2>&1; $(command -v pol || echo pol) odoo backup ops >/dev/null 2>&1; ls -1t $POL_SUITE_ROOT/.generated/backups/odoo-sim-*.sql 2>/dev/null | tail -n +15 | xargs -r rm --; ls -1t $POL_SUITE_ROOT/.generated/backups/odoo-ops-*.sql 2>/dev/null | tail -n +15 | xargs -r rm -- $MARK"
                ( crontab -l 2>/dev/null | grep -vF "$MARK" || true; echo "$LINE" ) | crontab -
                log_success "nightly backup cron installed (03:17, keep last 14 per db) — THIS host only; run on the odoo host (econ-core) too" ;;
            remove)
                ( crontab -l 2>/dev/null | grep -vF "$MARK" || true ) | crontab -
                log_success "backup cron removed" ;;
            status)
                if crontab -l 2>/dev/null | grep -qF "$MARK"; then
                    crontab -l | grep -F "$MARK"
                else
                    log_warn "no odoo backup cron on this host — 'pol odoo backup-cron install'"
                fi ;;
            *) die "backup-cron install|remove|status" ;;
        esac ;;
    restore-drill)
        DB=$(db_name_for "${1:-}")
        ensure_env_file
        BAK=$(ls -1t "$POL_SUITE_ROOT/.generated/backups/odoo-${1}-"*.sql 2>/dev/null | head -1)
        [ -n "$BAK" ] || die "no backup receipt for $DB in .generated/backups/ — 'pol odoo backup ${1}' first (a drill needs something to drill)"
        DRILL="odoo_scn_restore_drill"
        log_info "Drill: restoring $(basename "$BAK") into $DRILL"
        odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='"'"''"$DRILL"''"'"'" -c "DROP DATABASE IF EXISTS '"$DRILL"'" -c "CREATE DATABASE '"$DRILL"'"' >/dev/null
        $(compose_cmd) exec -T odoo-postgres psql -q -U odoo -d "$DRILL" -f /dev/stdin < "$BAK" >/dev/null 2>&1 || true
        DUMP_TABLES=$(grep -c '^CREATE TABLE' "$BAK")
        GOT_TABLES=$(odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d '"$DRILL"' -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='"'"'public'"'"' AND table_type='"'"'BASE TABLE'"'"'"' | tr -d '[:space:]')
        DUMP_USERS=$(awk '/^COPY public.res_users /{f=1;next} f&&/^\\\.$/{exit} f{n++} END{print n+0}' "$BAK")
        GOT_USERS=$(odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d '"$DRILL"' -tAc "SELECT count(*) FROM res_users"' | tr -d '[:space:]')
        DUMP_MODELS=$(awk '/^COPY public.ir_model /{f=1;next} f&&/^\\\.$/{exit} f{n++} END{print n+0}' "$BAK")
        GOT_MODELS=$(odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d '"$DRILL"' -tAc "SELECT count(*) FROM ir_model"' | tr -d '[:space:]')
        echo "  tables:   dump=$DUMP_TABLES restored=$GOT_TABLES"
        echo "  res_users: dump=$DUMP_USERS restored=$GOT_USERS"
        echo "  ir_model:  dump=$DUMP_MODELS restored=$GOT_MODELS"
        odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='"'"''"$DRILL"''"'"'" -c "DROP DATABASE '"$DRILL"'"' >/dev/null
        if [ "$DUMP_TABLES" = "$GOT_TABLES" ] && [ "$DUMP_USERS" = "$GOT_USERS" ] && [ "$DUMP_MODELS" = "$GOT_MODELS" ] && [ "$GOT_TABLES" -gt 50 ]; then
            log_success "RESTORE DRILL PASSED for $DB ($(basename "$BAK")): $GOT_TABLES tables, row-exact on res_users + ir_model; drill DB dropped"
        else
            die "RESTORE DRILL FAILED for $DB — counts diverge (see above); the backup may be unusable"
        fi ;;
    urls)
        DOM="$(base_domain)"; DOM="${DOM:-${LOCAL_IP}.nip.io}"
        echo "  https://odoo.$DOM/web/login?db=odoo_sim   (simulations)"
        echo "  https://odoo.$DOM/web/login?db=odoo_ops   (REAL ops)"
        echo "  dev tier: http://localhost:8069/web/login?db=odoo_sim" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown odoo command: $COMMAND"; show_help; exit 1 ;;
esac
