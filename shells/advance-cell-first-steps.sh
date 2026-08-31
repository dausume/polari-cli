#!/usr/bin/env bash
# The cells-advance SWEEP: take every cell×FET to the first step
# (coarse corner-grid library + sequential DFF/latch) so no cell page
# opens blank. Idempotent — devices with a library run are skipped by
# the service itself; re-running only fills what is still missing.
#   ssh pol-core 'bash ~/Desktop/polari-suite/polari-cli/shells/advance-cell-first-steps.sh'
set -euo pipefail
API=${API:-https://api.prf.192.168.0.210.nip.io}

report() {
  curl -sk "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in d["devices"]:
    steps = " ".join(p.get("steps", [])) or "done"
    print("  %-34s %s" % (p["device"], steps))
print("blank:", len(d.get("blankDevices", [])))
'
}

echo "== ladder report (before)"
report

DEVICES=$(curl -sk "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [p["device"] for p in d["devices"]
         if p.get("steps") and "error" not in p]
print(" ".join(names))
')

for dev in $DEVICES; do
  echo "== advancing $dev (long call — coarse library + sequential)"
  curl -sk -X POST -H 'Content-Type: application/json' \
       --max-time 3600 -d "{\"device\": \"$dev\"}" \
       "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
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
'
done

echo "== ladder report (after)"
report
