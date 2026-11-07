#!/bin/bash
# tls-selftest.sh — lib/tls.sh and every curl site of the CLI (no network; a FAKE curl records its argv):
# default = verified TLS (no -k, no --cacert); POL_TLS_CA=<pem> -> --cacert <pem> (a missing file refuses, exit 2);
# POL_TLS_INSECURE=1 -> -k AND a [WARN] on stderr on every call; the knobs ride through pol_api (pol engines)
# and core_api (POLARI_CORE_URL); a static audit names the only three curl sites still carrying -k.
#   tls-selftest.sh [-v] [--help]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0; case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,6p' "$0"; exit 0 ;; esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad() { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "no …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
no_insecure() { if grep -Eq '(^| )(-[a-zA-Z]*k[a-zA-Z]*|--insecure)( |$)' <<<"$2"; then bad "$1" "no -k / --insecure" "$2"; else ok "$1"; fi; }
BIN="$T/bin"; mkdir -p "$BIN"; LOG="$T/curl.log"
cat > "$BIN/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$LOG"
out=''; args=("\$@"); for ((i=0; i<\${#args[@]}; i++)); do case "\${args[i]}" in -o) out="\${args[i+1]}" ;; --data-binary) [ "\${args[i+1]}" = "@-" ] && cat >/dev/null ;; esac; done
body='{"ok": true, "engines": []}'
[ -n "\$out" ] && printf '%s' "\$body" > "\$out" || printf '%s' "\$body"
case " \$* " in *" -w "*) printf '200' ;; esac
exit 0
SH
chmod +x "$BIN/curl"
CA="$T/ca.pem"; printf -- '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n' > "$CA"
S="$T/suite"; mkdir -p "$S"; touch "$S/setup-polari-security.sh"
# run KNOB... -- CMD...: a subshell with the fake curl first on PATH and only the named knobs set
run() { local -a kv=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do kv+=("$1"); shift; done; shift
        ( env -u POL_TLS_CA -u POL_TLS_INSECURE PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" "${kv[@]}" "$@" ); }
lib() { bash -c "source '$HERE/lib/tls.sh'; $1"; }

# 1. the flags
eq "default: no flags" "" "$(run -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_flags | tr '\n' ' '")"
eq "default: mode verified" "verified" "$(run -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_mode")"
eq "POL_TLS_CA: --cacert FILE" "--cacert $CA " "$(run POL_TLS_CA="$CA" -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_flags | tr '\n' ' '")"
out=$(run POL_TLS_CA="$T/nope.pem" -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_flags" 2>&1); rc=$?
eq  "POL_TLS_CA missing file: exit 2" 2 "$rc"; has "POL_TLS_CA missing file: says so" "not a readable PEM" "$out"
eq "POL_TLS_INSECURE=1: -k" "-k " "$(run POL_TLS_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_flags | tr '\n' ' '")"
eq "POL_TLS_INSECURE=true: -k" "-k " "$(run POL_TLS_INSECURE=true -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_flags | tr '\n' ' '")"
eq "POL_TLS_INSECURE=0: verified" "verified" "$(run POL_TLS_INSECURE=0 -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_mode")"
eq "POL_TLS_INSECURE wins over POL_TLS_CA (announced bypass)" "insecure" "$(run POL_TLS_INSECURE=1 POL_TLS_CA="$CA" -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_mode")"

# 2. pol_curl: argv passthrough and the warning
: > "$LOG"; err=$(run -- bash -c "source '$HERE/lib/tls.sh'; pol_curl -s --max-time 7 -X POST https://x.invalid/p" 2>&1 >/dev/null)
eq  "pol_curl default: argv verbatim, no TLS flag" "-s --max-time 7 -X POST https://x.invalid/p" "$(cat "$LOG")"
eq  "pol_curl default: silent on stderr" "" "$err"
: > "$LOG"; err=$(run POL_TLS_CA="$CA" -- bash -c "source '$HERE/lib/tls.sh'; pol_curl -s https://x.invalid/p" 2>&1 >/dev/null)
eq  "pol_curl POL_TLS_CA: --cacert first, then argv" "--cacert $CA -s https://x.invalid/p" "$(cat "$LOG")"
eq  "pol_curl POL_TLS_CA: silent on stderr" "" "$err"
: > "$LOG"; err=$(run POL_TLS_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'; pol_curl -s https://x.invalid/p" 2>&1 >/dev/null)
eq  "pol_curl POL_TLS_INSECURE: -k then argv" "-k -s https://x.invalid/p" "$(cat "$LOG")"
has "pol_curl POL_TLS_INSECURE: [WARN] names the bypass" "[WARN] TLS verification OFF (POL_TLS_INSECURE=1)" "$err"
has "pol_curl POL_TLS_INSECURE: [WARN] names the URL" "https://x.invalid/p" "$err"
: > "$LOG"; out=$(run POL_TLS_CA="$T/nope.pem" -- bash -c "source '$HERE/lib/tls.sh'; pol_curl -s https://x.invalid/p" 2>&1); rc=$?
eq  "pol_curl with a missing CA file: exit 2, curl never called" "2|" "$rc|$(cat "$LOG")"

# 3. through pol_api (pol engines list --api) and core_api (POLARI_CORE_URL)
API=https://api.fake.invalid
: > "$LOG"; run -- bash "$HERE/engines.sh" list --api $API >/dev/null 2>&1
no_insecure "pol engines list: default verified" "$(cat "$LOG")"; hasnt "pol engines list: default no --cacert" "--cacert" "$(cat "$LOG")"
: > "$LOG"; run POL_TLS_CA="$CA" -- bash "$HERE/engines.sh" list --api $API >/dev/null 2>&1
has "pol engines list POL_TLS_CA: --cacert rides pol_api" "--cacert $CA" "$(cat "$LOG")"; has "… and --http1.1 is kept" "--http1.1" "$(cat "$LOG")"
: > "$LOG"; err=$(run POL_TLS_INSECURE=1 -- bash "$HERE/engines.sh" list --api $API 2>&1 >/dev/null)
has "pol engines list POL_TLS_INSECURE: -k rides pol_api" "-k " "$(cat "$LOG")"; has "… and the [WARN] reaches the user" "[WARN] TLS verification OFF" "$err"
: > "$LOG"; out=$(run POL_TLS_CA="$T/nope.pem" -- bash "$HERE/engines.sh" list --api $API 2>&1); rc=$?
eq  "pol engines list with a missing CA file: exit 2, curl never called" "2|" "$rc|$(cat "$LOG")"; has "… and it says which file" "nope.pem is not a readable PEM" "$out"
: > "$LOG"; run POLARI_CORE_URL=$API -- bash -c "source '$HERE/lib/core-api.sh'; core_api GET /api/x" >/dev/null 2>&1
no_insecure "core_api default: verified" "$(cat "$LOG")"; has "core_api: url intact" "$API/api/x" "$(cat "$LOG")"
: > "$LOG"; run POLARI_CORE_URL=$API POL_TLS_CA="$CA" -- bash -c "source '$HERE/lib/core-api.sh'; echo '{}' | core_api POST /api/x" >/dev/null 2>&1
has "core_api POST POL_TLS_CA: --cacert" "--cacert $CA" "$(cat "$LOG")"; has "core_api POST: method and body flag intact" "-X POST -H Content-Type: application/json --data-binary @-" "$(cat "$LOG")"

# 4. static audit of the tree: pol_curl callers source tls.sh (directly or via core-api.sh / pol-api.sh), and the
#    only curl sites still carrying -k are the three named below (two run INSIDE a remote ssh string on a host
#    that has no lib; one is the standalone prod agent).
ALLOWED='scripts/deploy.sh:.*ssh|scripts/deploy.sh:.*"curl -fsSk -o /tmp/isle-bootstrap.sh|scripts/dev.sh:.*'"'"'curl -sk -o /dev/null|scripts/prod-agent.sh:'
left=$(cd "$HERE/.." && grep -rn -- 'curl[^|]*\(-[a-zA-Z]*k\b\|--insecure\)' scripts | grep -v 'selftest\|scripts/lib/tls.sh' | grep -Ev "$ALLOWED" || true)
eq  "static: no curl -k outside the three named sites" "" "$left"
eq  "static: the three named sites are exactly three" 3 "$(cd "$HERE/.." && grep -rn -- 'curl[^|]*\(-[a-zA-Z]*k\b\|--insecure\)' scripts | grep -v 'selftest\|scripts/lib/tls.sh' | grep -Ec "$ALLOWED")"
missing=""
for f in $(cd "$HERE/.." && grep -rl 'pol_curl' scripts | grep -v 'selftest\|scripts/lib/tls.sh'); do
    grep -Eq 'source .*(lib/)?(tls|core-api|pol-api)\.sh' "$HERE/../$f" || missing="$missing $f"
done
eq  "static: every pol_curl caller sources tls.sh (or core-api.sh / pol-api.sh)" "" "$missing"
for f in "$HERE"/*.sh "$HERE"/lib/*.sh; do bash -n "$f" 2>/dev/null || bad "syntax: $f" "bash -n clean" "error"; done; ok "syntax: every script parses"

echo "$PASS/$((PASS+FAIL)) tls-selftest checks passed"; [ "$FAIL" -eq 0 ]
