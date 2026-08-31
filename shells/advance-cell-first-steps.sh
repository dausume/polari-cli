#!/usr/bin/env bash
# The cells-advance SWEEP: take every cell×FET to the first step
# (coarse corner-grid library + sequential DFF/latch) so no cell page
# opens blank. Idempotent — devices with a library run are skipped by
# the service itself; re-running only fills what is still missing.
#   ssh pol-core 'bash ~/Desktop/polari-suite/polari-cli/shells/advance-cell-first-steps.sh'
set -euo pipefail
API=${API:-https://api.prf.192.168.0.210.nip.io}

echo "== ladder report (before)"
curl -sk "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for p in d["devices"]:
    print(f"  {p[\"device\"]:34s} {\" \".join(p[\"steps\"]) or \"done\"}")
print("blank:", len(d["blankDevices"]))'

for dev in $(curl -sk "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("\n".join(p["device"] for p in d["devices"]
                if p.get("steps") and "error" not in p))'); do
  echo "== advancing $dev (long call — coarse library + sequential)"
  curl -sk -X POST -H 'Content-Type: application/json' \
       --max-time 3600 -d "{\"device\": \"$dev\"}" \
       "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
lib = d.get("library") or {}
print("  ok", d.get("ok"),
      "| library:", "skipped" if lib.get("skipped")
      else ("ok" if lib.get("ok") else lib.get("error", lib.get("refusal", ""))),
      "| seq:", (d.get("sequential") or {}).get("ok",
                (d.get("sequential") or {}).get("skipped")),
      "| latch:", (d.get("latch") or {}).get("ok",
                  (d.get("latch") or {}).get("skipped")),
      "| left:", " ".join((d.get("after") or {}).get("steps", [])) or "done",
      str(d.get("error", ""))[:80])'
done

echo "== ladder report (after)"
curl -sk "$API/api/fet/cells/advance" | python3 -c '
import json, sys
d = json.load(sys.stdin)
left = [p for p in d["devices"] if p.get("steps")]
print("  all done" if d["done"] else
      "  still missing: " + ", ".join(
          f"{p[\"device\"]}({len(p[\"steps\"])})" for p in left))'
