#!/bin/bash
# install-app-offline.sh <module> — install a module's OFFLINE app deb
# from the medium's modules/ section, then admit it into the running
# lean polari (prf-isle) from the image. Honest about what each step is:
# the deb STAGES (/var/lib/polari/apps/<m>, wheels inside), admission
# goes live from the running image (memory: module debs = staging only
# today). Never fetches.
set -eu
M="${1:-}"; [ -n "$M" ] || { echo "usage: sudo bash install-app-offline.sh <module>" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
POOL=$(cat /etc/polari/offline-source 2>/dev/null || true)
[ -n "$POOL" ] && [ -d "$POOL/modules" ] || { echo "[REFUSED] no offline source recorded (/etc/polari/offline-source) — run install-offline.sh first" >&2; exit 2; }
[ "$(cat /etc/polari/install-mode 2>/dev/null)" = offline ] || { echo "[REFUSED] install-mode is not offline" >&2; exit 2; }
DEB=$(ls "$POOL"/modules/polari-app-"$M"-offline_*.deb 2>/dev/null | sort -V | tail -1 || true)
[ -n "$DEB" ] || { echo "[REFUSED] offline: polari-app-$M-offline is not on the medium (section modules/) — add it to the bundle or install the online package" >&2; exit 2; }
dpkg -i "$DEB" && echo "[ OK ] staged $(basename "$DEB") → /var/lib/polari/apps/$M"
python3 -c "import json;m=json.load(open('/var/lib/polari/apps/$M/manifest.json'));print('   manifest: flavor=%s wheels=%s engines=%s' % (m.get('flavor'), m.get('delivery',{}).get('wheels', []), m.get('requires',{}).get('engines', [])))" 2>/dev/null || true
CURL="curl -sk --max-time 20 --resolve api.polari.isle:443:127.0.0.1"
if $CURL -o /dev/null -w '%{http_code}' https://api.polari.isle/api/health 2>/dev/null | grep -q '^200$'; then
    echo "==> admitting $M into prf-isle (from the running image — the live path)"
    R=$($CURL -X POST -H 'Content-Type: application/json' -d '{}' "https://api.polari.isle/modules/$M/admit" || true)
    echo "$R" | python3 -c "import json,sys; d=json.load(sys.stdin); print('   admit:', 'OK' if d.get('ok', True) and not d.get('error') else 'REFUSED', '-', d.get('message') or d.get('error') or d.get('status') or d)" 2>/dev/null || echo "   admit reply: $R"
    echo "   persists across a backend restart only when the module is in POLARI_ISLE_MODULES (isle-polari-deploy --modules ...,$M)"
else
    echo "[WARN] prf-isle not answering (no isle yet?) — staged only; admit after 'isle core-install': curl -sk -X POST -d '{}' https://api.polari.isle/modules/$M/admit"
fi
