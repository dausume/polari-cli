#!/usr/bin/env bash
# DisplayDefinition seeds are INSERT-BY-NAME: editing a page seed never
# reaches an already-seeded live row. This backfills every cntfet /
# sifet page from the seed modules via CRUDE PUT, diffing each row back
# before claiming it. Safe to re-run (no-op when identical).
#   ssh pol-core 'bash ~/Desktop/polari-suite/polari-cli/shells/backfill-cntfet-pages.sh'
set -euo pipefail
API=${1:-https://api.prf.192.168.0.210.nip.io}
FW=~/Desktop/polari-suite/polari-rf-node/polari-framework
cd "$FW/modules"
PYTHONPATH=..:../polariApiServer python3 - "$API" <<'EOF'
import json, subprocess, sys
API = sys.argv[1]
from cntfet.cnt_pages_seed import SEED_CNTFET_PAGE_DISPLAYS
from cntfet.cnt_basis import SEED_CNT_DEVICES
from cntfet.cnt_compare import score_pages, detail_pages
seeds = list(SEED_CNTFET_PAGE_DISPLAYS)
names = [d['name'] for d in SEED_CNT_DEVICES]
seeds += score_pages(names) + detail_pages(names)
try:
    from sifet.si_pages_seed import SEED_SI_PAGE_DISPLAYS, SEED_SI_SCORE_PAGES
    seeds += list(SEED_SI_PAGE_DISPLAYS) + list(SEED_SI_SCORE_PAGES)
except ImportError:
    pass

def curl(*args):
    return subprocess.run(['curl', '-sk', *args], capture_output=True, text=True).stdout

def live_rows():
    data = json.loads(curl(f'{API}/DisplayDefinition'))
    return {r['name']: r for w in data for b in w.get('DisplayDefinition', [])
            for r in b.get('data', [])}

live = live_rows()
updated, same, missing = [], [], []
for s in seeds:
    row = live.get(s['name'])
    if row is None:
        missing.append(s['name']); continue
    if json.loads(row['definition']) == json.loads(s['definition']):
        same.append(s['name']); continue
    pid = row.get('id') or row.get('polariId')
    curl('-X', 'PUT', f'{API}/DisplayDefinition', '--form-string', f'polariId={pid}',
         '--form-string', 'updateData=' + json.dumps(
             {'definition': s['definition'], 'description': s['description']}))
    updated.append(s['name'])
after = live_rows()
bad = [n for n in updated if json.loads(after[n]['definition']) != json.loads(
    next(s for s in seeds if s['name'] == n)['definition'])]
print(f'backfilled {len(updated)} page(s), unchanged {len(same)}, '
      f'missing on node (seed on next boot) {len(missing)}, diff-mismatch {bad}')
for n in updated: print('  updated', n)
for n in missing: print('  missing', n)
sys.exit(1 if bad else 0)
EOF
