#!/bin/bash
# reticulum-enable.sh — the Reticulum ENGINE for an isle: load the sidecar
# image (from engines/ when offline), run it beside prf-isle, point the
# backend at it (RETICULUM_URL) and put the reticulum module in the boot
# set so it survives restarts. Idempotent. Run as the isle user with sudo.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok(){ echo "[ OK ] $*"; }
if ! docker image inspect pol-reticulum:staging >/dev/null 2>&1; then
    TAR=$(ls "$HERE"/pol-reticulum_*.tar 2>/dev/null | head -1 || true)
    [ -n "$TAR" ] || { echo "[REFUSED] pol-reticulum:staging not loaded and no tarball beside this script (section engines/)" >&2; exit 2; }
    docker load -q -i "$TAR" >/dev/null && ok "loaded pol-reticulum:staging from $(basename "$TAR")"
fi
docker network inspect isle-agent-net >/dev/null 2>&1 || { echo "[REFUSED] no isle-agent-net — the isle is not created yet (isle core-install)" >&2; exit 2; }
docker compose -p pol-reticulum -f "$HERE/reticulum-isle.yml" up -d >/dev/null && ok "pol-reticulum up (4242 bearer, 4285 status)"
for i in $(seq 1 20); do curl -sf --max-time 2 http://127.0.0.1:4285/status >/dev/null 2>&1 && break; sleep 1; done
curl -sf --max-time 3 http://127.0.0.1:4285/status | python3 -c "
import json,sys; s=json.load(sys.stdin)
print('   identity', s['identityHash'][:16], ' rns', s['rnsVersion'], ' pins', s['stackPins'])
print('   interfaces:', ', '.join('%s(%s)' % (i['name'], 'up' if i['online'] else 'down') for i in s['interfaces']))
print('   lxmf:', {k: v for k, v in s.get('lxmf', {}).items() if k in ('deliveryHash','destinationHash','stored','ok')})" || echo "[WARN] sidecar status not answering yet"
# point prf-isle's backend at the sidecar + keep reticulum in the boot set
DIR="$HOME/polari-isle"; [ -f "$DIR/docker-compose.yml" ] || DIR=/home/$(logname 2>/dev/null || echo "$SUDO_USER")/polari-isle
[ -f "$DIR/docker-compose.yml" ] || { echo "[WARN] no ~/polari-isle compose — backend not repointed (set RETICULUM_URL yourself)"; exit 0; }
cat > "$DIR/docker-compose.override.yml" <<YML
services:
  backend:
    environment:
      - RETICULUM_URL=http://pol-reticulum:4285
YML
CUR=$(docker inspect prf-isle-backend --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^POLARI_MODULES=' | cut -d= -f2)
CUR="${CUR:-islemesh}"
case ",$CUR," in *,reticulum,*) MODS="$CUR" ;; *) MODS="$CUR,reticulum" ;; esac
( cd "$DIR" && POLARI_ISLE_MODULES="$MODS" docker compose up -d backend >/dev/null ) && ok "prf-isle backend re-upped with RETICULUM_URL + modules=$MODS (lean boot ≈ 30–90 s)"
for i in $(seq 1 60); do curl -sk --max-time 3 --resolve api.polari.isle:443:127.0.0.1 https://api.polari.isle/api/reticulum/capability 2>/dev/null | grep -q '"ok"' && break; sleep 3; done
curl -sk --max-time 5 --resolve api.polari.isle:443:127.0.0.1 https://api.polari.isle/api/reticulum/capability | python3 -c "
import json,sys; d=json.load(sys.stdin); print('   backend capability:', json.dumps({k: d[k] for k in d if k in ('ok','sidecar','reachable','pins','stackPins','archHonesty','error')})[:400])" || echo "[WARN] backend capability not answering yet — retry: curl -sk https://api.polari.isle/api/reticulum/capability"
