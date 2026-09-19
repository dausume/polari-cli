#!/bin/bash
# lib/tui.sh — the dialog helpers every `pol` walkthrough shares: whiptail
# when there is a terminal AND whiptail is installed, plain numbered
# prompts otherwise. Lifted out of prod.sh (ci-7b) so `pol jenkins setup`
# and any future guide use ONE implementation.
#
#   tui_available            → 0 when whiptail dialogs are in use
#   tui_menu   title text default item1 desc1 …   → the chosen item
#   tui_input  title text default                 → the value
#   tui_yesno  title text [yes|no]                → 0 yes / 1 no (default yes)
#   tui_msg    title text
#   tui_password title text                       → the value, NEVER echoed
#
# POL_TUI=plain forces the plain prompts (the selftest and any log-scraping
# caller set it). Everything a helper draws goes to stderr, so the VALUE a
# helper returns is the only thing on stdout.
#
# SOURCED, not executed. Sourcing must not change the caller's shell
# options: `set -e` in a caller is the caller's business.

if [ -z "${POL_TUI_SH:-}" ]; then
POL_TUI_SH=1

HAS_TUI=0
if [ "${POL_TUI:-}" != plain ] && [ -t 0 ] && [ -t 1 ] && command -v whiptail >/dev/null 2>&1; then
    HAS_TUI=1
fi
tui_available() { [ "$HAS_TUI" = 1 ]; }

# read a line from the terminal itself when there is one (so a helper still
# works when the caller's stdout is a tee or a pipe)
# never fails: EOF or no terminal leaves the variable empty and the caller
# falls back to its default (a caller under `set -e` must not die on EOF).
_tui_read() {
    if [ -e /dev/tty ] && { : </dev/tty; } 2>/dev/null; then read -r "$@" </dev/tty || true
    else read -r "$@" || true; fi
}

tui_menu() {   # title text default item1 desc1 item2 desc2 … → chosen item
    local title=$1 text=$2 default=$3; shift 3
    if [ "$HAS_TUI" = 1 ]; then
        whiptail --title "$title" --default-item "$default" --menu "$text" 20 78 8 "$@" 3>&1 1>&2 2>&3
        return
    fi
    local items=("$@") i=1 n=1 c=""
    { echo; echo "== $title"; echo "$text"; } >&2
    while [ $i -le $# ]; do
        printf '  %d) %-8s %s\n' "$n" "${items[$((i-1))]}" "${items[$i]}" >&2
        i=$((i+2)); n=$((n+1))
    done
    printf 'choice (number or name) [%s]: ' "$default" >&2
    _tui_read c
    [ -n "$c" ] || { printf '%s' "$default"; return 0; }
    case "$c" in
        ''|*[!0-9]*) printf '%s' "$c" ;;                       # a name, as typed
        *) i=$(( (c - 1) * 2 )); [ "$i" -ge 0 ] && [ "$i" -lt ${#items[@]} ] \
               && printf '%s' "${items[$i]}" || printf '%s' "$default" ;;
    esac
}

tui_input() {  # title text default → value
    if [ "$HAS_TUI" = 1 ]; then whiptail --title "$1" --inputbox "$2" 12 78 "$3" 3>&1 1>&2 2>&3; return; fi
    local c=""; { echo; echo "== $1"; echo "$2"; } >&2; printf '[%s]: ' "$3" >&2
    _tui_read c; printf '%s' "${c:-$3}"
}

tui_yesno() {  # title text [yes|no] → 0 yes / 1 no   (default yes)
    local def="${3:-yes}"
    if [ "$HAS_TUI" = 1 ]; then
        [ "$def" = no ] && whiptail --title "$1" --defaultno --yesno "$2" 16 78 \
                        || whiptail --title "$1" --yesno "$2" 16 78
        return
    fi
    local c=""; { echo; echo "== $1"; echo "$2"; } >&2
    printf '%s ' "$([ "$def" = no ] && echo '[y/N]:' || echo '[Y/n]:')" >&2
    _tui_read c; c="${c,,}"
    [ -n "$c" ] || c="$def"
    case "$c" in y|yes) return 0 ;; *) return 1 ;; esac
}

tui_checklist() {  # title text item1 desc1 item2 desc2 … → the chosen items, space-separated
    local title=$1 text=$2; shift 2
    if [ "$HAS_TUI" = 1 ]; then
        local args=() i=1 items=("$@")
        while [ $i -le $# ]; do args+=("${items[$((i-1))]}" "${items[$i]}" off); i=$((i+2)); done
        whiptail --title "$title" --checklist "$text" 22 78 12 "${args[@]}" 3>&1 1>&2 2>&3 | tr -d '"'
        return
    fi
    local items=("$@") i=1 n=1 c="" out="" tok
    { echo; echo "== $title"; echo "$text"; } >&2
    while [ $i -le $# ]; do printf '  %2d) %-22s %s\n' "$n" "${items[$((i-1))]}" "${items[$i]}" >&2; i=$((i+2)); n=$((n+1)); done
    printf 'numbers and/or names, space- or comma-separated (Enter alone = none): ' >&2
    _tui_read c
    for tok in ${c//,/ }; do
        case "$tok" in
            ''|*[!0-9]*) out="$out $tok" ;;
            *) i=$(( (tok - 1) * 2 )); [ "$i" -ge 0 ] && [ "$i" -lt ${#items[@]} ] && out="$out ${items[$i]}" ;;
        esac
    done
    printf '%s' "${out# }"
}

tui_msg() {
    if [ "$HAS_TUI" = 1 ]; then whiptail --title "$1" --msgbox "$2" 20 78
    else { echo; echo "== $1"; echo "$2"; } >&2; fi
}

tui_password() {  # title text → the value on stdout; never echoed, never logged
    if [ "$HAS_TUI" = 1 ]; then whiptail --title "$1" --passwordbox "$2" 12 78 3>&1 1>&2 2>&3; return; fi
    local v=""; { echo; echo "== $1"; echo "$2"; } >&2
    printf 'value (not echoed, Enter alone to skip): ' >&2
    if [ -e /dev/tty ] && { : </dev/tty; } 2>/dev/null; then read -rs v </dev/tty || true; else read -rs v || true; fi
    echo >&2; printf '%s' "$v"
}

fi
