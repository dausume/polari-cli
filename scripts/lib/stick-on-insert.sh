#!/bin/bash
# stick-on-insert.sh — the prompt a Polari app stick raises when it is plugged in (his ask 2026-09-13).
# Self-contained: works on a computer with NO Polari yet (the desktop's own media prompt runs autorun.sh, which
# execs this), and Polari's watcher runs it once the platform is installed.
#   Install       → pkexec/sudo install-apps.sh, then --verify; "confirmed finished" only when every package is present
#   Not now       → nothing happens; the stick stays as it is
#   Wipe the stick→ wipe-stick.sh (the whole drive becomes an empty FAT drive) after a second, named confirmation
# After a CONFIRMED FINISHED install the stick's after_install policy applies: ask (default) | wipe | keep.
# Scripted use: --answer install|no|wipe [--after keep|wipe|ask]  (tests, the isle store, the watcher)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE" || exit 1
MOUNT=$(dirname "$HERE")
ANSWER=""; AFTER=""
while [ $# -gt 0 ]; do case "$1" in --answer) ANSWER="$2"; shift 2 ;; --after) AFTER="$2"; shift 2 ;; *) shift ;; esac; done
have() { command -v "$1" >/dev/null 2>&1; }
gui() { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && { have zenity || have kdialog; }; }
field() { python3 -c "import json,sys; i=json.load(open('index.json')); print($1)" 2>/dev/null; }
N=$(field "len([a for a in i['apps'] if 'file' in a])"); N=${N:-0}
PLAT=$(field "', '.join(x['file'] for x in i.get('installers', []))")
POLICY=${AFTER:-$(field "i.get('after_install', 'ask')")}; POLICY=${POLICY:-ask}
DEV=$(findmnt -no SOURCE "$MOUNT" 2>/dev/null); SIZE=$(lsblk -dno SIZE "$DEV" 2>/dev/null)
TITLE="Polari app stick"
TEXT="This stick carries $N app(s)${PLAT:+ and the platform ($PLAT)}, ready to install with no internet.
Nothing already on this computer is installed twice.

Install them now?"

# ---- the three-way question ---------------------------------------------------------------------------------
ask3() {   # prints install | no | wipe
    if [ -n "$ANSWER" ]; then echo "$ANSWER"; return; fi
    if gui && have zenity; then
        out=$(zenity --question --title="$TITLE" --text="$TEXT" --ok-label="Install" --cancel-label="Not now" --extra-button="Wipe the stick" 2>/dev/null); rc=$?
        [ "$out" = "Wipe the stick" ] && { echo wipe; return; }; [ $rc = 0 ] && echo install || echo no; return
    fi
    if gui && have kdialog; then
        kdialog --title "$TITLE" --yesnocancel "$TEXT" --yes-label "Install" --no-label "Not now" --cancel-label "Wipe the stick" >/dev/null 2>&1; rc=$?
        case $rc in 0) echo install ;; 1) echo no ;; *) echo wipe ;; esac; return
    fi
    echo "$TEXT" >&2; printf '[i]nstall / [n]ot now / [w]ipe the stick: ' >&2; read -r r
    case "$r" in i*|I*) echo install ;; w*|W*) echo wipe ;; *) echo no ;; esac
}
yes_no() {   # $1 = question; returns 0 for yes
    if [ -n "$ANSWER" ]; then [ "$2" = yes ]; return; fi
    if gui && have zenity; then zenity --question --title="$TITLE" --text="$1" 2>/dev/null; return; fi
    if gui && have kdialog; then kdialog --title "$TITLE" --yesno "$1" >/dev/null 2>&1; return; fi
    printf '%s [y/N]: ' "$1" >&2; read -r r; case "$r" in y*|Y*) return 0 ;; *) return 1 ;; esac
}
say() { if gui && have zenity; then zenity --info --title="$TITLE" --text="$1" 2>/dev/null; elif gui && have kdialog; then kdialog --title "$TITLE" --msgbox "$1" >/dev/null 2>&1; else echo "$1" >&2; fi; }
as_root() { if [ "$(id -u)" = 0 ]; then bash "$@"; elif gui && have pkexec; then pkexec bash "$@"; else sudo bash "$@"; fi; }

do_wipe() {
    yes_no "Wipe the stick $DEV ($SIZE)?
Everything on it is erased and it becomes an empty drive. This cannot be undone." "${1:-no}" || { echo "kept the stick" >&2; return 1; }
    as_root "$HERE/wipe-stick.sh" "$MOUNT" --yes && say "The stick is wiped: an empty drive. You can unplug it."
}

case "$(ask3)" in
    no)   echo "not now — the stick is untouched (run polari-apps/on-insert.sh or 'pol apps usb install' later)" >&2; exit 0 ;;
    wipe) do_wipe "${ANSWER:+yes}"; exit $? ;;
esac
# ---- install, then confirm it finished ----------------------------------------------------------------------
as_root "$HERE/install-apps.sh"; rc=$?
if bash "$HERE/install-apps.sh" --verify >/dev/null 2>&1; then
    echo "install confirmed finished: every package on the stick is present on this computer" >&2
    case "$POLICY" in
        keep) say "Installed. The stick is kept as it is." ;;
        wipe) as_root "$HERE/wipe-stick.sh" "$MOUNT" --yes && say "Installed, and the stick is wiped (its after-install policy). You can unplug it." ;;
        *)    yes_no "Install confirmed finished.
Wipe the stick $DEV ($SIZE) now? It becomes an empty drive." "no" && as_root "$HERE/wipe-stick.sh" "$MOUNT" --yes && say "The stick is wiped. You can unplug it." ;;
    esac
    exit 0
fi
say "The install did not finish (exit $rc). The stick is kept so you can try again: see the terminal output, or run polari-apps/install-apps.sh."
exit 1
