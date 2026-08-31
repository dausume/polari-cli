#!/usr/bin/env bash
# The cells-advance SWEEP: take every cell×FET to the first step
# (coarse corner-grid library + sequential DFF/latch) so no cell page
# opens blank. Idempotent — devices with a library run are skipped by
# the service itself; re-running only fills what is still missing.
#   ssh pol-core 'bash ~/Desktop/polari-suite/polari-cli/shells/advance-cell-first-steps.sh'
#
# RESILIENCE (learned 2026-08-31, twice): the proxy cuts long POST
# responses (~40 min) — the backend KEEPS WORKING and the run lands
# server-side. So the POST body is advisory only: on an empty/unparseable
# response we POLL the report until that device's steps are done (or a
# stall cap), and the loop NEVER dies on one device's client error.
set -uo pipefail
API=${API:-https://api.prf.192.168.0.210.nip.io}
STALL_CAP_S=${STALL_CAP_S:-5400}   # per-device server-side wait cap

report() {
  curl -sk --max-time 60 "$API/api/fet/cells/advance" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (report unavailable — empty/cut response)"); raise SystemExit
for p in d["devices"]:
    steps = " ".join(p.get("steps", [])) or "done"
    print("  %-34s %s" % (p["device"], steps))
print("blank:", len(d.get("blankDevices", [])))
' || true
}

# remaining steps for ONE device ("done" / step list / "?" on cut)
dev_steps() {
  curl -sk --max-time 60 "$API/api/fet/cells/advance" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
for p in d["devices"]:
    if p["device"] == sys.argv[1]:
        print(" ".join(p.get("steps", [])) or "done"); break
else:
    print("?")
' "$1" || echo "?"
}

echo "== ladder report (before)"
report

DEVICES=$(curl -sk --max-time 60 "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [p["device"] for p in d["devices"]
         if p.get("steps") and "error" not in p]
print(" ".join(names))
')

for dev in $DEVICES; do
  echo "== advancing $dev (long call — coarse library + sequential)"
  body=$(curl -sk -X POST -H 'Content-Type: application/json' \
       --max-time 3600 -d "{\"device\": \"$dev\"}" \
       "$API/api/fet/cells/advance" || true)
  parsed=$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("CUT"); raise SystemExit
lib = d.get("library") or {}
seq = d.get("sequential") or {}
lat = d.get("latch") or {}
after = d.get("after") or {}
lib_s = ("skipped" if lib.get("skipped")
         else "ok" if lib.get("ok")
         else str(lib.get("error") or lib.get("refusal") or "?")[:60])
left = " ".join(after.get("steps", [])) or "done"
print("  ok", d.get("ok"), "| library:", lib_s,
      "| seq:", seq.get("ok", seq.get("skipped")),
      "| latch:", lat.get("ok", lat.get("skipped")),
      "| left:", left, str(d.get("error", ""))[:80])
' || echo "CUT")
  if [ "$parsed" = "CUT" ]; then
    echo "  response cut by the proxy — backend still working; polling"
    waited=0
    while [ "$waited" -lt "$STALL_CAP_S" ]; do
      sleep 120; waited=$((waited + 120))
      left=$(dev_steps "$dev")
      echo "  [poll ${waited}s] $dev: $left"
      [ "$left" = "done" ] && break
    done
    [ "$left" != "done" ] && echo "  ⚠ $dev still not done after ${STALL_CAP_S}s — moving on (idempotent re-run picks it up)"
  else
    printf '%s\n' "$parsed"
  fi
done

echo "== ladder report (after)"
report
