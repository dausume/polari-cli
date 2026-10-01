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
    mirror --forest                   every repo in polari-forge/forest.txt (frg-1 runs this on the chosen box)
    mirror --sync <owner/repo>|--forest   ask the forge to fetch NOW (after a release); otherwise it checks GitHub once a WEEK
    apt-source [<owner>]              the two lines a person needs: the key fetch + the deb line

  ${CYAN}what it costs, what it keeps${NC}
    meter [--json]                    THE STORAGE METER: rss/peak/cpu + data per area (git, packages, db,
                                      attachments, log), repos, packages — one JSON line to meter.jsonl + a table
    retention <K> [--dry-run]         packages: keep the newest K per package + keep.txt, delete the rest
                                      (git history is never trimmed)
    posture                           registration, anonymous read, indexer, mem limit, loopback ports,
                                      secrets + token modes — OK/WARN rows and ONE line

  ${CYAN}proof${NC}
    selftest [-v]                     fake docker + fake curl, incl. THE CLEAN-TREE RULE

Not wired into \`pol prod\` profiles yet (frg-2/frg-3). See polari-forge/README.md.
EOF
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
case "$cmd" in help|-h|--help) usage; exit 0 ;; esac

[ -f "$P/scripts/_lib.sh" ] || die "polari-forge is not checked out at $P — git -C $SUITE submodule update --init polari-forge"

case "$cmd" in
    render|up|down|status|token|mirror|meter|retention|posture|apt-source)
        exec bash "$P/scripts/$cmd.sh" "$@" ;;
    selftest)
        exec bash "$P/selftest.sh" "$@" ;;
    *)
        log_error "unknown verb: pol forge $cmd"; usage; exit 1 ;;
esac
