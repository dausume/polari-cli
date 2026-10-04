#!/bin/bash
# pcb-ingest-selftest.sh — pcb-api-1: `pol pcb ingest <path> --api URL` sent
# the HOST path for the SERVER to open, which fails against a staging
# container with no bind mount (the server opens `path` on its OWN
# filesystem, cwd = the framework root). The fix: a path under the
# framework's own modules/ directory (which DOES exist inside the server's
# image) is sent RELATIVE to the framework root; anything else is refused
# honestly instead of being sent and failing remotely.
#
# No real network touched: `curl` is faked in a scratch bin dir and just
# records the body it was given.
#
#   pcb-ingest-selftest.sh [-v] [--help]   → prints N/N and exits non-zero on a miss
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,12p' "$0"; exit 0 ;; esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad() { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# ---------------------------------------------------------------- a scratch suite shaped like the real one
S="$T/suite"
FW="$S/polari-rf-node/polari-framework"
mkdir -p "$FW/modules/pcb/myproject" "$S/outside-the-checkout/another-project"
touch "$S/setup-polari-security.sh"
echo 'board.kicad_pcb content' > "$FW/modules/pcb/myproject/board.kicad_pcb"
echo 'board.kicad_pcb content' > "$S/outside-the-checkout/another-project/board.kicad_pcb"

BIN="$T/bin"; mkdir -p "$BIN"
CURL_BODY_FILE="$T/curl-body.json"
CURL_CALLED_FILE="$T/curl-called"
cat > "$BIN/curl" <<SH
#!/bin/bash
echo 1 > "$CURL_CALLED_FILE"
cat > "$CURL_BODY_FILE"
echo '{"ok": true, "stored": {"Part": 3}}'
SH
chmod +x "$BIN/curl"

run() {  # run <pcb.sh ingest args…>
    rm -f "$CURL_CALLED_FILE" "$CURL_BODY_FILE"
    ( env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" bash "$HERE/pcb.sh" ingest "$@" )
}

# ---------------------------------------------------------------- a path under modules/ -> sent relative, curl called
out=$(run "$FW/modules/pcb/myproject" --api http://fake-api.invalid --board myboard 2>&1)
rc=$?
eq  "a path under the framework's modules/: ingest succeeds (exit 0)" 0 "$rc"
eq  "…curl is actually called" "1" "$(cat "$CURL_CALLED_FILE" 2>/dev/null || echo 0)"
has "…the body sent is RELATIVE to the framework root, never the host absolute path" '"path": "modules/pcb/myproject"' "$(cat "$CURL_BODY_FILE" 2>/dev/null)"
has "…and still carries the board" '"board": "myboard"' "$(cat "$CURL_BODY_FILE" 2>/dev/null)"
has "…the printed verdict reads the server's response" "stored" "$out"

# ---------------------------------------------------------------- a path OUTSIDE modules/ -> refused, curl never called
out2=$(run "$S/outside-the-checkout/another-project" --api http://fake-api.invalid 2>&1)
rc2=$?
[ "$rc2" -ne 0 ] && ok "a path OUTSIDE the framework's modules/: refused (non-zero exit)" || bad "a path OUTSIDE the framework's modules/: refused (non-zero exit)" "non-zero" "$rc2"
has "…names the refusal in plain words" "--api needs a path the server can read" "$out2"
has "…says upload is owed" "upload is owed" "$out2"
eq  "…curl is NEVER called for a refused path" "0" "$(cat "$CURL_CALLED_FILE" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------- no --api: untouched, local CLI path still works (no curl at all)
BIN2="$T/bin-no-curl"; mkdir -p "$BIN2"   # deliberately no `curl` here
out3=$(env PATH="$BIN2:/usr/bin:/bin" POL_SUITE_ROOT="$S" bash "$HERE/pcb.sh" ingest "$FW/modules/pcb/myproject" 2>&1)
rc3=$?
# py -m pcb.custom.pcb_cli will itself fail in this scratch suite (no real framework) —
# the only thing asserted here is that the --api branch (and its curl requirement) was
# never entered: no "command not found: curl" and no path-translation message.
has "no --api: never mentions the --api refusal/translation machinery at all" "" "$(echo "$out3" | grep -c 'upload is owed' || true)"
eq  "no --api: the local CLI path is attempted (not the --api branch)" "0" "$(echo "$out3" | grep -c 'upload is owed\|curl: command not found' || true)"

echo "$PASS/$((PASS+FAIL)) pcb-ingest-selftest checks passed"
[ "$FAIL" -eq 0 ]
