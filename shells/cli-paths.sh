#!/bin/bash
# SINGLE SOURCE OF TRUTH for where the pol CLI lives on a machine.
# (isle-mesh cli-paths.sh idiom: every install/uninstall route converges
# on ONE symlink so there is never a duplicate `pol` on PATH.)
#
# Source this; don't execute it.

# Preferred system-wide location; falls back to ~/.local/bin (on PATH for
# normal user setups) when /usr/local/bin isn't writable and passwordless
# sudo is unavailable — keeps installs working headless over ssh.
if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
    POL_CLI_LINK="/usr/local/bin/pol"
else
    POL_CLI_LINK="$HOME/.local/bin/pol"
    mkdir -p "$HOME/.local/bin"
fi

# Elevate only when the target path isn't user-writable (works headless
# over ssh with passwordless-sudo absent — fails loudly instead of
# prompting invisibly).
_pol_priv() {
    local target_dir="$1"; shift
    if [ -w "$target_dir" ]; then
        "$@"
    else
        sudo -n "$@" 2>/dev/null || {
            echo "Need privileges for $target_dir — rerun with: sudo $*" >&2
            return 1
        }
    fi
}

link_pol() {
    local index_js="$1"
    [ -f "$index_js" ] || { echo "link_pol: $index_js not found" >&2; return 1; }
    chmod +x "$index_js"
    local cur
    cur="$(readlink -f "$POL_CLI_LINK" 2>/dev/null || true)"
    if [ -n "$cur" ] && [ "$cur" != "$(readlink -f "$index_js")" ]; then
        echo "pol already installed at $POL_CLI_LINK -> $cur"
        echo "Re-linking to $index_js"
    fi
    _pol_priv "$(dirname "$POL_CLI_LINK")" ln -sf "$(readlink -f "$index_js")" "$POL_CLI_LINK"
    echo "pol -> $(readlink -f "$POL_CLI_LINK")"
}

unlink_pol() {
    [ -L "$POL_CLI_LINK" ] || [ -f "$POL_CLI_LINK" ] || { echo "pol not installed"; return 0; }
    _pol_priv "$(dirname "$POL_CLI_LINK")" rm -f "$POL_CLI_LINK"
    echo "removed $POL_CLI_LINK"
}
