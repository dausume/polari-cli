#!/bin/bash
# bench-selftest.sh — cis-1: `pol bench` / `pol plans` / lib/pol-api.sh against a FAKE curl (no network, no backend).
# Asserts the shared conventions pol-core and econ agreed on 2026-11-06: --api / POL_API base, --json verbatim,
# exit 0 ok / 1 refused (words on stderr) / 2 unreachable, path segments URL-encoded (':' and '#'), TLS never
# bypassed (no -k ever sent), HTTP/1.1 forced, and the two meanings of exit 1 on check verbs (status, coverage untested).
#
#   bench-selftest.sh [-v] [--help]   → prints N/N and exits non-zero on a miss
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,8p' "$0"; exit 0 ;; esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad() { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "no …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

S="$T/suite"; mkdir -p "$S/polari-rf-node/polari-framework"; touch "$S/setup-polari-security.sh"
BIN="$T/bin"; mkdir -p "$BIN"; LOG="$T/curl.log"; BODY="$T/curl-body"; CANNED="$T/canned"; CODE="$T/code"; CURLRC="$T/curlrc"
# The fake curl: records argv + stdin, honours -o FILE / -w FMT, answers with $CANNED and HTTP $CODE, exits $CURLRC.
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
pol() { ( env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" bash "$HERE/$1" "${@:2}" ); }
API=https://api.fake.invalid

# ---------------------------------------------------------------- list: pretty + --json verbatim + transport flags
set_reply '{"ok": true, "rows": [{"name": "uno-light-on-desk", "title": "UNO light", "whole": false, "missing": 2}]}'
out=$(pol bench.sh list --api $API 2>&1); rc=$?
eq  "list: exit 0" 0 "$rc"
has "list: prints the row" "uno-light-on-desk" "$out"
has "list: curl got the door" "$API/api/board/bench-solutions" "$(cat "$LOG")"
has "list: HTTP/1.1 forced (item 15)" "--http1.1" "$(cat "$LOG")"
hasnt "list: TLS is NEVER bypassed (no -k)" " -k " " $(cat "$LOG") "
hasnt "list: … nor --insecure" "--insecure" "$(cat "$LOG")"
out=$(pol bench.sh list --api $API --json 2>&1)
eq  "list --json: the backend body verbatim" '{"ok": true, "rows": [{"name": "uno-light-on-desk", "title": "UNO light", "whole": false, "missing": 2}]}' "$out"
out=$(env POL_API=$API PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" bash "$HERE/bench.sh" list 2>&1); rc=$?
eq  "POL_API env is the base when --api is absent" 0 "$rc"

# ---------------------------------------------------------------- run --pin: body + encoded path + full node name accepted
set_reply '{"ok": true, "run": {"name": "uno-light-on-desk:on-by-button#run1", "outcome": "reached", "hex_sha256": "1e75dab5ee7e"}, "edges": [], "capture": "pin-b399"}'
out=$(pol bench.sh run uno-light-on-desk uno-light-on-desk:on-by-button --pin --path 'uno-light-on-desk:on-by-button#1' --api $API 2>&1); rc=$?
eq  "run: exit 0" 0 "$rc"
has "run: POSTs the node run door, slug stripped of the bench prefix" "POST" "$(cat "$LOG")"
has "run: … at B/nodes/on-by-button/run" "/api/cmod/bench-topology/uno-light-on-desk/nodes/on-by-button/run" "$(cat "$LOG")"
has "run: body carries pin:true" '"pin": true' "$(cat "$BODY")"
has "run: body carries the path (the # is JSON, not URL)" '"path": "uno-light-on-desk:on-by-button#1"' "$(cat "$BODY")"
has "run: prints outcome + capture" "reached" "$out"
has "run: … and the pinned capture id" "pin-b399" "$out"

# ---------------------------------------------------------------- captures: run names with ':' and '#' are URL-encoded
set_reply '{"ok": true, "rows": [{"name": "pin-b399", "kind": "pinned", "words": "kept"}]}'
out=$(pol bench.sh captures uno-light-on-desk 'uno-light-on-desk:on-by-button#run1' --api $API 2>&1); rc=$?
eq  "captures: exit 0" 0 "$rc"
has "captures: ':' and '#' percent-encoded in the path" "/runs/uno-light-on-desk%3Aon-by-button%23run1/captures" "$(cat "$LOG")"

# ---------------------------------------------------------------- refused: HTTP 404 / ok:false -> exit 1, words on stderr, body on stdout under --json
set_reply '{"ok": false, "error": "no Bench Solution nope"}' 404
out=$(pol bench.sh topology nope --api $API 2>/dev/null); rc=$?
err=$(pol bench.sh topology nope --api $API 2>&1 >/dev/null)
eq  "refused (404): exit 1" 1 "$rc"
has "refused: the backend's words on stderr" "no Bench Solution nope" "$err"
out=$(pol bench.sh topology nope --api $API --json 2>/dev/null); rc=$?
has "refused --json: body still on stdout" '"ok": false' "$out"
set_reply '{"ok": false, "error": "spec unknown"}' 200
out=$(pol bench.sh apply-spec uno-light-on-desk --spec zzz --api $API 2>&1); rc=$?
eq  "refused (200 but ok:false): exit 1" 1 "$rc"
has "refused (ok:false): words" "spec unknown" "$out"
has "apply-spec: body carries the spec" '"spec": "zzz"' "$(cat "$BODY")"

# ---------------------------------------------------------------- unreachable -> exit 2
set_reply '' 000 7
out=$(pol bench.sh list --api $API 2>&1); rc=$?
eq  "unreachable (curl rc 7): exit 2" 2 "$rc"
has "unreachable: says so" "unreachable" "$out"
out=$(pol bench.sh list --api 'not a url' 2>&1); rc=$?
eq  "bad --api value: exit 2" 2 "$rc"
out=$(pol bench.sh frobnicate --api $API 2>&1); rc=$?
eq  "unknown verb: exit 2 (usage)" 2 "$rc"
out=$(pol bench.sh run uno-light-on-desk --api $API 2>&1); rc=$?
eq  "missing argument: exit 1 via die (as every pol verb)" 1 "$rc"

# ---------------------------------------------------------------- check verbs: exit 1 means NOT GREEN
set_reply '{"ok": true, "rows": [{"words": "uno-light-on-desk:reported: never tested"}]}'
out=$(pol bench.sh coverage uno-light-on-desk untested --api $API 2>&1); rc=$?
eq  "coverage untested with rows: exit 1 (NOT GREEN)" 1 "$rc"
has "coverage untested: says NOT GREEN" "NOT GREEN" "$out"
has "coverage untested: hits the door" "/coverage/untested" "$(cat "$LOG")"
set_reply '{"ok": true, "rows": []}'
out=$(pol bench.sh coverage uno-light-on-desk untested --api $API 2>&1); rc=$?
eq  "coverage untested empty: exit 0 (green)" 0 "$rc"

# status: the fake answers the SAME body to every door, so make one that satisfies all four reads at once
set_reply '{"ok": true, "name": "uno-light-on-desk", "whole": true, "legs": {"system": {"ref": "uno-light-bench", "ok": true, "why": ""}}, "root": "r", "nodes": [{"name": "uno-light-on-desk:on-by-button", "kind": "state", "paths": [1], "blocked": false}], "edges": [], "events": [], "rows": []}'
out=$(pol bench.sh status uno-light-on-desk --api $API 2>&1); rc=$?
eq  "status: all legs ok, nothing untested, node never run -> exit 0 GREEN" 0 "$rc"
has "status: prints GREEN" "GREEN" "$out"
has "status: lists the node" "uno-light-on-desk:on-by-button" "$out"
set_reply '{"ok": true, "name": "uno-light-on-desk", "whole": false, "legs": {"firmware": {"ref": "uno-light", "ok": false, "why": "validated, not built"}}, "root": "r", "nodes": [], "edges": [], "events": [], "rows": []}'
out=$(pol bench.sh status uno-light-on-desk --api $API 2>&1); rc=$?
eq  "status: a red leg -> exit 1 NOT GREEN" 1 "$rc"
has "status: names the red leg" "validated, not built" "$out"
out=$(pol bench.sh status uno-light-on-desk --api $API --json 2>&1)
has "status --json: the composite object" '"green": false' "$out"

# ---------------------------------------------------------------- node add from flags -> the documented body shape
set_reply '{"ok": true, "name": "uno-light-on-desk:via-door", "paths": [1], "requirements": [1]}'
out=$(pol bench.sh node add uno-light-on-desk --slug via-door --from boot --event 'uno-light-on-desk:reset' --require 'LightState_t->LightState:boot_session:written' --exec apps/light.boot_session_mint --api $API 2>&1); rc=$?
eq  "node add (flags): exit 0" 0 "$rc"
has "node add: slug" '"slug": "via-door"' "$(cat "$BODY")"
has "node add: from_node" '"from_node": "boot"' "$(cat "$BODY")"
has "node add: default edge_kind trigger" '"edge_kind": "trigger"' "$(cat "$BODY")"
has "node add: requirement object" '"object_map": "LightState_t->LightState", "field": "boot_session", "kind": "written"' "$(cat "$BODY")"
has "node add: execution string" '"executions": ["apps/light.boot_session_mint"]' "$(cat "$BODY")"

# ---------------------------------------------------------------- plans: task set posts the file; spec list forwards to bench specs
set_reply '{"ok": true, "plan": "p1"}'
echo '{"system": "uno-light-bench", "run": true}' > "$T/plan.json"
out=$(pol plans.sh task set uno-light --file "$T/plan.json" --api $API 2>&1); rc=$?
eq  "plans task set: exit 0" 0 "$rc"
has "plans task set: POST /api/missions/<m>/task-plan" "POST" "$(cat "$LOG")"
has "plans task set: … the door" "/api/missions/uno-light/task-plan" "$(cat "$LOG")"
has "plans task set: body = the file" '"system": "uno-light-bench"' "$(cat "$BODY")"
set_reply '{"ok": true, "rows": [{"name": "uno-light-bench", "bench_system": "uno-light-bench", "nodes": 6, "roles": ["press"], "title": "t"}]}'
out=$(pol plans.sh spec list --api $API 2>&1); rc=$?
eq  "plans spec list: forwards to pol bench specs (exit 0)" 0 "$rc"
has "plans spec list: hits /api/cmod/topology-specs" "/api/cmod/topology-specs" "$(cat "$LOG")"
out=$(pol plans.sh task bogus --api $API 2>&1); rc=$?
eq  "plans task unknown: exit 2" 2 "$rc"

echo "$PASS/$((PASS+FAIL)) bench-selftest checks passed"
[ "$FAIL" -eq 0 ]
