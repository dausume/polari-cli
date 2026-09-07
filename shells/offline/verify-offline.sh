#!/bin/bash
# verify-offline.sh <medium> — marker + manifest + every section present
# + SHA256SUMS clean. Exit 0 only when the medium is trustworthy to read.
set -eu
POOL="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fail(){ echo "[FAIL] $*" >&2; exit 1; }
[ -f "$POOL/ISLE_OFFLINE_BUNDLE" ] || fail "no ISLE_OFFLINE_BUNDLE marker in $POOL"
[ -f "$POOL/manifest.json" ] || fail "no manifest.json"
[ -f "$POOL/SHA256SUMS" ] || fail "no SHA256SUMS"
for s in debs apt images router modules engines hardware scripts; do
    [ -d "$POOL/$s" ] || fail "section directory missing: $s/ (every section must exist; empty ones carry an EMPTY file)"
done
( cd "$POOL" && sha256sum --quiet -c SHA256SUMS ) || fail "SHA256SUMS mismatch — do not install from this medium"
python3 - "$POOL/manifest.json" <<'PY' || fail "manifest does not parse"
import json, sys
m = json.load(open(sys.argv[1]))
assert m.get('flavor') == 'offline', 'manifest flavor is not offline'
print('   Polari %s  flavor=%s  target=%s  built %s on %s' % (
    m['polari'], m['flavor'], m.get('target'), m.get('builtAt'), m.get('builtOn')))
for name, sec in m['sections'].items():
    print('   %-9s %s' % (name, ('%d files, %.1f MB' % (sec['files'], sec['bytes'] / 1e6))
                          if sec['present'] else 'EMPTY — ' + sec.get('emptyReason', '')))
PY
echo "[ OK ] medium verified: $POOL"
