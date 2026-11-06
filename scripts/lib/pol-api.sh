#!/bin/bash
# pol-api.sh — ONE transport for the Polari-side verbs (cis arc, COHERENT_ISLE_WORK_SPLIT.md):
# a Polari backend's HTTP API, never root, never the isle.
#
#   source "$SCRIPT_DIR/lib/pol-api.sh"
#   pol_api GET  /api/board/bench-solutions            -> body on stdout
#   pol_api POST /api/cmod/bench-topology/x/apply-spec '{"spec":"y"}'
#   pol_api GET  /api/.../vcd '' --raw                 -> text body, no JSON judgement
#
# Base URL, in order: $POL_API (set by the caller from --api), $POLARI_API, else the
# LOCAL docker backend (core-api.sh: prf-backend | prf-isle-backend | polari-node_backend)
# exactly as the older pol verbs do today.
#
# Exit codes (agreed with pol-core 2026-11-06, shared by pol bench / pol plans / pol topology --api):
#   0  ok
#   1  REFUSED — the backend answered and said no (HTTP >= 400 or {"ok": false}); its words on stderr,
#      its body still on stdout so --json callers can read it
#   2  UNREACHABLE or usage — no backend answered (curl failed, no local container, bad URL)
#
# TLS is verified against the system trust store. There is NO -k here on purpose (the isle root
# is installed by `isle trust`; a per-host exception or -k is never the accepted workflow).
# HTTP/1.1 is forced: the isle proxies have shown HTTP/2 framing errors (item 15).

pol_api_base() { printf '%s' "${POL_API:-${POLARI_API:-}}"; }

# pol_api_enc STRING — one URL path segment (bench names carry ':' and run names '#').
pol_api_enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# _pol_api_judge BODYFILE — exit 1 when the body says {"ok": false}, else 0.
_pol_api_judge() {
    python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)            # not JSON (text doors): nothing to judge
if isinstance(d, dict) and d.get('ok') is False:
    sys.stderr.write('[REFUSED] ' + str(d.get('error') or d.get('why') or d.get('words') or d) + '\n')
    sys.exit(1)
PY
}

pol_api() {
    local method=$1 path=$2 body=${3:-} raw=${4:-}
    local base tmp code rc
    base=$(pol_api_base)
    tmp=$(mktemp)
    if [ -n "$base" ]; then
        case "$base" in http://*|https://*) ;; *) echo "[FAIL] --api must be an http(s) URL, got: $base" >&2; rm -f "$tmp"; return 2 ;; esac
        if [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
            code=$(printf '%s' "${body:-{\}}" | curl -sS --http1.1 --max-time "${POL_API_TIMEOUT:-120}" -X "$method" \
                   -H 'Content-Type: application/json' --data-binary @- -o "$tmp" -w '%{http_code}' "$base$path" 2>"$tmp.err") || rc=$?
        else
            code=$(curl -sS --http1.1 --max-time "${POL_API_TIMEOUT:-120}" -o "$tmp" -w '%{http_code}' "$base$path" 2>"$tmp.err") || rc=$?
        fi
        if [ -n "${rc:-}" ]; then
            echo "[FAIL] $base unreachable: $(tr -d '\n' < "$tmp.err")" >&2; rm -f "$tmp" "$tmp.err"; return 2
        fi
        rm -f "$tmp.err"
    else
        # shellcheck source=core-api.sh
        source "$(dirname "${BASH_SOURCE[0]}")/core-api.sh"
        if ! POLARI_CORE_URL='' core_api "$method" "$path" <<<"${body:-{\}}" > "$tmp"; then
            echo "[FAIL] no backend: set --api https://api.<name>.isle (or POL_API), or run beside a local Polari backend container" >&2
            rm -f "$tmp"; return 2
        fi
        code=200
    fi
    cat "$tmp"
    if [ "$raw" = "--raw" ]; then rm -f "$tmp"; [ "$code" -lt 400 ] && return 0 || return 1; fi
    if [ "$code" -ge 400 ]; then
        _pol_api_judge "$tmp" 2>/dev/null || true
        python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1])); w=d.get("error") or d.get("title") or d.get("description") or d
except Exception: w=open(sys.argv[1]).read()[:300]
sys.stderr.write("[REFUSED] HTTP %s: %s\n" % (sys.argv[2], w))' "$tmp" "$code"
        rm -f "$tmp"; return 1
    fi
    _pol_api_judge "$tmp"; rc=$?
    rm -f "$tmp"; return $rc
}

# pol_api_flags "$@" — strip the shared flags; leaves the rest in ARGS, sets POL_API / JSON.
#   --api URL   --json
pol_api_flags() {
    JSON=${JSON:-0}; ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --api) [ -n "${2:-}" ] || { echo "[FAIL] --api needs a URL" >&2; return 2; }; export POL_API="$2"; shift 2 ;;
            --api=*) export POL_API="${1#--api=}"; shift ;;
            --json) JSON=1; shift ;;
            *) ARGS+=("$1"); shift ;;
        esac
    done
    return 0
}

# pretty 'python' — read the JSON body on stdin as d and run the snippet (same idiom as topology.sh).
pretty() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }
