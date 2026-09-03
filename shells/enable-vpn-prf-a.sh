#!/usr/bin/env bash
# Enable the vpn module (isle-vpn mirror + proposal inbox, vpn-1) on
# prf-a (rows are the truth; islemesh rides in through requires),
# re-render + roll the node stack, wait for boot, and verify the
# /api/vpn surfaces with the two-isle mock demo. Unattended — safe
# over ssh:
#   ssh pol-core 'bash ~/Desktop/polari-suite/polari-cli/shells/enable-vpn-prf-a.sh'
# Re-runnable: assign is idempotent-by-name; deploy re-rolls only when
# the rendered stack changed. BUILD=1 rebuilds prf-backend:staging first
# (the swarm respawns from the IMAGE — code changes need the build).
set -euo pipefail
cd "$(dirname "$0")/../.."          # suite root
API=https://api.prf.192.168.0.210.nip.io

if [ "${VERIFY_ONLY:-0}" != 1 ]; then
  echo "== 1. assign vpn + islemesh -> prf-a (ModuleAssignment rows; the running"
  echo "      core's registry may predate vpn, so the requires-closure is made explicit)"
  pol topology assign vpn prf-a
  pol topology assign islemesh prf-a
  pol topology modules-env prf-a

  if [ "${BUILD:-0}" = 1 ]; then
    echo "== 1b. build prf-backend:staging (the module is baked into the image)"
    pol node build backend --env staging
  fi

  echo "== 2. render + deploy the node stack (derived POLARI_MODULES)"
  export CNTFET_ENGINES_URL="${CNTFET_ENGINES_URL:-http://192.168.0.210:9700}"
  export POL_STACK_CONSTRAINTS="${POL_STACK_CONSTRAINTS:-backend=node.labels.polari.machine==pol-core}"
  pol swarm deploy node
  if [ "${FORCE_ROLL:-0}" = 1 ]; then
    docker service update --force --image prf-backend:staging polari-node_backend
  fi
fi

echo "== 3. wait for the backend (a 21-module boot takes ~15 min on pol-core:"
echo "      the class registration cycles once per admitted module — normal)"
code=000
for i in $(seq 1 360); do
  code=$(curl -sk -o /dev/null -w '%{http_code}' "$API/api/vpn/kinds" || true)
  [ "$code" = 200 ] && { echo "   up after ~$((i*5))s"; break; }
  sleep 5
done
[ "$code" = 200 ] || { echo "backend never answered 200 on /api/vpn/kinds (last $code)"; exit 1; }

echo "== 4. verify the read surface"
curl -sk "$API/api/vpn/kinds" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  kinds:", len(d.get("kinds", [])), "| family:", d.get("family"))
for k in d.get("kinds", []):
    print("   %-20s %-14s %-12s %s" % (k["kind"], k["title"], k["line"], k["label"]))'
curl -sk "$API/api/islemesh/catalog" | python3 -c '
import sys, json
d = json.load(sys.stdin)
vpn = [e for e in d.get("entries", []) if e.get("kind") == "isle-vpn"]
print("  catalog isle-vpn listings:", len(vpn), "| gateway engines:", sorted(e["name"] for e in vpn if e.get("provides_engine")))'

echo "== 5. the two-isle mock demo (acceptance flow, every payload mock-flagged)"
curl -sk -X POST -H 'Content-Type: application/json' -d '{}' "$API/api/vpn/demo" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for s in d.get("steps", []):
    print("   ", "PASS" if s["pass"] else "FAIL", s["step"], ("— " + s["detail"]) if (s.get("detail") and not s["pass"]) else "")
print("  all_pass:", d.get("all_pass"))
sys.exit(0 if d.get("all_pass") else 1)'

echo "== 6. matrix + exposure options + isle-mesh .vpn column"
curl -sk "$API/api/vpn/matrix" | python3 -c '
import sys, json
for r in json.load(sys.stdin).get("matrix", []):
    print("   %-8s %-18s %-12s rung=%s nets=%s vpn=%s" % (r["isle"], r["app_kind"], r["label"], r["vpn_rung"], r["networks"], r["vpn_names"]))'
curl -sk "$API/api/vpn/exposure-options?device=isle-a" | python3 -c '
import sys, json
d = json.load(sys.stdin); print("  isle-a options:", d.get("options"))'
curl -sk "$API/api/vpn/exposure-options?device=isle-c" | python3 -c '
import sys, json
d = json.load(sys.stdin); print("  isle-c options:", d.get("options"), "(no .vpn: Link Node)")'
curl -sk "$API/api/islemesh/matrix" | python3 -c '
import sys, json
m = json.load(sys.stdin).get("matrix", {})
rows = [(dev, p["app"], p.get("vpn"), p.get("vpn_label")) for dev, ps in m.items() for p in ps if p.get("vpn")]
print("  isle-mesh matrix rows with a .vpn name:", rows)'

echo "== 7. private-key sweep over the CRUDE export of every vpn class"
for cls in VpnNetwork VpnPeer VpnAccessRule VpnFederationLink AppVpnExposure VpnProposal; do
  n=$(curl -sk "$API/$cls" | grep -ciE 'private_key|preshared_key|PrivateKey *= *[A-Za-z0-9+/]{43}=' || true)
  printf "   %-20s key-material hits: %s\n" "$cls" "$n"
done

echo "== pages"
echo "   https://prf.192.168.0.210.nip.io/display/vpn"
echo "   https://prf.192.168.0.210.nip.io/display/isle-mesh   (.vpn column in the protocol matrix)"
