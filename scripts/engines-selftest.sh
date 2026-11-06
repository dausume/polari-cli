#!/bin/bash
# engines-selftest.sh — `pol engines list|sync` against a FAKE curl (no network): the doors, the exit codes
# (0 ok / 1 refused incl. 502 registry-unreachable / 2 unreachable), --json verbatim, TLS never bypassed.
#   engines-selftest.sh [-v] [--help]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0; case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,5p' "$0"; exit 0 ;; esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad() { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "no …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
S="$T/suite"; mkdir -p "$S"; touch "$S/setup-polari-security.sh"
BIN="$T/bin"; mkdir -p "$BIN"; LOG="$T/curl.log"; BODY="$T/curl-body"; CANNED="$T/canned"; CODE="$T/code"; CURLRC="$T/curlrc"
cat > "$BIN/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$LOG"
out=''; want_code=0; args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do case "\${args[i]}" in -o) out="\${args[i+1]}" ;; -w) want_code=1 ;; --data-binary) [ "\${args[i+1]}" = "@-" ] && cat > "$BODY" ;; esac; done
rc=\$(cat "$CURLRC" 2>/dev/null || echo 0); [ "\$rc" != 0 ] && { echo "curl: (\$rc) Failed to connect" >&2; exit "\$rc"; }
[ -n "\$out" ] && cat "$CANNED" > "\$out" || cat "$CANNED"
[ "\$want_code" = 1 ] && cat "$CODE"
exit 0
SH
chmod +x "$BIN/curl"
set_reply() { printf '%s' "$1" > "$CANNED"; echo "${2:-200}" > "$CODE"; echo "${3:-0}" > "$CURLRC"; : > "$LOG"; rm -f "$BODY"; }
pol() { ( env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" bash "$HERE/engines.sh" "$@" ); }
API=https://api.fake.invalid

set_reply '{"ok": true, "engines": [{"name": "board-engines@board", "app": "board-engines", "device": "", "provides": "board", "url": "https://board-engines.isle", "bound": true, "bound_to": "EngineProviderBinding:board", "note": "[isle registry] wired", "is_mock": false}]}'
out=$(pol list --api $API 2>&1); rc=$?
eq  "list: exit 0" 0 "$rc"
has "list: GET /api/islemesh/engines" "$API/api/islemesh/engines" "$(cat "$LOG")"
has "list: prints the engine, bound" "board-engines@board" "$out"
has "list: an empty device prints as unknown, never a guessed host" "device unknown" "$out"
has "list: HTTP/1.1 forced" "--http1.1" "$(cat "$LOG")"
hasnt "list: TLS never bypassed" " -k " " $(cat "$LOG") "
out=$(pol list --api $API --json 2>&1); has "list --json: verbatim body" '"bound_to": "EngineProviderBinding:board"' "$out"

set_reply '{"ok": true, "source": "refresh", "origin": "https://api.polari.isle", "seen": 2, "bound": [{"engine": "board-engines@board", "bound_to": "EngineProviderBinding:board", "url": "https://board-engines.isle", "device": "unknown"}], "unbound": [], "skipped_mock": ["fake@scope"], "retired": ["old@cad"], "words": "2 listed, 1 bound, 0 unbound, 1 mock skipped, 1 retired (https://api.polari.isle)"}'
out=$(pol sync --api $API 2>&1); rc=$?
eq  "sync: exit 0" 0 "$rc"
has "sync: POST /api/islemesh/engines/sync" "POST" "$(cat "$LOG")"
has "sync: … the door" "/api/islemesh/engines/sync" "$(cat "$LOG")"
has "sync: prints the words" "1 bound, 0 unbound, 1 mock skipped, 1 retired" "$out"
has "sync: lists the retirement" "retired old@cad" "$out"
has "sync: lists the skipped mock" "mock    fake@scope" "$out"

set_reply '{"ok": false, "source": "refresh", "origin": "https://api.polari.isle", "seen": 0, "bound": [], "unbound": [], "skipped_mock": [], "retired": [], "words": "registry unreachable at https://api.polari.isle/api/islemesh/engines: URLError: boom"}' 502
out=$(pol sync --api $API 2>/dev/null); rc=$?; err=$(pol sync --api $API 2>&1 >/dev/null)
eq  "sync: registry unreachable (502, ok:false) -> exit 1" 1 "$rc"
has "sync: … words on stderr" "registry unreachable" "$err"
set_reply '' 000 7
out=$(pol sync --api $API 2>&1); rc=$?
eq  "sync: backend unreachable -> exit 2" 2 "$rc"
out=$(pol bogus --api $API 2>&1); rc=$?; eq "unknown verb: exit 2" 2 "$rc"
echo "$PASS/$((PASS+FAIL)) engines-selftest checks passed"; [ "$FAIL" -eq 0 ]
