#!/bin/bash
# tls.sh — ONE place that decides how `pol` verifies TLS (user ruling 2026-11-07, relayed by pol-core; Isle review 2026-11-07):
#   default              verified against the system trust store (an isle's root is installed by `isle trust`);
#   POL_TLS_CA=<pem>     a PEM file to trust INSTEAD (self-signed / private deployments): curl --cacert. This is the
#                        VERIFYING answer to a self-signed target; prefer it over the bypass.
#   POL_TLS_INSECURE=1   an explicit, announced bypass for intended non-isle lightweight / dev settings: curl -k, plus
#                        a [WARN] once when the CLI starts and on every call, written to the CLI's ORIGINAL stderr
#                        (saved when this file is sourced), so a script's own `2>/dev/null` around one call never
#                        hides it. A caller that discards the CLI's stderr as a whole discards the notice too.
#   Both set             POL_TLS_CA wins (the safer explicit choice) and the ignored bypass is said once.
#   Aliases              POLARI_INSECURE=1 and the older `--insecure` flags set POL_TLS_INSECURE=1 (one knob, one name).
# The python side (lib/pol_tls.py) reads the same two names. tls-selftest.sh audits the tree: the only curl -k left
# are three DISCLOSED EXCEPTIONS (deploy.sh bootstrap in a remote ssh string, dev.sh remote probe, the standalone
# prod-agent.sh), tracked individually; they are NOT instances of this policy.
#
#   source "$SCRIPT_DIR/lib/tls.sh"
#   pol_tls_mode           -> verified | cacert | insecure
#   pol_tls_flags          -> the curl arguments for the current knobs, one per line (nothing, --cacert FILE, or -k)
#   pol_curl ARGS...       -> curl <flags> ARGS...   (a drop-in for the old `curl -sk …` sites: every other flag, the
#                             output handling and the exit status are untouched)
#   lib/pol-curl           -> the same as an EXECUTABLE, for external executors (`timeout 30 lib/pol-curl …`), which
#                             exec a file, not a shell function
[ "$(type -t pol_tls_flags)" = function ] && return 0 2>/dev/null

# the alias: the older name / flag means the new knob
case "${POLARI_INSECURE:-}" in 1|true|yes|on) : "${POL_TLS_INSECURE:=1}"; export POL_TLS_INSECURE ;; esac

# the CLI's original stderr, kept open so the notice survives a call site's own `2>/dev/null`
# (bash >= 4.1: exec {var}>&2 opens a new fd on the current stderr and leaves fd 2 itself untouched)
if [ -z "${POL_TLS_ERRFD:-}" ]; then { exec {POL_TLS_ERRFD}>&2; } || POL_TLS_ERRFD=2; export POL_TLS_ERRFD; fi

pol_tls_mode() {
    [ -n "${POL_TLS_CA:-}" ] && { echo cacert; return; }
    case "${POL_TLS_INSECURE:-}" in 1|true|yes|on) echo insecure; return ;; esac
    echo verified
}

pol_tls_say() { printf '%s\n' "$*" >&"$POL_TLS_ERRFD" 2>/dev/null || printf '%s\n' "$*" >&2; }
pol_tls_warn() { pol_tls_say "[WARN] TLS verification OFF (POL_TLS_INSECURE=1): ${1:-curl}"; }

# said once per CLI process, at source time, whatever the call sites do with their stderr
case "$(pol_tls_mode)" in
    insecure) pol_tls_say "[WARN] TLS verification OFF for this pol run (POL_TLS_INSECURE=1): every HTTPS call below is unverified" ;;
    cacert)   case "${POL_TLS_INSECURE:-}" in 1|true|yes|on) pol_tls_say "[WARN] POL_TLS_INSECURE ignored: POL_TLS_CA=$POL_TLS_CA is set and verification against it wins" ;; esac ;;
esac

# pol_tls_flags — exit 2 in words when POL_TLS_CA names a file that is not there (a wrong path must not fall through).
pol_tls_flags() {
    case "$(pol_tls_mode)" in
        insecure) printf -- '-k\n' ;;
        cacert)
            [ -r "$POL_TLS_CA" ] || { pol_tls_say "[FAIL] POL_TLS_CA=$POL_TLS_CA is not a readable PEM file"; return 2; }
            printf -- '--cacert\n%s\n' "$POL_TLS_CA" ;;
    esac
    return 0
}

pol_curl() {
    case "$(pol_tls_mode)" in
        insecure) pol_tls_warn "$(printf '%s\n' "$@" | grep -m1 '^http' || true)"; curl -k "$@" ;;
        cacert)   [ -r "$POL_TLS_CA" ] || { pol_tls_say "[FAIL] POL_TLS_CA=$POL_TLS_CA is not a readable PEM file"; return 2; }
                  curl --cacert "$POL_TLS_CA" "$@" ;;
        *)        curl "$@" ;;
    esac
}
