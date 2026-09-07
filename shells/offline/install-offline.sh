#!/bin/bash
# install-offline.sh — install Polari from an OFFLINE medium (the
# `offline-build/<ver>/` tree; AI-Notes/guides/OFFLINE_BUILD_TEMPLATE.md
# §3). Run as root FROM THE MEDIUM: sudo bash <medium>/scripts/install-offline.sh
#
# The no-fallback rule (OFFLINE_INSTALL_PLAN.md §C): every part comes
# from a SECTION of this medium or the step refuses naming the section.
# This script never calls apt against the internet, never `docker pull`s,
# never curls anything that is not 127.0.0.1 / .isle.
#
#   --core-install      run `isle core-install` at the end (interactive)
#   --skip-images       do not docker-load images/ (already loaded)
#   --skip-apt          do not touch apt (closure already installed)
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL="$(cd "$HERE/.." && pwd)"
CORE_INSTALL=0; SKIP_IMAGES=0; SKIP_APT=0
while [ $# -gt 0 ]; do case "$1" in
    --core-install) CORE_INSTALL=1; shift ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --skip-apt) SKIP_APT=1; shift ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
esac; done
G="\033[0;32m"; R="\033[0;31m"; Y="\033[1;33m"; C="\033[0;36m"; N="\033[0m"
ok(){ echo -e "${G}[ OK ]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }
step(){ echo; echo -e "${C}==> $*${N}"; }
refuse(){ echo -e "${R}[REFUSED]${N} offline: $*" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

step "0/6 verify the medium ($POOL)"
bash "$HERE/verify-offline.sh" "$POOL" || refuse "medium failed verification — nothing installed"
VER=$(python3 -c "import json;print(json.load(open('$POOL/manifest.json'))['polari'])")
TARGET=$(python3 -c "import json;print(json.load(open('$POOL/manifest.json')).get('target',''))")
HOST_REL="ubuntu-$(. /etc/os-release && echo "$VERSION_ID")"
[ "$TARGET" = "$HOST_REL" ] || warn "medium built for $TARGET, this host is $HOST_REL — the apt section may not fit"
ok "Polari $VER ($TARGET), sections verified"

step "1/6 install mode → offline (the one file every later step reads)"
mkdir -p /etc/polari
printf 'offline\n' > /etc/polari/install-mode
printf '%s\n' "$POOL" > /etc/polari/offline-source
ok "/etc/polari/install-mode=offline, offline-source=$POOL"

step "2/6 apt section (distro closure from the medium, file: source only)"
APT_LIST=/etc/apt/sources.list.d/polari-offline.list
APT_OPTS="-o Dir::Etc::SourceList=$APT_LIST -o Dir::Etc::SourceParts=/dev/null -o Acquire::Retries=0"
if [ "$SKIP_APT" = 1 ]; then
    warn "apt skipped (--skip-apt)"
elif [ -f "$POOL/apt/EMPTY" ]; then
    warn "apt section EMPTY: $(cat "$POOL/apt/EMPTY")"
else
    echo "deb [trusted=yes] file:$POOL/apt ./" > "$APT_LIST"
    # ONLY our file: source is consulted — the system's internet
    # sources are not read (no network, no timeouts, no fallback).
    apt-get $APT_OPTS update -qq 2>&1 | grep -v '^W:' || true
    WANT="socat dpkg-dev avahi-daemon avahi-utils apt-utils gnupg"
    command -v docker >/dev/null 2>&1 || WANT="$WANT docker.io docker-compose-v2 containerd runc"
    docker compose version >/dev/null 2>&1 || WANT="$WANT docker-compose-v2"
    NEED=""
    for p in $WANT; do dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"; done
    if [ -n "$NEED" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS install -y --no-install-recommends $NEED \
            || refuse "a distro package is not in the medium's apt/ section (needed:$NEED) — add it to the bundle (build-offline-medium.sh --closure) or install the online package"
        ok "installed from the medium:$NEED"
    else
        ok "distro closure already satisfied"
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
fi

step "3/6 images section (docker load — no pulls, ever)"
if [ "$SKIP_IMAGES" = 1 ]; then
    warn "images skipped (--skip-images)"
elif [ -f "$POOL/images/EMPTY" ]; then
    refuse "images section EMPTY ($(cat "$POOL/images/EMPTY")) — a base install needs prf-backend/prf-frontend/nginx:alpine/isle-sample-app-sample here"
else
    python3 - "$POOL/images/images.json" <<'PY' | while read -r ref file; do
import json, sys
for e in json.load(open(sys.argv[1])):
    print(e['name'] + ':' + e['tag'], e['file'])
PY
        if docker image inspect "$ref" >/dev/null 2>&1; then
            ok "$ref already present"
        else
            docker load -q -i "$POOL/images/$file" >/dev/null && ok "loaded $ref" \
                || refuse "docker load failed for $file (section images/)"
        fi
    done
fi

step "4/6 the platform deb (polari-complete-offline) from debs/"
DEB=$(ls "$POOL"/debs/polari-complete-offline_*.deb 2>/dev/null | sort -V | tail -1 || true)
[ -n "$DEB" ] || refuse "no polari-complete-offline deb in debs/ (section debs/)"
if dpkg -s polari-complete-offline >/dev/null 2>&1; then
    ok "polari-complete-offline already installed ($(dpkg-query -W -f='${Version}' polari-complete-offline))"
else
    if [ "$SKIP_APT" = 1 ] || [ -f "$POOL/apt/EMPTY" ]; then
        dpkg -i "$DEB" || refuse "dpkg -i failed — missing Depends must come from the apt/ section"
    else
        DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS install -y "$DEB" \
            || refuse "the deb's Depends could not be met from the medium's apt/ section"
    fi
    ok "installed $(basename "$DEB")"
fi
# the deb's postinst wrote the same mode file; keep the source path
printf '%s\n' "$POOL" > /etc/polari/offline-source

step "5/6 engines + modules staged for later (nothing goes live here)"
[ -f "$POOL/engines/EMPTY" ] && warn "engines: $(cat "$POOL/engines/EMPTY")" \
    || ok "engines available: $(ls "$POOL/engines" | tr '\n' ' ')"
[ -f "$POOL/modules/EMPTY" ] && warn "modules: $(cat "$POOL/modules/EMPTY")" \
    || ok "module debs: $(ls "$POOL"/modules/*.deb 2>/dev/null | xargs -n1 basename | sed 's/_.*//' | tr '\n' ' ')"
echo "   install one later:  sudo bash $HERE/install-app-offline.sh <module>"

step "6/6 the isle"
if [ "$CORE_INSTALL" = 1 ]; then
    isle core-install
else
    echo "Next (the normal user route): open the Isle App Store → 'Create my own isle'"
    echo "  or in a terminal:  sudo isle core-install"
    echo "Everything it needs is loaded; in offline mode it refuses instead of fetching."
fi
echo
ok "offline install of Polari $VER staged from $POOL (mode file: $(cat /etc/polari/install-mode))"
