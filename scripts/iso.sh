#!/bin/bash
# iso.sh — `pol iso`: get Polari and Ubuntu onto a new computer (ISO plan §P). The CLI is the substance; the pages wrap it.
#   pol iso kit [<dir>] [--from <core>]                     the probe kit (README.html + Windows/Mac/Linux launchers) unpacked into <dir> (a stick root)
#   pol iso probe <report.json> [--from <core>]             post a probe report → the derived verdict + suggested role
#   pol iso probes [--from <core>]                          every probed computer
#   pol iso bases [--from <core>] | fetch-base <name>       the Ubuntu bases; cache one (a 2–3 GB download + the kernel table)
#   pol iso preview --role R --shape S [...]                the autoinstall a set of choices renders to (no build)
#   pol iso build --role core|member|hardware|access|server [--shape detect|desktop|headless] [--base <name>] [--posture production|dev]
#                 [--look preset] [--encryption] [--secure-boot off] [--hostname H] [--target <probe hash>] [--join-core A] [--fingerprint F]
#                 [--ssh-key "<pubkey>"] [--apps a,b] [--wait]
#   pol iso status <build id> | fetch <build id> -o file.iso   the build; the image (sha256 verified)
#   pol iso ventoy /dev/sdX                                 make a stick a Ventoy stick (his decision D-P1) — erases it; needs sudo
# --from <core url> (default $POLARI_API or http://127.0.0.1:3300); --insecure for a self-signed home core.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD=${1:-help}; shift || true
FROM="${POLARI_API:-http://127.0.0.1:3300}"; INSECURE="${POLARI_INSECURE:-0}"; ARGS=()
while [ $# -gt 0 ]; do case "$1" in --from|--api) FROM="$2"; shift 2 ;; --insecure) INSECURE=1; shift ;; *) ARGS+=("$1"); shift ;; esac; done
set -- "${ARGS[@]+"${ARGS[@]}"}"
FROM=${FROM%/}
py() { POLARI_ISO_FROM="$FROM" POLARI_INSECURE="$INSECURE" python3 "$SCRIPT_DIR/lib/iso_cli.py" "$@"; }
case "$CMD" in
    kit)         py kit "$@" ;;
    probe)       py probe "$@" ;;
    probes)      py probes "$@" ;;
    bases)       py bases "$@" ;;
    fetch-base)  py fetch-base "$@" ;;
    preview)     py preview "$@" ;;
    build)       py build "$@" ;;
    status)      py status "$@" ;;
    fetch)       py fetch "$@" ;;
    ventoy)      py ventoy "$@" ;;
    help|*)      sed -n '2,13p' "$0" ;;
esac
