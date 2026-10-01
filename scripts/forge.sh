#!/bin/bash
# forge.sh — `pol forge`: the self-hosted forge (Forgejo), the polari-forge/
# sub-project (CICD_PIPELINE_PLAN §12, frg-0). THE PROJECT IS THE CAPABILITY,
# NEVER THE CONTENT: this dispatches to polari-forge/scripts/*.sh; the repos,
# packages, database and keys live in the forge's named volume.
#
#   pol forge help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
SUITE="${POL_SUITE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
P="$SUITE/polari-forge"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol forge${NC} — the self-hosted forge (polari-forge/, Forgejo) — the capability, never the content

  ${CYAN}the forge${NC}
    render                            secrets ONCE (.generated/forge/forge.env, 600, never printed) + app.ini
    up                                render if needed, start on 127.0.0.1:3300 (ssh :2222), wait for the API,
                                      the admin user on first run, the admin token (.generated/forge/token, 600)
    down                              stop it; the VOLUME (the content) is kept
    status                            running/health, version, URL, volume, token
    token [--new]                     check the admin token, mint one when missing/refused (or --new)

  ${CYAN}the dual route${NC} — GitHub = online availability · the forge = self-sustaining, the default for people
    mirror <owner/repo>               pull-mirror one GitHub repo onto the forge (skips one already there)
    mirror --forest                   every repo in polari-forge/forest.txt, by its hold= level (default mirror;
                                      primary = not yet, treated as mirror; link = not migrated, see \`links\` below)
    mirror --sync <owner/repo>|--forest   ask the forge to fetch NOW (after a release); otherwise it checks GitHub
                                      once a WEEK (--sync --forest skips hold=link lines — nothing to fetch)
    mirror --drop <owner/repo>        remove a repo from the forge — refuses unless it IS a mirror (never primary)
    links                             print what forest.txt holds as hold=link (NOT held here) and its GitHub URL
    apt-source [<owner>]              the two lines a person needs: the key fetch + the deb line

  ${CYAN}what it costs, what it keeps${NC}
    meter [--json]                    THE STORAGE METER: rss/peak/cpu + data per area (git, packages, db,
                                      attachments, log), repos, packages, held/linked/primary — one JSON line
                                      to meter.jsonl + a table
    retention <K> [--dry-run]         packages: keep the newest K per package + keep.txt, delete the rest
                                      (git history is never trimmed)
    posture                           registration, anonymous read, indexer, mem limit, loopback ports,
                                      secrets + token modes — OK/WARN rows and ONE line

  ${CYAN}proof${NC}
    selftest [-v]                     fake docker + fake curl, incl. THE CLEAN-TREE RULE

  ${CYAN}on production${NC} (frg-2) — POL_PROD_FORGE=on: the forge is a \`pol prod\` stack service
    (forge.<domain> + apt.<domain> behind pol-proxy, no published port, secrets in the vault).
    status|posture|meter|mirror|retention|links|apt-source|token then reach the swarm TASK
    (docker exec … curl localhost:3000); up/down/render refuse — pol prod apply / pol prod down.
See polari-forge/README.md ("On production").
EOF
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in help|-h|--help) usage; exit 0 ;; esac

[ -f "$P/scripts/_lib.sh" ] || die "polari-forge is not checked out at $P — git -C $SUITE submodule update --init polari-forge"

# ---- frg-2: the PRODUCTION home. When the prod answers say POL_PROD_FORGE=on and no compose
# forge runs here (the home forge on a dev box keeps its compose home), the forge scripts are
# pointed at the stack service: the suite's .generated/forge (where pol prod renders), the public
# names, the stack volume, the rendered stack files, and the admin token from the vault.
prod_answer() {  # KEY → env value, else the answers file's value
    local v="POL_PROD_$1"; [ -n "${!v:-}" ] && { printf '%s' "${!v}"; return; }
    grep -s "^POL_PROD_$1=" "$SUITE/.generated/prod-answers.env" | tail -n1 | cut -d= -f2-
}
compose_forge_running() {
    docker ps -q --filter label=com.docker.compose.project=polari-forge --filter label=com.docker.compose.service=forge 2>/dev/null | grep -q .
}
if [ "$(prod_answer FORGE)" = on ] && ! compose_forge_running; then
    D="$(prod_answer DOMAIN)"
    export FORGE_PROD=on FORGE_GEN="$SUITE/.generated/forge" FORGE_VOLUME=polari_forge_data
    export FORGE_OWNER="$(prod_answer FORGE_OWNER)"; [ -n "$FORGE_OWNER" ] || FORGE_OWNER=dausume
    export FORGE_STACK_FILES="$SUITE/.generated/stack-lean.yml $SUITE/.generated/stack-prod.yml"
    if [ -n "$D" ]; then export FORGE_ROOT_URL="https://forge.$D/" FORGE_DOMAIN="forge.$D" FORGE_APT_URL="https://apt.$D"; fi
    if [ ! -s "$FORGE_GEN/token" ] && [ -z "${FORGE_TOKEN:-}" ]; then
        # the admin token lives in the vault (pol prod apply put it there); read once, never printed
        source "$SCRIPT_DIR/lib/vault.sh"
        FORGE_TOKEN="$(vault_get forge ADMIN_TOKEN 2>/dev/null || true)"; export FORGE_TOKEN
    fi
    case "$cmd" in
        up|down|render) die "this forge is a pol prod service — pol prod apply / pol prod down (POL_PROD_FORGE=on in $SUITE/.generated/prod-answers.env)" ;;
        token)
            bash "$P/scripts/token.sh" "$@"
            # a freshly minted token landed in the file — its home on production is the vault
            if [ -s "$FORGE_GEN/token" ]; then
                source "$SCRIPT_DIR/lib/vault.sh"
                vault_put forge ADMIN_TOKEN "$(cat "$FORGE_GEN/token")" "the forge's admin API token (forge.$D)" \
                    && { shred -u "$FORGE_GEN/token" 2>/dev/null || rm -f "$FORGE_GEN/token"; log_success "admin token moved into the vault (forge ADMIN_TOKEN)"; } \
                    || log_warn "could not write the vault — the token stays in $FORGE_GEN/token (mode 600)"
            fi
            exit 0 ;;
    esac
fi

case "$cmd" in
    render|up|down|status|token|mirror|meter|retention|posture|apt-source|links)
        exec bash "$P/scripts/$cmd.sh" "$@" ;;
    selftest)
        exec bash "$P/selftest.sh" "$@" ;;
    *)
        log_error "unknown verb: pol forge $cmd"; usage; exit 1 ;;
esac
