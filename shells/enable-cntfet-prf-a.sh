#!/usr/bin/env bash
# Enable the cntfet module on prf-a (rows are the truth), re-render +
# roll the node stack, wait for boot, and verify the fi-2/fi-3 scoring
# surfaces. Unattended — safe to run over ssh:
#   ssh pol-core 'bash ~/Desktop/polari-suite/polari-cli/shells/enable-cntfet-prf-a.sh'
# Re-runnable: assign is idempotent-by-name; deploy re-rolls only when
# the rendered stack changed.
set -euo pipefail
cd "$(dirname "$0")/../.."          # suite root
API=https://api.prf.192.168.0.210.nip.io
DEV=${1:-cnt-aligned-s1}

echo "== 1. assign cntfet + sifet -> prf-a (ModuleAssignment rows)"
pol topology assign cntfet prf-a
pol topology assign sifet prf-a
pol topology modules-env prf-a

echo "== 2. render + deploy the node stack (derived POLARI_MODULES)"
# The node compose interpolates these from the PROCESS env at render
# time (neither the suite .env nor pol state carries them):
#  - CNTFET_ENGINES_URL: cntfet compute (ngspice/OpenVAF/OpenSTA/kwant)
#    delegates to the cnt-engines swarm worker; unset = the backend
#    tries LOCAL binaries first (ngspice exists in the image, OpenVAF
#    does not) and cell characterization fails half-way.
#  - POL_STACK_CONSTRAINTS: pin the backend to this machine — its bind
#    mounts (ca/root_ca.crt) only exist here; without it swarm bounces
#    the task across nodes ("invalid mount config") until it lands.
export CNTFET_ENGINES_URL="${CNTFET_ENGINES_URL:-http://192.168.0.210:9700}"
export POL_STACK_CONSTRAINTS="${POL_STACK_CONSTRAINTS:-backend=node.labels.polari.machine==pol-core}"
pol swarm deploy node

echo "== 3. wait for the backend (boot ~4 min)"
for i in $(seq 1 120); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' "$API/api/cntfet/capability" || true)
  [ "$code" = 200 ] && { echo "   up after ~$((i*5))s"; break; }
  sleep 5
done
[ "$code" = 200 ] || { echo "backend never answered 200 on /api/cntfet/capability (last $code)"; exit 1; }

echo "== 4. verify"
curl -sk "$API/api/cntfet/device/$DEV/score?samples=100" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  score ok:", d.get("ok"), "| valid FET:", d.get("validity", {}).get("valid"), "| score:", d.get("score"), "| missing:", d.get("termsMissing"), "| err:", d.get("error"))
for t in d.get("idealTable", []):
    print(f"   {t['"'"'term'"'"']:22} actual={t['"'"'actual'"'"']!s:>10.10} ideal={t['"'"'ideal'"'"']!s:>10.10} norm={t['"'"'normalized'"'"']}")
mc = d.get("monteCarlo") or {}
print("  MC:", mc.get("sampleCount"), "samples | p05/p50/p95:", {k: round(v, 3) for k, v in (mc.get("quantiles") or {}).items() if k in ("p05","p50","p95")}, "| worst moved by:", (mc.get("worst") or {}).get("movedMostBy"))'
curl -sk "$API/api/cntfet/device/$DEV/cell-scores" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  cells ok:", d.get("ok"), "| run:", d.get("run"), "| ranking:", d.get("ranking"), "| err:", d.get("error"))'
curl -sk "$API/api/cntfet/device/$DEV/compare" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  compare ok:", d.get("ok"), "| ranking:", [(r["device"], r["score"], r["valid"]) for r in d.get("ranking", [])], "| err:", d.get("error"))' || true

echo "== 5. derive every comparator FET (unproven → real candidates) + sample the field scenes"
for d in $(curl -sk "$API/api/cntfet/devices" | python3 -c 'import sys,json; print(" ".join(x["name"] for x in json.load(sys.stdin)["devices"]))'); do
  printf "   %-24s derive: " "$d"
  curl -sk -X POST -H 'Content-Type: application/json' -d '{"action":"derive"}' "$API/api/cntfet/devices/$d" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("ok"), d.get("error",""))'
  printf "   %-24s fields: " "$d"
  curl -sk -X POST -H 'Content-Type: application/json' -d '{"action":"sample-fields"}' "$API/api/cntfet/devices/$d" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("ok"), d.get("rows", d.get("error","")), "rows")'
done

echo "== 5b. derive the silicon FETs (sol-gel + thermal oxide) so they compete"
for d in $(curl -sk "$API/api/sifet/devices" | python3 -c 'import sys,json; print(" ".join(x["name"] for x in json.load(sys.stdin).get("devices",[])))'); do
  printf "   %-30s derive: " "$d"
  curl -sk -X POST -H 'Content-Type: application/json' -d '{"action":"derive"}' "$API/api/sifet/devices/$d" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("ok"), d.get("error",""))'
done

echo "== 5c'. cell-library characterization on the engines worker (opt-in: CHARACTERIZE=1; ~30 min for 24 cells at drive 1)"
if [ "${CHARACTERIZE:-0}" = 1 ]; then
  curl -sk -m 3600 -X POST -H 'Content-Type: application/json' -d '{"action":"characterize-cells","drives":[1]}' "$API/api/cntfet/devices/$DEV" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  characterize:", d.get("ok"), d.get("error") or d.get("refusal") or "", "| cells", len(d.get("cells",[])), "| staGate", (d.get("staGate") or {}).get("accepted"), "| failures", len(d.get("failures",[])))'
else
  echo "  skipped (set CHARACTERIZE=1 to run; cell-scores / cell-power refuse by name until a run exists)"
fi

echo "== 5c. fp surfaces: power, taxonomy, logic proof, refinement"
curl -sk "$API/api/cntfet/device/$DEV/power" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  power: static W", (d.get("fet") or {}).get("static_w"), "| failing limits:", d.get("failing"), d.get("error",""))'
curl -sk "$API/api/cntfet/device/$DEV/taxonomy" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  taxonomy: suited to", (d.get("optimization") or {}).get("suited_to"), "| partner:", (d.get("complementary") or {}).get("partner", d.get("complementary")), d.get("error",""))'
curl -sk "$API/api/cntfet/cells/logic" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  cells: allProven", d.get("allProven"), "| cells:", len(d.get("combinational",[])), d.get("error",""))'
curl -sk "$API/api/sifet/refinement" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  refinement routes:", [(r.get("name"), r.get("openness"), (r.get("simulation") or {}).get("grade")) for r in d.get("routes",[])] if isinstance(d.get("routes"), list) else list(d)[:6])'
curl -sk "$API/api/cntfet/device/$DEV/compare" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  cross-tech ranking:", [(r["device"], r["score"]) for r in d.get("ranking",[])][:6])'

echo "== 6. fv surfaces on $DEV"
curl -sk "$API/api/cntfet/device/$DEV/regimes?vg=0.6&vd=0.6" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  regimes:", d.get("verdict") or d.get("error"))'
curl -sk "$API/api/cntfet/device/$DEV/transport?vg=0.6&vd=0.6" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  transport:", (d.get("regime") or {}).get("name"), "T=", d.get("transmission"), "top:", d.get("topContributor"), d.get("error",""))'
curl -sk "$API/api/cntfet/device/$DEV/characteristics" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  characteristics:", len(d.get("characteristics",[])), d.get("error",""))'
curl -sk "$API/api/cntfet/device/$DEV/characteristic/potential-at-instant" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  potential views:", [(v["title"], v["status"]) for v in d.get("views",[])], d.get("error",""))'

echo "== pages"
echo "   https://prf.192.168.0.210.nip.io/display/cntfet"
echo "   https://prf.192.168.0.210.nip.io/display/cntfet-score-$DEV     (competitive ranking)"
echo "   https://prf.192.168.0.210.nip.io/display/cntfet-detail-$DEV    (characteristic explorer + 3-D field scenes)"
echo "   https://prf.192.168.0.210.nip.io/display/cntfet-cells           (logic diagrams + schematics, step-through proofs — 19 cells)"
echo "   https://prf.192.168.0.210.nip.io/display/sifet                  (silicon FETs on sol-gel: devices, pairs, cross-tech ranking, refinement)"
echo "   https://prf.192.168.0.210.nip.io/display/cntfet-detail-si-nmos-planar-90   (a silicon FET's detail page)"
