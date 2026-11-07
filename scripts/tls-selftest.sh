#!/bin/bash
# tls-selftest.sh — lib/tls.sh and every curl site of the CLI (no network; a FAKE curl records its argv):
# default = verified TLS (no -k, no --cacert); POL_TLS_CA=<pem> -> --cacert <pem> (a missing file refuses, exit 2; wins when
# both are set); POL_TLS_INSECURE=1 (alias POLARI_INSECURE=1 / --insecure) -> -k AND a [WARN] once per run and on every
# call, on the CLI's ORIGINAL stderr (a call site's own 2>/dev/null does not hide it); lib/pol-curl for external executors
# (timeout); lib/pol_tls.py for urllib; the knobs ride pol_api (pol engines) and core_api (POLARI_CORE_URL); a static
# audit names the only three curl sites still carrying -k (disclosed exceptions) and no unverified python context elsewhere.
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
CA="$T/ca.pem"; openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/ca.key" -out "$CA" -subj /CN=tls-selftest -days 1 >/dev/null 2>&1 || printf -- '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n' > "$CA"
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
eq "POL_TLS_INSECURE=1: -k" "-k " "$(run POL_TLS_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_flags | tr '\n' ' '") 2>/dev/null)"
eq "POL_TLS_INSECURE=true: -k" "-k " "$(run POL_TLS_INSECURE=true -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_flags | tr '\n' ' '") 2>/dev/null)"
eq "POL_TLS_INSECURE=0: verified" "verified" "$(run POL_TLS_INSECURE=0 -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_mode")"
eq "both set: POL_TLS_CA wins (cacert, the safer explicit choice)" "cacert" "$(run POL_TLS_INSECURE=1 POL_TLS_CA="$CA" -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_mode" 2>/dev/null)"
err=$(run POL_TLS_INSECURE=1 POL_TLS_CA="$CA" -- bash -c "source '$HERE/lib/tls.sh'; pol_curl -s https://x.invalid/p >/dev/null" 2>&1 >/dev/null)
has "both set: the ignored bypass is said" "[WARN] POL_TLS_INSECURE ignored: POL_TLS_CA=$CA is set" "$err"; hasnt "both set: no OFF warning" "verification OFF" "$err"
eq "alias POLARI_INSECURE=1 -> insecure" "insecure" "$(run POLARI_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'; pol_tls_mode" 2>/dev/null)"
err=$(run POL_TLS_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'" 2>&1); has "sourcing with the bypass says it ONCE per run" "[WARN] TLS verification OFF for this pol run (POL_TLS_INSECURE=1)" "$err"

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

# 2b. the notice survives a call site's OWN stderr redirection (Isle review: dev/prod/swarm probes use 2>/dev/null)
err=$(run POL_TLS_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'; pol_curl -s https://x.invalid/p 2>/dev/null >/dev/null; pol_curl -s https://y.invalid/q >/dev/null 2>&1" 2>&1)
has "redirected site: per-call [WARN] still reaches the CLI's stderr (2>/dev/null)" "verification OFF (POL_TLS_INSECURE=1): https://x.invalid/p" "$err"
has "redirected site: … and with >/dev/null 2>&1" "https://y.invalid/q" "$err"
has "redirected site: the once-per-run notice too" "for this pol run" "$err"
err=$(run POL_TLS_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'; pol_curl -s https://x.invalid/p" 2>/dev/null >/dev/null); eq "caller discarding the CLI's whole stderr discards the notice (outside the guarantee)" "" "$err"
# 2c. an external executor (timeout) must get an executable, not a function (Isle review: swarm quiesce exit 127)
: > "$LOG"; out=$(run -- bash -c "source '$HERE/lib/tls.sh'; printf '{}' | timeout 5 '$HERE/lib/pol-curl' -s -X POST --data-binary @- --max-time 4 https://x.invalid/quiesce" 2>&1); rc=$?
eq  "timeout lib/pol-curl: exit 0 (not 127), curl invoked with the argv" "0|-s -X POST --data-binary @- --max-time 4 https://x.invalid/quiesce" "$rc|$(cat "$LOG")"
: > "$LOG"; err=$(run POL_TLS_INSECURE=1 -- bash -c "source '$HERE/lib/tls.sh'; timeout 5 '$HERE/lib/pol-curl' -s https://x.invalid/p >/dev/null 2>&1" 2>&1)
has "timeout lib/pol-curl with the bypass: -k" "-k -s https://x.invalid/p" "$(cat "$LOG")"; has "… and the run-level notice is on the CLI's stderr even with >/dev/null 2>&1 around the executor" "for this pol run" "$err"
has "swarm.sh quiesce uses the executable" 'timeout 30 "$SCRIPT_DIR/lib/pol-curl"' "$(cat "$HERE/swarm.sh")"
# 2d. the python side (lib/pol_tls.py): the same two names, the alias, the precedence, the warning, the refusal
PYL="$HERE/lib"
eq  "py default: mode verified, context None" "verified None" "$(run -- python3 -c "import sys; sys.path.insert(0,'$PYL'); import pol_tls; print(pol_tls.tls_mode(), pol_tls.tls_context('https://x'))" 2>/dev/null)"
eq  "py POL_TLS_CA: a verifying SSLContext trusting that file" "cacert True 1" "$(run POL_TLS_CA="$CA" -- python3 -c "import sys,ssl; sys.path.insert(0,'$PYL'); import pol_tls; c=pol_tls.tls_context('https://x'); print(pol_tls.tls_mode(), c.verify_mode==ssl.CERT_REQUIRED, len(c.get_ca_certs()))" 2>&1)"
out=$(run POL_TLS_CA="$T/nope.pem" -- python3 -c "import sys; sys.path.insert(0,'$PYL'); import pol_tls; pol_tls.tls_context('https://x')" 2>&1); rc=$?
eq  "py POL_TLS_CA missing: exit 1 in words" 1 "$rc"; has "py POL_TLS_CA missing: says which file" "nope.pem is not a readable PEM" "$out"
err=$(run POL_TLS_INSECURE=1 -- python3 -c "import sys,ssl; sys.path.insert(0,'$PYL'); import pol_tls; c=pol_tls.tls_context('https://x/p'); print(c.verify_mode==ssl.CERT_NONE)" 2>&1); has "py POL_TLS_INSECURE: unverified context + the same [WARN]" "[WARN] TLS verification OFF (POL_TLS_INSECURE=1): https://x/p" "$err"; has "py POL_TLS_INSECURE: CERT_NONE" "True" "$err"
eq  "py alias POLARI_INSECURE=1 -> insecure" "insecure" "$(run POLARI_INSECURE=1 -- python3 -c "import sys; sys.path.insert(0,'$PYL'); import pol_tls; print(pol_tls.tls_mode())" 2>/dev/null)"
err=$(run POL_TLS_INSECURE=1 POL_TLS_CA="$T/nope.pem" -- python3 -c "import sys; sys.path.insert(0,'$PYL'); import pol_tls; pol_tls.tls_context()" 2>&1 || true); has "py both set: CA wins and the ignored bypass is said" "POL_TLS_INSECURE ignored" "$err"

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
pyleft=$(cd "$HERE/.." && grep -rnI "_create_unverified_context\|verify=False\|check_hostname = False\|environ.get('POLARI_INSECURE')\|\${POLARI_INSECURE" scripts | grep -v "selftest\|scripts/lib/tls.sh\|scripts/lib/pol_tls.py\|__pycache__" || true)
eq  "static: no unverified python context / old POLARI_INSECURE outside lib/pol_tls.py and lib/tls.sh" "" "$pyleft"
eq  "static: lib/pol-curl is executable" "yes" "$([ -x "$HERE/lib/pol-curl" ] && echo yes)"
for f in "$HERE"/*.sh "$HERE"/lib/*.sh; do bash -n "$f" 2>/dev/null || bad "syntax: $f" "bash -n clean" "error"; done; ok "syntax: every script parses"

echo "$PASS/$((PASS+FAIL)) tls-selftest checks passed"; [ "$FAIL" -eq 0 ]
