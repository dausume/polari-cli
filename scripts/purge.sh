#!/bin/bash
# pol purge — scenario C of AI-Notes/plans/UNINSTALL_LIFECYCLE_PLAN.md:
# remove every polari/isle RUNTIME artifact from a DEV/HYBRID box (the
# machine that builds from the suite checkout), mirroring the manual
# 2026-08-17 purge. The suite CODE, the pol CLI, third-party systems
# (odoo), and backups are NEVER touched.
#
#   pol purge            confirm, then: backup volumes → swarm stack rm
#                        → containers → volumes → networks → images
#   pol purge --force    no confirmation
#   pol purge --dry-run  print what WOULD go, remove nothing
#
# Exact-name families only (the aisleriot lesson — never fuzzy-match).
# Data volumes are tarred to ~/polari-purge-backup-<date>/ before
# removal; the backup path is always printed.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

FORCE=0; DRY=0
for a in "$@"; do case "$a" in
    --force|-f) FORCE=1 ;;
    --dry-run) DRY=1 ;;
esac; done

# exact families; odoo EXCLUDED everywhere (business system, not polari)
CTR_RE='^(prf-[a-z0-9-]+|polari-[a-z0-9_-]+|pol-(reticulum|livekit)|mtg1-page|isle-[a-z0-9_-]+)$'
VOL_RE='^(polari-(rf-node|suite|twin-b)_|prf-|polari-isle_|isle-)'
NET_RE='^(isle-|polari-|prf-)'
IMG_RE='^(prf-|polari|isle|pol-(reticulum|livekit|hub|proxy|keycloak|mariadb|file-store)|[0-9.]+:5000/)'
ODOO_RE='odoo'

list_targets() {
    echo "== swarm stacks:"
    docker stack ls --format '{{.Name}}' 2>/dev/null | grep -E '^polari' || true
    echo "== containers:"
    docker ps -a --format '{{.Names}}' | grep -E "$CTR_RE" | grep -vE "$ODOO_RE" || true
    echo "== volumes (backed up first):"
    docker volume ls --format '{{.Name}}' | grep -E "$VOL_RE" | grep -vE "$ODOO_RE" || true
    echo "== networks:"
    docker network ls --format '{{.Name}}' | grep -E "$NET_RE" | grep -vE "$ODOO_RE" || true
    echo "== images:"
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "$IMG_RE" | grep -vE "$ODOO_RE" || true
}

pol_box "pol purge — dev-box polari/isle runtime removal"
echo "SPARED always: the suite code checkout, the pol CLI, odoo (business"
echo "system), and every polari-purge-backup directory."
echo
list_targets
echo
if [ "$DRY" = 1 ]; then
    log_info "dry run — nothing removed"
    exit 0
fi
if [ "$FORCE" = 0 ]; then
    read -p "Remove ALL of the above (volumes are backed up first)? (yes/no): " C
    [ "$C" = "yes" ] || die "aborted"
fi

BK="$HOME/polari-purge-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
for v in $(docker volume ls --format '{{.Name}}' | grep -E "$VOL_RE" | grep -vE "$ODOO_RE"); do
    docker run --rm -v "$v":/v:ro -v "$BK":/b alpine tar czf "/b/$v.tgz" -C /v . >/dev/null 2>&1 \
        && log_success "backed up $v"
done
log_success "backups: $BK"

for s in $(docker stack ls --format '{{.Name}}' 2>/dev/null | grep -E '^polari'); do
    docker stack rm "$s" && log_success "stack removed: $s"
done
# stack teardown is async — wait for its containers to drain
sleep 15

for c in $(docker ps -a --format '{{.Names}}' | grep -E "$CTR_RE" | grep -vE "$ODOO_RE"); do
    docker rm -f "$c" >/dev/null 2>&1 && log_success "container removed: $c"
done
for v in $(docker volume ls --format '{{.Name}}' | grep -E "$VOL_RE" | grep -vE "$ODOO_RE"); do
    docker volume rm "$v" >/dev/null 2>&1 && log_success "volume removed: $v"
done
for n in $(docker network ls --format '{{.Name}}' | grep -E "$NET_RE" | grep -vE "$ODOO_RE"); do
    docker network rm "$n" >/dev/null 2>&1 && log_success "network removed: $n"
done
docker rmi -f $(docker images --format '{{.Repository}}:{{.Tag}}@@{{.ID}}' \
    | grep -E "$IMG_RE" | grep -vE "$ODOO_RE" | sed 's/.*@@//' | sort -u) >/dev/null 2>&1
log_success "images removed"

echo
REMAIN=$(docker ps -a --format '{{.Names}}' | grep -E "$CTR_RE" | grep -cvE "$ODOO_RE" || true)
[ "${REMAIN:-0}" = 0 ] && log_success "dev-box runtime purge complete (code + odoo + backups intact)" \
    || log_warn "$REMAIN container(s) still present — rerun or inspect"
log_info "isle-mesh DEB layer (if installed) is a separate route: sudo isle uninstall --everything"