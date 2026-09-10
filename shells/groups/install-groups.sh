#!/bin/bash
# install-groups.sh <remote|app> <user> — create the group, install its sudoers
# drop-in (validated with visudo before it lands), add the user. Needs root ONCE
# (the point: after this, `pol deploy` never needs a password on this machine).
#   sudo bash install-groups.sh remote alice     ssh + swarm + AI-assisted setup
#   sudo bash install-groups.sh app alice        the app-setup route (store doors)
#   sudo bash install-groups.sh remove <remote|app>
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0 $*" >&2; exit 1; }
KIND=${1:?remote|app|remove}
if [ "$KIND" = remove ]; then G=polari-${2:?remote|app}; rm -f "/etc/sudoers.d/$G"; groupdel "$G" 2>/dev/null || true; echo "removed $G"; exit 0; fi
USER_NAME=${2:?user}; G="polari-$KIND"; SRC="$HERE/$G.sudoers"; DST="/etc/sudoers.d/$G"
[ -f "$SRC" ] || { echo "no such group file $SRC" >&2; exit 1; }
getent group "$G" >/dev/null || groupadd --system "$G"
install -m 0440 -o root -g root "$SRC" "$DST.tmp"
visudo -cf "$DST.tmp" >/dev/null || { rm -f "$DST.tmp"; echo "sudoers file failed validation — not installed" >&2; exit 1; }
mv "$DST.tmp" "$DST"
usermod -aG "$G" "$USER_NAME"
[ "$KIND" = remote ] && { getent group docker >/dev/null && usermod -aG docker "$USER_NAME" || true; }
echo "group $G installed; $USER_NAME added (log out and in for the group to apply)"
