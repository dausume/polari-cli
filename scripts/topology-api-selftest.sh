#!/bin/bash
# topology-api-selftest.sh — `pol topology --api <url>` (cis arc) against a FAKE curl (no network, no docker):
# the doors each verb calls, the shared exit codes (0 ok / 1 refused / 2 unreachable or usage), --json verbatim
# with nothing else on stdout, verified TLS (never -k), and the local-only verbs refusing to target another backend.
# fixtures/isle-needs-sample.json is the REAL topology_isle_needs.isle_needs() output (framework 391cccea) for one
# fresh device and one dated 2099 (clock skew), so the renderer is tested against the production shape.
#   topology-api-selftest.sh [-v] [--help]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0; case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,7p' "$0"; exit 0 ;; esac
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad() { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "no …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
# no_insecure LABEL LOG — no curl call carried -k in any spelling (-k, -sSk, --insecure).
no_insecure() { if grep -Eq '(^| )(-[a-zA-Z]*k[a-zA-Z]*|--insecure)( |$)' <<<"$2"; then bad "$1" "no -k / --insecure" "$2"; else ok "$1"; fi; }
S="$T/suite"; mkdir -p "$S"; touch "$S/setup-polari-security.sh"
BIN="$T/bin"; mkdir -p "$BIN"; LOG="$T/curl.log"; BODY="$T/curl-body"; ROUTES="$T/routes"; CURLRC="$T/curlrc"
# The fake answers by route: each line of $ROUTES is "<url substring>\t<http code>\t<body file>"; first match wins.
cat > "$BIN/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$LOG"
out=''; want_code=0; url=''; args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do case "\${args[i]}" in -o) out="\${args[i+1]}" ;; -w) want_code=1 ;;
  --data-binary) [ "\${args[i+1]}" = "@-" ] && cat >> "$BODY" ;; http*) url="\${args[i]}" ;; esac; done
rc=\$(cat "$CURLRC" 2>/dev/null || echo 0); [ "\$rc" != 0 ] && { echo "curl: (\$rc) Failed to connect" >&2; exit "\$rc"; }
code=404; file=/dev/null
while IFS=\$'\t' read -r sub c f; do case "\$url" in *"\$sub"*) code=\$c; file=\$f; break ;; esac; done < "$ROUTES"
[ -n "\$out" ] && cat "\$file" > "\$out" || cat "\$file"
[ "\$want_code" = 1 ] && printf '%s' "\$code"
exit 0
SH
chmod +x "$BIN/curl"
reset() { : > "$ROUTES"; : > "$LOG"; rm -f "$BODY"; echo 0 > "$CURLRC"; }
route() { local f="$T/body.$RANDOM$RANDOM"; printf '%s' "$3" > "$f"; printf '%s\t%s\t%s\n' "$1" "$2" "$f" >> "$ROUTES"; }
route_file() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ROUTES"; }
# docker is shadowed too: a --api run must never fall back to a local container.
printf '#!/bin/bash\necho "docker $*" >> "%s/docker.log"; exit 1\n' "$T" > "$BIN/docker"; chmod +x "$BIN/docker"
pol() { ( env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" bash "$HERE/topology.sh" "$@" ); }
API=https://api.fake.invalid
SUMMARY='{"ok": true, "activeTopology": "polari", "topologies": [{"name": "polari", "status": "active", "isActive": true, "description": "described by the instance itself (tpl-0)"}], "counts": {"InstanceDefinition": 2, "ModuleAssignment": 9}}'

# ---- status: GET summary, verified TLS, HTTP/1.1, human + --json
reset; route /api/topology/summary 200 "$SUMMARY"
out=$(pol status --api $API 2>&1); rc=$?
eq  "status: exit 0" 0 "$rc"
has "status: GET /api/topology/summary on the --api backend" "$API/api/topology/summary" "$(cat "$LOG")"
has "status: prints the active topology" "active topology: polari" "$out"
has "status: prints the row counts" "ModuleAssignment=9" "$out"
has "status: the box names the backend" "($API)" "$out"
has "status: HTTP/1.1 forced" "--http1.1" "$(cat "$LOG")"
no_insecure "status: TLS never bypassed (-k, -sSk, --insecure)" "$(cat "$LOG")"
hasnt "status: never falls back to a local container" "docker" "$(cat "$T/docker.log" 2>/dev/null)"
out=$(pol status --api $API --json 2>/dev/null); rc=$?
eq  "status --json: exit 0" 0 "$rc"
eq  "status --json: stdout is the body verbatim, nothing else" "$SUMMARY" "$out"
out=$(POL_API=$API pol status 2>&1); has "status: POL_API env works like --api" "active topology: polari" "$out"
out=$(pol --api $API status 2>&1); rc=$?; eq "flags before the verb are not the verb (verb first): unknown -> exit 2" 2 "$rc"

# ---- graph with no name: resolves the active topology first, then GETs the graph
reset; route /api/topology/summary 200 "$SUMMARY"
route '/api/topology/graph?name=polari' 200 '{"ok": true, "topology": {"name": "polari", "status": "active", "defaultTarget": "compose"}, "instances": [{"name": "polari", "kind": "backend", "orchestrationTarget": "compose", "dbBackend": "sqlite", "machineName": "isle-core"}], "assignments": [{"instanceName": "polari", "moduleName": "board", "state": "enabled"}], "edges": [{"moduleName": "board", "consumerInstanceName": "polari", "dependsOnModule": "board.engines", "providerInstanceName": "board-engines", "status": "resolved"}], "connections": []}'
out=$(pol graph --api $API 2>&1); rc=$?
eq  "graph: exit 0" 0 "$rc"
has "graph: asked for the active topology by name" "graph?name=polari" "$(cat "$LOG")"
has "graph: the instance and its machine" "@isle-core" "$out"
has "graph: the engine edge" "board@polari -> board.engines @ board-engines" "$out"

# ---- isle-needs: the production shape (one fresh device, one dated 2099)
reset; route_file /api/topology/isle-needs 200 "$HERE/fixtures/isle-needs-sample.json"
out=$(pol isle-needs --api $API 2>&1); rc=$?
eq  "isle-needs: exit 0" 0 "$rc"
has "isle-needs: GET /api/topology/isle-needs" "$API/api/topology/isle-needs" "$(cat "$LOG")"
has "isle-needs: the isle words, with the future-dated device named as clock skew" "dated in the future (clock skew)" "$out"
has "isle-needs: a fresh observation shows its state and age" "[last-reported ] Finding other devices and their Polari instances (2026-11-06T18:59:00+00:00, 60 s ago)" "$out"
has "isle-needs: configured is never claimed as working" "[configured    ] Trusted HTTPS names" "$out"
has "isle-needs: each feature's fallback" "without it: set the engine URL knob" "$out"
has "isle-needs: the knobs are named in the header" "older than 86400 s is stale" "$out"
has "isle-needs: Polari-only features listed as supported" "Polari-only (supported with or without an isle): placement, dependencies" "$out"
hasnt "isle-needs: never the word available" "available" "$out"
out=$(pol isle-needs --api $API --json 2>/dev/null)
has "isle-needs --json: the backend body" '"clockSkewS": 300' "$out"

# ---- WRITE verbs send their bodies
reset; route /api/topology/summary 200 "$SUMMARY"; route /api/topology/validate 200 '{"ok": true, "topology": "polari", "valid": true, "errorCount": 0, "warnCount": 0, "findings": []}'
out=$(pol validate --api $API 2>&1); rc=$?
eq  "validate: exit 0" 0 "$rc"
has "validate: POSTs" "-X POST" "$(cat "$LOG")"
has "validate: prints the verdict" "topology polari: VALID" "$out"
reset; route /api/topology/assign 200 '{"ok": true, "assignment": "scope@polari", "disabled": [], "resolve": {"changed": []}, "suggestedCommand": "isle polari module move scope --from a --to polari"}'
out=$(pol assign scope polari --api $API 2>&1); rc=$?
eq  "assign: exit 0" 0 "$rc"
has "assign: the body names the module and instance" '"module": "scope", "to_instance": "polari"' "$(cat "$BODY" 2>/dev/null)"
has "assign: the deploy stays the person's" "deploying the change stays yours" "$out"

# ---- refused: the backend answered no
reset; route /api/topology/summary 200 "$SUMMARY"; route /api/topology/graph 404 '{"ok": false, "error": "no topology named nope"}'
out=$(pol graph nope --api $API 2>/dev/null); rc=$?; err=$(pol graph nope --api $API 2>&1 >/dev/null)
eq  "refused (404, ok:false): exit 1" 1 "$rc"
has "refused: the backend's words on stderr" "no topology named nope" "$err"
out=$(pol graph nope --api $API --json 2>/dev/null); rc=$?
eq  "refused --json: exit 1" 1 "$rc"
has "refused --json: the body still on stdout" '"error": "no topology named nope"' "$out"

# ---- an older backend without the door: the REAL Falcon 404 body (seen live on api.polari-pol.isle, image 3b088dca)
reset; route /api/topology/isle-needs 404 '{"title": "404 Not Found"}'
out=$(pol isle-needs --api $API 2>/dev/null); rc=$?; err=$(pol isle-needs --api $API 2>&1 >/dev/null)
eq  "404 without ok:false: exit 1" 1 "$rc"
eq  "404: nothing rendered as if it were a report" "" "$out"
has "404: the status and words on stderr" "HTTP 404: 404 Not Found" "$err"
out=$(pol isle-needs --api $API --json 2>/dev/null); rc=$?
eq  "404 --json: exit 1" 1 "$rc"
eq  "404 --json: the body verbatim" '{"title": "404 Not Found"}' "$out"
reset; route /api/topology/summary 200 '<html>bad gateway</html>'
out=$(pol status --api $API 2>&1); rc=$?
eq  "a non-JSON 200: exit 1" 1 "$rc"
has "a non-JSON 200: says so, no traceback" "not JSON" "$out"
hasnt "a non-JSON 200: no Python traceback" "Traceback" "$out"

# ---- unreachable: exit 2, with and without an implied name lookup
reset; echo 7 > "$CURLRC"
out=$(pol status --api $API 2>&1); rc=$?
eq  "unreachable status: exit 2" 2 "$rc"
has "unreachable: says which backend" "$API unreachable" "$out"
out=$(pol graph --api $API 2>&1); rc=$?
eq  "unreachable graph (needs the active name first): exit 2" 2 "$rc"
out=$(pol isle-needs --api $API 2>&1); rc=$?
eq  "unreachable isle-needs: exit 2" 2 "$rc"

# ---- usage
reset
out=$(pol status --api ftp://x 2>&1); rc=$?; eq "--api must be http(s): exit 2" 2 "$rc"
out=$(pol status --api 2>&1); rc=$?; eq "--api with no URL: exit 2" 2 "$rc"
out=$(pol bogus --api $API 2>&1); rc=$?; eq "unknown verb: exit 2" 2 "$rc"

# ---- tpl-6 example-rows: plan (GET) shows the digest; retire POSTs it; usage refusals
reset; route /api/topology/example-rows 200 '{"ok": true, "instance": "polari", "retire": [{"class": "InstanceDefinition", "name": "prf-a"}], "keep": [{"class": "PolariNodeMachine", "name": "isle-core", "why": "a 2026-07-09 example row still referred to by kept InstanceDefinition:polari (machine_name)"}], "rehome": [{"class": "InstanceDefinition", "name": "polari", "from": "staging-a", "to": "polari"}], "planDigest": "abc123", "plannedAction": {"summary": "retire 1 unchanged July example row on polari", "appRun": "not built yet: the Isle App bulk run of planned actions is planned (Isle side); today run operatorCommand on the device"}, "words": "polari: retire 1 unchanged example row, keep 1, move 1 kept row onto topology polari"}'
out=$(pol example-rows --api $API 2>&1); rc=$?
eq  "example-rows plan: exit 0" 0 "$rc"
has "example-rows plan: GET the door" "$API/api/topology/example-rows" "$(cat "$LOG")"
hasnt "example-rows plan: a GET only" "POST" "$(cat "$LOG")"
has "example-rows plan: retire lines" "retire  InstanceDefinition     prf-a" "$out"
has "example-rows plan: keep lines with the reason" "referred to by kept InstanceDefinition:polari" "$out"
has "example-rows plan: move lines" "topology staging-a -> polari" "$out"
has "example-rows plan: the exact apply command with the digest" "example-rows retire --digest abc123" "$out"
has "example-rows plan: says nothing changed" "nothing has changed" "$out"
has "example-rows plan: names the host-operator path, no --api" "on the backend's device, no --api" "$out"
has "example-rows plan: prints the planned action summary" "planned action: retire 1 unchanged July example row" "$out"
has "example-rows plan: says the Isle App run is not built yet" "not built yet" "$out"
hasnt "example-rows plan: never presents the App run as existing" "planned-actions run (one sudo" "$out"
reset; route /api/topology/example-rows/retire 200 '{"ok": true, "retired": [], "rehomed": [], "backup": {"file": "retire-example-20261107T040000Z.json", "dir": "/data/topology-backups", "sha256": "dd", "bytes": 10}, "problems": [], "words": "polari: retired 1 example row"}'
out=$(pol example-rows retire --digest abc123 --api $API 2>&1); rc=$?
eq  "example-rows retire: exit 0" 0 "$rc"
has "example-rows retire: POSTs the digest" '"planDigest": "abc123"' "$(cat "$BODY" 2>/dev/null)"
has "example-rows retire: prints the backup" "/data/topology-backups/retire-example-20261107T040000Z.json" "$out"
reset; route /api/topology/example-rows/retire 409 '{"ok": false, "words": "refused: the plan changed since it was reviewed"}'
out=$(pol example-rows retire --digest old --api $API 2>&1); rc=$?
eq  "example-rows retire, stale digest (409): exit 1" 1 "$rc"
reset; route /api/topology/example-rows/retire 403 '{"ok": false, "denied": true, "words": "refused: this door changes rows, and runs only for the host operator or a Polari administrator (caller 172.18.0.5). Nothing was written, backed up or deleted."}'
out=$(pol example-rows retire --digest abc123 --api $API 2>&1); rc=$?
eq  "example-rows retire from elsewhere (403 denied): exit 1" 1 "$rc"
has "example-rows retire 403: the gate's words reach the person" "runs only for the host operator" "$out"
reset
out=$(pol example-rows retire --api $API 2>&1); rc=$?
eq  "example-rows retire without --digest: exit 2, no call" "2:" "$rc:$(cat "$LOG")"
out=$(pol example-rows restore --api $API 2>&1); rc=$?
eq  "example-rows restore without a name: exit 2" 2 "$rc"
reset; route /api/topology/example-rows/restore 200 '{"ok": true, "created": [], "unrehomed": [], "words": "restored 1 row from retire-example-x.json"}'
out=$(pol example-rows restore retire-example-x.json --api $API 2>&1); rc=$?
eq  "example-rows restore: exit 0" 0 "$rc"
has "example-rows restore: POSTs the name" '"backup": "retire-example-x.json"' "$(cat "$BODY" 2>/dev/null)"

# ---- the CLI boundary: verbs that run things on THIS machine refuse another backend, before any call
for verb in "apply --plan" "deploy x" "allocate scope polari"; do
    reset
    # shellcheck disable=SC2086
    out=$(pol $verb --api $API 2>&1); rc=$?
    eq  "${verb%% *} --api: exit 2" 2 "$rc"
    has "${verb%% *} --api: names the isle operation instead" "is an isle operation (sudo isle polari instance deploy" "$out"
    eq  "${verb%% *} --api: no backend call made" "" "$(cat "$LOG")"
done

echo "$PASS/$((PASS+FAIL)) topology-api-selftest checks passed"; [ "$FAIL" -eq 0 ]
