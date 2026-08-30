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

# fg-6: sync the fet-2d-* SimSpaceDefinition rows (their definitions
# changed when the gray-viewport scale bug was fixed) — same
# PUT-diff-verify pattern as the pages; new fet-3d-* rows seed at boot.
def live_scenes():
    data = json.loads(curl(f'{API}/SimSpaceDefinition'))
    return {r['name']: r for w in data for b in w.get('SimSpaceDefinition', [])
            for r in b.get('data', [])}

try:
    from cntfet.cnt_parts_svg import SEED_FET_2D_SCENES
    from sifet.si_pages_seed import SI_DEVICE_NAMES as _sin
    scene_seeds = SEED_FET_2D_SCENES(names + list(_sin))
except ImportError as exc:
    scene_seeds = []
    print(f'scene seeds unavailable ({exc}) — skipping scene sync')
sc_live = live_scenes()
sc_updated, sc_same, sc_missing = [], [], []
for s in scene_seeds:
    row = sc_live.get(s['name'])
    if row is None:
        sc_missing.append(s['name']); continue
    if json.loads(row.get('definition') or '{}') == json.loads(s['definition']):
        sc_same.append(s['name']); continue
    pid = row.get('id') or row.get('polariId')
    curl('-X', 'PUT', f'{API}/SimSpaceDefinition', '--form-string', f'polariId={pid}',
         '--form-string', 'updateData=' + json.dumps(
             {'definition': s['definition'],
              'viewport_json': s['viewport_json'],
              'description': s['description']}))
    sc_updated.append(s['name'])
print(f'scenes: backfilled {len(sc_updated)}, unchanged {len(sc_same)}, '
      f'missing (seed on next boot) {len(sc_missing)}')

# fg-2: the per-device pages the generic fet / fet-detail ones
# replace — ALWAYS listed, deleted only with CONFIRM_DELETE_LEGACY=yes
# (plan decision 2), and only after the generic pages are live.
import os
from cntfet.cnt_compare import legacy_page_names
try:
    from sifet.si_pages_seed import SI_DEVICE_NAMES
except ImportError:
    SI_DEVICE_NAMES = []
legacy = [n for n in legacy_page_names(names + list(SI_DEVICE_NAMES))
          if n in after]
# fg-6 scene rename: the old cnt-device-3d-* rows the fet-3d-* ones
# replace — same list-always / delete-only-confirmed treatment.
legacy_scenes = sorted(n for n in live_scenes()
                       if n.startswith('cnt-device-3d-'))
print(f'legacy 3-D scene rows (renamed to fet-3d-*): '
      f'{len(legacy_scenes)}')
for n in legacy_scenes: print('  legacy-scene', n)
if legacy_scenes and os.environ.get('CONFIRM_DELETE_LEGACY') == 'yes':
    sl = live_scenes()
    for n in legacy_scenes:
        pid = sl[n].get('id') or sl[n].get('polariId')
        curl('-X', 'DELETE', f'{API}/SimSpaceDefinition',
             '--form-string', 'targetInstance=' + json.dumps({'id': pid}))
    left = [n for n in legacy_scenes if n in live_scenes()]
    print(f'deleted {len(legacy_scenes) - len(left)} legacy scene(s); '
          f'still live: {left or "none"}')
generic_live = all(n in after for n in ('fet', 'fet-detail'))
print(f'legacy per-device pages live: {len(legacy)} '
      f'(generic pages live: {generic_live})')
for n in legacy: print('  legacy', n)
if legacy and os.environ.get('CONFIRM_DELETE_LEGACY') == 'yes':
    if not generic_live:
        print('  REFUSING to delete: the generic fet/fet-detail rows '
              'are not live yet (roll the image first)')
        sys.exit(1)
    for n in legacy:
        pid = after[n].get('id') or after[n].get('polariId')
        curl('-X', 'DELETE', f'{API}/DisplayDefinition',
             '--form-string', 'targetInstance=' + json.dumps({'id': pid}))
    remaining = [n for n in legacy if n in live_rows()]
    print(f'deleted {len(legacy) - len(remaining)} legacy page(s); '
          f'still live: {remaining or "none"}')
elif legacy:
    print('  (kept — re-run with CONFIRM_DELETE_LEGACY=yes after '
          'verifying the generic pages in the browser)')
sys.exit(1 if bad else 0)
EOF
