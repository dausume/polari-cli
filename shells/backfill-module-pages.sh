#!/usr/bin/env bash
# DisplayDefinition seeds are INSERT-BY-NAME: editing a page seed never
# reaches an already-seeded live row. This backfills every module page
# whose api-json-panel items became api-structured-panel (Dustin: "there
# should not be any json showing on the screens") from the seed modules
# via CRUDE PUT, diffing each row back before claiming it. Covers
# module_pages_seed (nutrition / vermicompost / tanks / biomining /
# microalgae / wax / supply-chain / morphology / zones / authority),
# computers, climate, the cntfet home + cells + blocks + per-device
# score/detail pages and the sifet pages. Safe to re-run (no-op when
# identical). Pages whose module is not assigned on this node are
# listed as "missing" (they seed on that node's next boot).
#   ssh pol-core 'bash ~/Desktop/polari-suite/polari-cli/shells/backfill-module-pages.sh'
set -euo pipefail
API=${1:-https://api.prf.192.168.0.210.nip.io}
FW=~/Desktop/polari-suite/polari-rf-node/polari-framework
cd "$FW/modules"
PYTHONPATH=..:../polariApiServer python3 - "$API" <<'EOF'
import json, subprocess, sys
API = sys.argv[1]
from polariApiServer.module_pages_seed import SEED_MODULE_PAGE_DISPLAYS
seeds = list(SEED_MODULE_PAGE_DISPLAYS)
skipped = []
try:
    from computers.computers_page import SEED_COMPUTERS_PAGE_DISPLAYS
    seeds += list(SEED_COMPUTERS_PAGE_DISPLAYS)
except ImportError as exc:
    skipped.append(f'computers ({exc})')
try:
    from climate.climate_page import (SEED_CLIMATE_PAGE_DISPLAYS,
                                       SEED_CLIMATE_ERA_DISPLAYS)
    seeds += list(SEED_CLIMATE_PAGE_DISPLAYS) + list(SEED_CLIMATE_ERA_DISPLAYS)
except ImportError as exc:
    skipped.append(f'climate ({exc})')
try:
    from cntfet.cnt_page import SEED_CNTFET_PAGE_DISPLAYS
    from cntfet.cnt_basis import SEED_CNT_DEVICES
    from cntfet.custom.cnt_compare import score_pages, detail_pages
    seeds += list(SEED_CNTFET_PAGE_DISPLAYS)
    names = [d['name'] for d in SEED_CNT_DEVICES]
    seeds += score_pages(names) + detail_pages(names)
except ImportError as exc:
    skipped.append(f'cntfet ({exc})')
try:
    from cntfet.cnt_blocks_page import SEED_BLOCK_PAGES
    seeds += list(SEED_BLOCK_PAGES)
except ImportError as exc:
    skipped.append(f'cntfet blocks ({exc})')
try:
    from sifet.si_page import SEED_SI_PAGE_DISPLAYS, SEED_SI_SCORE_PAGES
    seeds += list(SEED_SI_PAGE_DISPLAYS) + list(SEED_SI_SCORE_PAGES)
except ImportError as exc:
    skipped.append(f'sifet ({exc})')
try:
    from appstore.appstore_page import SEED_APPSTORE_PAGE_DISPLAYS
    seeds += list(SEED_APPSTORE_PAGE_DISPLAYS)
except ImportError as exc:
    skipped.append(f'appstore ({exc})')
try:
    from islemesh.islemesh_page import SEED_ISLEMESH_PAGE_DISPLAYS
    seeds += list(SEED_ISLEMESH_PAGE_DISPLAYS)
except ImportError as exc:
    skipped.append(f'islemesh ({exc})')
try:
    from cntfet.cnt_open_library_page import SEED_OPEN_LIBRARY_PAGES
    seeds += list(SEED_OPEN_LIBRARY_PAGES)
except ImportError as exc:
    skipped.append(f'cntfet open-library ({exc})')
for s in skipped:
    print(f'seed module unavailable — skipping: {s}')

def curl(*args):
    return subprocess.run(['curl', '-sk', *args], capture_output=True, text=True).stdout

def live_rows():
    data = json.loads(curl(f'{API}/DisplayDefinition'))
    return {r['name']: r for w in data for b in w.get('DisplayDefinition', [])
            for r in b.get('data', [])}

# fg-2 generic `fet-detail` page: its emitter (cntfet.custom.cnt_compare
# fet_detail seed) lives on dev-fg-1, not necessarily on the checked-out
# branch, and its links panel is an api-json-panel over the /api/fet
# alias (404 until that branch's image rolls). When no seed for it is
# importable, rewrite the LIVE row in place: api-json-panel →
# api-structured-panel, pick='pages', path repointed to the
# /api/cntfet/device/{object}/links route that IS live. Same PUT+diff
# idiom — the rewritten row joins `seeds`. Once dev-fg-1's seed carries
# _sapi(..., pick='pages') this block is a no-op (the seed wins).
def _structured_links(item):
    cp = item.get('componentProps') or {}
    if cp.get('componentName') != 'api-json-panel':
        return False
    path = (cp.get('inputs') or {}).get('path', '')
    if not path.endswith('/links'):
        return False
    path = path.replace('/api/fet/device/', '/api/cntfet/device/')
    item['componentProps'] = {
        'componentName': 'api-structured-panel',
        'inputs': {'path': path, 'pick': 'pages', 'hideKeys': '',
                   'title': ''}}
    return True

if 'fet-detail' not in {s['name'] for s in seeds}:
    live_fd = live_rows().get('fet-detail')
    if live_fd is not None:
        defn = json.loads(live_fd['definition'])
        changed = [_structured_links(i) for r in defn.get('rows') or []
                   for i in (r.get('items') or [])]
        if any(changed):
            seeds.append({'name': 'fet-detail',
                          'description': live_fd.get('description', ''),
                          'definition': json.dumps(defn)})
            print('fet-detail: no seed on this branch — rewriting the live '
                  f'links panel in place ({sum(changed)} item(s))')

def json_panels(defn):
    try:
        rows = json.loads(defn or '{}').get('rows') or []
    except (TypeError, ValueError):
        return 0
    return sum(1 for r in rows for i in (r.get('items') or [])
               if (i.get('componentProps') or {}).get('componentName')
               == 'api-json-panel')

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
# the point of the exercise: no api-json-panel left on any live page
# this script owns (other live pages are listed, not touched).
owned = {s['name'] for s in seeds}
left = {n: json_panels(r['definition']) for n, r in after.items()
        if json_panels(r['definition'])}
print(f'live pages still carrying api-json-panel: {len(left)} '
      f'(owned by this script: {len([n for n in left if n in owned])})')
for n, c in sorted(left.items()):
    print(f'  json-panel x{c}', n, '' if n in owned else '(not owned here)')
sys.exit(1 if bad else 0)
EOF
