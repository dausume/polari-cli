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
    from cntfet.cnt_cell_pages import SEED_CELL_PAGES
    seeds += list(SEED_CELL_PAGES)
except ImportError:
    pass
try:
    from cntfet.cnt_block_pages import SEED_BLOCK_PAGES
    seeds += list(SEED_BLOCK_PAGES)
except ImportError:
    pass
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
    from cntfet.cnt_scene import SEED_CNT_DEVICE_SCENES
    from sifet.si_pages_seed import SI_DEVICE_NAMES as _sin
    from sifet.si_scene import SEED_SI_DEVICE_SCENES
    scene_seeds = (SEED_FET_2D_SCENES(names + list(_sin))
                   + SEED_CNT_DEVICE_SCENES(names)
                   + SEED_SI_DEVICE_SCENES(list(_sin)))
except ImportError as exc:
    scene_seeds = []
    print(f'scene seeds unavailable ({exc}) — skipping scene sync')
sc_live = live_scenes()
sc_updated, sc_same, sc_missing = [], [], []
for s in scene_seeds:
    row = sc_live.get(s['name'])
    if row is None:
        sc_missing.append(s['name']); continue
    same = (json.loads(row.get('definition') or '{}')
            == json.loads(s['definition'])
            and json.loads(row.get('viewport_json') or '{}')
            == json.loads(s.get('viewport_json') or '{}')
            and json.loads(row.get('camera_json') or '{}')
            == json.loads(s.get('camera_json') or '{}'))
    if same:
        sc_same.append(s['name']); continue
    pid = row.get('id') or row.get('polariId')
    curl('-X', 'PUT', f'{API}/SimSpaceDefinition', '--form-string', f'polariId={pid}',
         '--form-string', 'updateData=' + json.dumps(
             {'definition': s['definition'],
              'viewport_json': s['viewport_json'],
              'camera_json': s.get('camera_json', ''),
              'description': s['description']}))
    sc_updated.append(s['name'])
print(f'scenes: backfilled {len(sc_updated)}, unchanged {len(sc_same)}, '
      f'missing (seed on next boot) {len(sc_missing)}')

# fg-6b: sync the fet-part-* MathShapeDefinition rows (the CSG shell
# triplets became single annular_sector primitives) + list orphans.
def live_shapes():
    data = json.loads(curl(f'{API}/MathShapeDefinition'))
    return {r['name']: r for w in data
            for b in w.get('MathShapeDefinition', [])
            for r in b.get('data', [])}

try:
    from cntfet.cnt_scene import part_shape_seeds
    from sifet.si_scene import part_shape_seeds_si
    shape_seeds = ([sh for n2 in names for sh in part_shape_seeds(n2)]
                   + [sh for n2 in list(_sin)
                      for sh in part_shape_seeds_si(n2)])
except ImportError as exc:
    shape_seeds = []
    print(f'shape seeds unavailable ({exc}) — skipping shape sync')
if shape_seeds:
    sh_live = live_shapes()
    sh_up, sh_same, sh_miss = [], [], []
    KEYS = ('family', 'primitive_kind', 'parameters_json', 'csg_json',
            'bounds_json', 'notes')
    for s in shape_seeds:
        row = sh_live.get(s['name'])
        if row is None:
            sh_miss.append(s['name']); continue
        if all(str(row.get(k) or '') == str(s.get(k) or '')
               for k in KEYS):
            sh_same.append(s['name']); continue
        pid = row.get('id') or row.get('polariId')
        curl('-X', 'PUT', f'{API}/MathShapeDefinition',
             '--form-string', f'polariId={pid}',
             '--form-string',
             'updateData=' + json.dumps({k: s.get(k, '') for k in KEYS}))
        sh_up.append(s['name'])
    orphans = sorted(n for n in sh_live
                     if n.startswith('fet-part-')
                     and (n.endswith('-outer') or n.endswith('-inner')))
    print(f'shapes: backfilled {len(sh_up)}, unchanged {len(sh_same)}, '
          f'missing (seed on next boot) {len(sh_miss)}; '
          f'orphaned shell components: {len(orphans)}')
    if orphans and os.environ.get('CONFIRM_DELETE_LEGACY') == 'yes':
        import os as _os  # noqa: F401 (os imported below too)
        for n in orphans:
            pid = sh_live[n].get('id') or sh_live[n].get('polariId')
            curl('-X', 'DELETE', f'{API}/MathShapeDefinition',
                 '--form-string',
                 'targetInstance=' + json.dumps({'id': pid}))
        print(f'deleted {len(orphans)} orphaned shell component(s)')
    elif orphans:
        for n in orphans: print('  orphan-shape', n)

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
