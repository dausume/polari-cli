#!/usr/bin/env python3
"""checkout_module_closure.py — topo-closure-1 / mod-env-4.

`pol topology modules-env <instance>` (and the swarm render path that reads it,
scripts/lib/core-api.sh's resolve_polari_modules) asks the RUNNING backend to
compute the requires-closure of an instance's assigned modules. That backend
answers from the manifests baked into its OWN (possibly old) image — a module
assigned on a newer checkout but absent from that image contributes NO
requires at all, so a real dependency (e.g. hwnocode -> grpcbridge) silently
drops out of POLARI_MODULES (found live: `pol topology modules-env prf-a`
missed `grpcbridge`, required by `hwnocode`, because the deployed image
predates both).

This module recomputes the SAME closure from the CHECKOUT currently on disk —
modules/polari-modules.json (every module's own top-level `requires` list) AND
each module's own polari-app.json (`requires.modules`, which wins when
present — it is the more precise, per-module-owned source) — and unions it
with whatever the running backend already resolved. Every module the checkout
closure adds that the backend did not already know about is reported by name
and by what required it, so the gap is visible instead of silent.

CLI:
    checkout_module_closure.py <modules_dir> <assigned_csv> <backend_env_csv>
        -> prints ONE JSON object to stdout:
           {"full": [...sorted union...],
            "added_by_checkout": {module: [requires chain], ...}}
        assigned_csv / backend_env_csv may be empty strings.

Pure functions (`requires_map_from_checkout`, `closure`, `union_with_backend`)
are also importable for the selftest and for in-process callers.
"""
import json
import os
import sys


def requires_map_from_checkout(modules_dir):
    """{module: set(required modules)} — per-module polari-app.json wins;
    modules/polari-modules.json's own `requires` list fills in the rest
    (a module not yet split into its own polari-app.json, or whose
    checkout is partial)."""
    requires = {}
    pm_path = os.path.join(modules_dir, 'polari-modules.json')
    if os.path.isfile(pm_path):
        try:
            pm = json.load(open(pm_path))
        except Exception:
            pm = {}
        for name, info in (pm.get('modules') or {}).items():
            if isinstance(info, dict) and info.get('requires'):
                requires.setdefault(name, set()).update(info['requires'])
    if os.path.isdir(modules_dir):
        for name in sorted(os.listdir(modules_dir)):
            app_path = os.path.join(modules_dir, name, 'polari-app.json')
            if not os.path.isfile(app_path):
                continue
            try:
                app = json.load(open(app_path))
            except Exception:
                continue
            req = ((app.get('requires') or {}).get('modules')) if isinstance(app.get('requires'), dict) else None
            if req:
                requires[name] = set(req)   # the module's own manifest is authoritative over polari-modules.json's mirror
    return requires


def closure(assigned, requires_map):
    """Transitive requires-closure of `assigned` against `requires_map`.
    Returns (full_set, added: {module: [chain of modules that pulled it in]})."""
    full = set(assigned)
    added = {}
    changed = True
    while changed:
        changed = False
        for mod in list(full):
            for req in requires_map.get(mod, ()):
                if req not in full:
                    full.add(req)
                    added.setdefault(req, []).append(mod)
                    changed = True
    return full, added


def union_with_backend(modules_dir, assigned, backend_env):
    """The fix: union the backend's own resolved env with the SAME closure
    recomputed from the checkout's manifests. `added_by_checkout` names only
    the modules the checkout closure contributes that the backend's own env
    did not already carry — the honest WARN list."""
    requires_map = requires_map_from_checkout(modules_dir)
    checkout_full, checkout_added = closure(assigned, requires_map)
    backend_set = set(backend_env)
    full = backend_set | checkout_full
    added_by_checkout = {m: chain for m, chain in checkout_added.items() if m not in backend_set}
    return full, added_by_checkout


def main(argv):
    if len(argv) != 3:
        print('usage: checkout_module_closure.py <modules_dir> <assigned_csv> <backend_env_csv>', file=sys.stderr)
        return 2
    modules_dir, assigned_csv, backend_env_csv = argv
    assigned = [m for m in assigned_csv.split(',') if m]
    backend_env = [m for m in backend_env_csv.split(',') if m]
    full, added = union_with_backend(modules_dir, assigned, backend_env)
    json.dump({'full': sorted(full), 'added_by_checkout': {k: sorted(v) for k, v in added.items()}}, sys.stdout)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
