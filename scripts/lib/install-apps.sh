#!/bin/bash
# install-apps.sh — install what is on this Polari stick, OFFLINE, installing only what this computer lacks.
# Copied onto the stick by `pol apps usb write`; run there:
#   sudo bash install-apps.sh                 the platform (if on the stick and missing here), then EVERY app
#   sudo bash install-apps.sh gears terms     only these apps (the platform still goes first if missing)
#   sudo bash install-apps.sh --no-platform   apps only, never the platform
# Nothing is installed twice: a package dpkg already knows is skipped; the libraries inside each app are installed
# by the instance from the carried wheels with pip --no-index, which skips what is already present.
set -u
cd "$(dirname "$0")" || exit 1
platform=yes; want=""
for a in "$@"; do case "$a" in --no-platform) platform=no ;; *) want="$want $a" ;; esac; done
[ "$(id -u)" = 0 ] || { echo "run with sudo (installing packages needs root)"; exit 1; }
if [ "$platform" = yes ]; then
    inst=$(ls polari-complete_*.deb 2>/dev/null | head -1)
    if [ -n "$inst" ]; then
        if dpkg -s polari-complete >/dev/null 2>&1; then echo "platform: polari-complete already present ($(dpkg-query -W -f='${Version}' polari-complete)) — skipped"
        else echo "installing the platform from the stick: $inst"; apt-get install -y "./$inst" || { echo "!! the platform installer failed"; exit 1; }; fi
    else
        echo "platform: no installer on this stick (apps only)"
    fi
else
    echo "platform: skipped (--no-platform)"
fi
n=0; s=0; f=0
for deb in polari-app-*.deb; do
    [ -e "$deb" ] || continue
    pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null) || { echo "!! $deb is not a valid deb"; f=$((f+1)); continue; }
    mod=${pkg#polari-app-}; mod=${mod%-offline}
    if [ -n "$want" ] && ! echo " $want " | grep -q " $mod "; then continue; fi
    if dpkg -s "$pkg" >/dev/null 2>&1; then echo "$pkg: already present — skipped"; s=$((s+1)); continue; fi
    echo "installing $pkg from the stick (offline: its libraries travel inside it; ones already present are skipped)"
    if apt-get install -y "./$deb"; then n=$((n+1)); else echo "!! $pkg failed"; f=$((f+1)); fi
done
echo "done: $n installed, $s already present, $f failed — apps are staged under /var/lib/polari/apps; the instance admits them (Isle App Store, or: sudo isle app install)"
[ "$f" = 0 ]
