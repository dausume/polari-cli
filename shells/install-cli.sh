#!/bin/bash
# Dev install: symlink the LIVE CHECKOUT's index.js as `pol` — edits to the
# checkout take effect immediately (isle-mesh dev-install route).
#
#   ./shells/install-cli.sh          install
#   ./shells/install-cli.sh remove   uninstall
set -e
SHELLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="$(dirname "$SHELLS_DIR")"
source "$SHELLS_DIR/cli-paths.sh"

command -v node >/dev/null 2>&1 || { echo "pol needs node on PATH"; exit 1; }

case "${1:-install}" in
    install) link_pol "$CLI_DIR/index.js"; echo "Try: pol help" ;;
    remove|uninstall) unlink_pol ;;
    *) echo "usage: $0 [install|remove]"; exit 1 ;;
esac
