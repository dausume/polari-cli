#!/bin/bash
# pol odoo — Odoo ERP service pair (odoo + odoo-postgres), the backbone of
# business SIMULATIONS (odoo_sim) and REAL business ops (odoo_ops).
# Plan: ODOO_INTEGRATION_PLAN.md (od-1). Both services sit behind the
# compose profile 'odoo', so a plain `pol suite up` never starts them.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

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
export LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
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
    urls)
        DOM="$(base_domain)"; DOM="${DOM:-${LOCAL_IP}.nip.io}"
        echo "  https://odoo.$DOM/web/login?db=odoo_sim   (simulations)"
        echo "  https://odoo.$DOM/web/login?db=odoo_ops   (REAL ops)"
        echo "  dev tier: http://localhost:8069/web/login?db=odoo_sim" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown odoo command: $COMMAND"; show_help; exit 1 ;;
esac
