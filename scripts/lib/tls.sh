#!/bin/bash
# tls.sh — ONE place that decides how `pol` verifies TLS (ruling 2026-11-07, relayed by pol-core):
#   default      verified against the system trust store (an isle's root is installed by `isle trust`);
#   POL_TLS_CA   a PEM file to trust INSTEAD (self-signed dev / staging targets): curl --cacert;
#   POL_TLS_INSECURE=1   an explicit, announced bypass for lightweight non-isle settings: curl -k plus a
#                [WARN] on stderr on EVERY call, so a bypass is never silent and never the default.
# There is no other spelling of -k in the CLI's own curl calls (tls-selftest.sh audits the tree).
#
#   source "$SCRIPT_DIR/lib/tls.sh"
#   pol_tls_flags          -> the curl arguments for the current knobs (nothing, --cacert FILE, or -k)
#   pol_curl ARGS...       -> curl $(pol_tls_flags) ARGS...   (a drop-in for the old `curl -sk …` sites:
#                             every other flag, the output handling and the exit status are untouched)
[ "$(type -t pol_tls_flags)" = function ] && return 0 2>/dev/null

pol_tls_mode() {
    case "${POL_TLS_INSECURE:-}" in 1|true|yes|on) echo insecure; return ;; esac
    [ -n "${POL_TLS_CA:-}" ] && { echo cacert; return; }
    echo verified
}

# pol_tls_flags — prints the curl flags, one per line (use: mapfile -t F < <(pol_tls_flags)); exit 2 in
# words when POL_TLS_CA names a file that is not there (a wrong path must not fall through to anything).
pol_tls_flags() {
    case "$(pol_tls_mode)" in
        insecure) printf -- '-k\n' ;;
        cacert)
            [ -r "$POL_TLS_CA" ] || { echo "[FAIL] POL_TLS_CA=$POL_TLS_CA is not a readable PEM file" >&2; return 2; }
            printf -- '--cacert\n%s\n' "$POL_TLS_CA" ;;
    esac
    return 0
}

pol_tls_warn() { echo "[WARN] TLS verification OFF (POL_TLS_INSECURE=1): ${1:-curl}" >&2; }

pol_curl() {
    case "$(pol_tls_mode)" in
        insecure) pol_tls_warn "$(printf '%s\n' "$@" | grep -m1 '^http' || true)"; curl -k "$@" ;;
        cacert)   [ -r "$POL_TLS_CA" ] || { echo "[FAIL] POL_TLS_CA=$POL_TLS_CA is not a readable PEM file" >&2; return 2; }
                  curl --cacert "$POL_TLS_CA" "$@" ;;
        *)        curl "$@" ;;
    esac
}
