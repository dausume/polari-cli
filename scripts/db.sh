#!/bin/bash
# pol db — database backend selection + visibility for PRF instances.
# The framework supports sqlite (default), and mariadb + keydb cache (the
# "dbcombo" pattern, proven on twin-B). Selection is per-instance; this
# namespace shows what each instance runs and switches where switching is
# actually plumbed (honest refusal where it isn't yet).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol db — database backend per PRF instance"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}show${NC}        DATABASE_TYPE / CACHE_BACKEND of each RUNNING PRF
              backend (docker inspect) + the compose-configured defaults
  ${CYAN}options${NC}     available backends and which instances can switch today
  ${CYAN}use combo --role twin${NC}
              switch twin-B to MariaDB + KeyDB (dbcombo overlay)
  ${CYAN}use sqlite --role twin${NC}
              back to sqlite (drop the overlay; sqlite volume untouched)

${BOLD}BACKENDS${NC}
  sqlite          zero-config file DB (default for every instance)
  mariadb         object DB in shared prf-mariadb (schema per instance)
  mariadb+keydb   'combo' — mariadb objects + keydb table cache

${BOLD}NOT PLUMBED YET${NC} (honest refusal): switching the PRIMARY node/suite
backend — needs a dbcombo-style overlay for the A-instance + a migration
story for the existing sqlite volume. The knobs exist (DATABASE_TYPE,
MARIADB_*, KEYDB_*); the overlay + migration do not."
}

inspect_db() {
    local name=$1
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
        local dbt cache
        dbt=$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^DATABASE_TYPE=' | cut -d= -f2)
        cache=$(docker inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^CACHE_BACKEND=' | cut -d= -f2)
        printf "  %-16s RUNNING   db=%-8s cache=%s\n" "$name" "${dbt:-sqlite}" "${cache:-none}"
    else
        printf "  %-16s (not running)\n" "$name"
    fi
}

COMMAND=$1; shift || true
case "$COMMAND" in
    show)
        pol_box "database backends in effect"
        inspect_db prf-backend
        inspect_db prf-b-backend
        echo
        echo "  compose-configured defaults:"
        echo "    node/suite primary : sqlite (all variants)"
        echo "    twin-B             : sqlite; + dbcombo overlay => mariadb(polari_objects_b) + keydb" ;;
    options)
        show_help ;;
    use)
        BACKEND=$1; shift || true
        ROLE="twin"
        while [ $# -gt 0 ]; do case "$1" in --role) ROLE="$2"; shift 2 ;; *) shift ;; esac; done
        [ "$ROLE" = "twin" ] || die "only --role twin is switchable today — the primary needs an A-instance overlay + sqlite migration story (not built; see 'pol db options')"
        cd "$POL_RF_NODE"
        TOKEN_FILE=".generated/.polari-peer-token"
        [ -f "$TOKEN_FILE" ] || die "no peer token (.generated/.polari-peer-token) — bring the twin up first: pol compose twin"
        case "$BACKEND" in
            combo|mariadb+keydb|mariadb)
                log_info "Switching twin-B to MariaDB + KeyDB (dbcombo overlay)"
                POLARI_PEER_TOKEN="$(cat $TOKEN_FILE)" docker compose -p polari-twin-b \
                    -f docker-compose.twin-b.yml -f docker-compose.dbcombo.yml up -d
                log_success "twin-B on combo (schema polari_objects_b; sqlite volume untouched)" ;;
            sqlite)
                log_info "Dropping the overlay — twin-B back to sqlite"
                POLARI_PEER_TOKEN="$(cat $TOKEN_FILE)" docker compose -p polari-twin-b \
                    -f docker-compose.twin-b.yml up -d
                log_success "twin-B on sqlite" ;;
            *) die "unknown backend '$BACKEND' (sqlite | combo)" ;;
        esac ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown db command: $COMMAND"; show_help; exit 1 ;;
esac
