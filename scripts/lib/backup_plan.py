#!/usr/bin/env python3
"""pol backup plan [--target <mount point>] [--table]   read-only, for anyone

What a device-backup (one backup of this machine, taken at one time) would hold: the named Docker volumes of Polari, the isle's settings and
state, what is left out and why, the sizes, and whether the target could take it.  Nothing is copied, stopped
or written.  The other verbs (create, list, verify, restore) are not built yet; see AI-Notes/plans/BACKUP_PLAN.md.
"""
import argparse
from datetime import datetime, timezone
import json
import os
import re
import shutil
import socket
import subprocess
import sys

NOT_BUILT = ('create', 'list', 'verify', 'restore')
ANONYMOUS = re.compile(r'^[0-9a-f]{64}$')
# first match wins: (volume name pattern, kind, how it is taken while in use, how while not in use)
VOLUME_RULES = (
    (re.compile(r'odoo-db-data$'), 'odoo-database', 'pol odoo backup', 'plain copy of the volume'),
    (re.compile(r'odoo-filestore$'), 'odoo-files', 'archive of the volume', 'archive of the volume'),
    (re.compile(r'(mariadb-data|kc_lean_db)$'), 'mariadb', 'dump inside one transaction', 'plain copy of the volume'),
    (re.compile(r'(backend-data|prf_lean_data)$'), 'instance-data', 'write gate up, copy, gate down', 'plain copy of the volume'),
    (re.compile(r'file-store-data$'), 'file-store', 'archive of the volume', 'archive of the volume'),
    (re.compile(r'forge-data$'), 'forge', 'archive of the volume', 'archive of the volume'),
)
# (item name, folder, sub-folders that stay out of the item: {name: reason})
ISLE_FOLDERS = (
    ('isle-settings', '/etc/isle-mesh', {'apt': 'public packages; kept as a placed dataset'}),
    ('isle-state', '/var/lib/isle-mesh', {'artifacts': 'release files; they come from a release',
                                          'operations': 'operation journals; in or out is not decided'}),
)
UNITS = {'B': 1, 'kB': 10**3, 'MB': 10**6, 'GB': 10**9, 'TB': 10**12}


def _run(args):
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def docker_bytes(text):
    """'110.8MB' -> 110800000.  Docker prints decimal units; anything else is None (not measured)."""
    found = re.fullmatch(r'([0-9]+(?:\.[0-9]+)?)(B|kB|MB|GB|TB)', (text or '').strip())
    return int(float(found.group(1)) * UNITS[found.group(2)]) if found else None


def volumes(run=_run):
    """Return (reachable, items, not_covered, anonymous_count) from Docker's own listing."""
    listed = run(['docker', 'system', 'df', '-v', '--format', '{{json .Volumes}}'])
    if listed is None:
        return False, [], [], 0
    users = {}
    for line in (run(['docker', 'ps', '-a', '--no-trunc', '--format', '{{.Names}}\t{{.State}}\t{{.Mounts}}']) or '').splitlines():
        name, state, mounts = (line.split('\t') + ['', ''])[:3]
        for mount in filter(None, mounts.split(',')):
            users.setdefault(mount, []).append((name, state))
    items, not_covered, anonymous = [], [], 0
    for row in sorted(json.loads(listed) or [], key=lambda r: r.get('Name', '')):
        name = row.get('Name', '')
        if ANONYMOUS.match(name):
            anonymous += 1
            continue
        running = sorted(n for n, state in users.get(name, []) if state == 'running')
        size = docker_bytes(row.get('Size'))
        rule = next((r for r in VOLUME_RULES if r[0].search(name)), None)
        if rule is None:
            not_covered.append(dict(source=name, sizeBytes=size, reason='No rule says how this volume is taken.'))
            continue
        items.append(dict(item=name, kind=rule[1], source='docker volume ' + name, sizeBytes=size, inUseBy=running,
                          method=rule[2] if running else rule[3]))
    return True, items, not_covered, anonymous


def tree_bytes(path, skip=(), seen=None):
    """Return (bytes, entries that could not be read).  Links are never followed; a hard-linked file counts once."""
    total, unreadable = 0, 0
    seen = set() if seen is None else seen
    try:
        entries = list(os.scandir(path))
    except OSError:
        return 0, 1
    for entry in entries:
        if entry.name in skip:
            continue
        try:
            if entry.is_dir(follow_symlinks=False):
                size, missed = tree_bytes(entry.path, seen=seen)
                total, unreadable = total + size, unreadable + missed
                continue
            info = entry.stat(follow_symlinks=False)
            if info.st_nlink > 1:
                if (info.st_dev, info.st_ino) in seen:
                    continue
                seen.add((info.st_dev, info.st_ino))
            total += info.st_size
        except OSError:
            unreadable += 1
    return total, unreadable


def isle_state(folders=ISLE_FOLDERS):
    items, left_out = [], []
    for name, folder, skipped in folders:
        if not os.path.isdir(folder):
            continue
        size, missed = tree_bytes(folder, skip=tuple(skipped))
        items.append(dict(item=name, kind='isle-folder', source=folder, sizeBytes=size, unreadable=missed,
                          method='archive of the folder, read as root'))
        for sub, reason in sorted(skipped.items()):
            path = os.path.join(folder, sub)
            if os.path.isdir(path):
                size, missed = tree_bytes(path)
                left_out.append(dict(source=path, sizeBytes=size, unreadable=missed, reason=reason))
    return items, left_out


def target(path, needed, *, usage=shutil.disk_usage, device_of=lambda p: os.stat(p).st_dev):
    if not path:
        return dict(chosen=False, usable=False,
                    reason='No partition carries the role backup yet. Name one with --target <mount point>.')
    doc = dict(chosen=True, path=path, usable=False)
    if not os.path.isdir(path):
        return dict(doc, reason='The target is not a folder on this machine.')
    if device_of(path) == device_of('/'):
        return dict(doc, reason='The target is on the system filesystem. A backup goes to its own disk.')
    if not os.path.ismount(path):
        return dict(doc, reason='The target is not a mount point. Name the mount point of the backup partition.')
    free = usage(path).free
    doc.update(freeBytes=free, neededBytes=needed * 2)
    if free < needed * 2:
        return dict(doc, reason='The target has less free space than twice the device-backup.')
    return dict(doc, usable=True, reason=None)


def plan(target_path=None, *, run=_run, folders=ISLE_FOLDERS, device_file='/etc/isle-mesh/device-name', **target_kwargs):
    reachable, items, not_covered, anonymous = volumes(run)
    folder_items, left_out = isle_state(folders)
    items += folder_items
    try:
        with open(device_file, encoding='utf-8') as handle:
            device = handle.read().strip() or socket.gethostname()
    except OSError:
        device = socket.gethostname()
    measured = [i['sizeBytes'] for i in items]
    complete = reachable and None not in measured and not any(i.get('unreadable') for i in items)
    total = sum(size or 0 for size in measured)
    place = target(target_path, total, **target_kwargs)
    return dict(device=device, dockerReachable=reachable, items=items, notCovered=not_covered, leftOut=left_out,
                anonymousVolumes=anonymous, totalBytes=total, sizesComplete=complete, target=place,
                ready=bool(place['usable'] and complete and not not_covered))


def _size(value):
    if value is None:
        return 'not measured'
    for unit in ('B', 'kB', 'MB', 'GB', 'TB'):
        if value < 1000 or unit == 'TB':
            return ('%d %s' if unit == 'B' else '%.1f %s') % (value, unit)
        value /= 1000.0


def table(doc):
    lines = ['Device-backup plan for %s (nothing is copied by this verb)' % doc['device'], '']
    if not doc['dockerReachable']:
        lines += ['Docker did not answer: no volume is listed.', '']
    for item in doc['items']:
        note = ' (%d entries not readable without root)' % item['unreadable'] if item.get('unreadable') else ''
        lines.append('  %-34s %-14s %12s  %s%s' % (item['item'], item['kind'], _size(item['sizeBytes']), item['method'], note))
    for title, rows in (('Not covered', doc['notCovered']), ('Left out', doc['leftOut'])):
        if rows:
            lines += ['', title + ':'] + ['  %-49s %12s  %s' % (r['source'], _size(r['sizeBytes']), r['reason']) for r in rows]
    lines += ['', 'Total: %s%s' % (_size(doc['totalBytes']), '' if doc['sizesComplete'] else ' (incomplete)')]
    place = doc['target']
    lines.append('Target: %s' % ('%s, usable, %s free' % (place['path'], _size(place['freeBytes'])) if place['usable'] else place['reason']))
    return '\n'.join(lines)


def main(argv=None, *, out=print, **plan_kwargs):
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv and argv[0] in NOT_BUILT:
        out(json.dumps(dict(ok=False, operation='backup.' + argv[0],
                            error='pol backup %s is not built yet. Only pol backup plan exists.' % argv[0])))
        return 2
    parser = argparse.ArgumentParser(prog='pol backup', description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    listing = parser.add_subparsers(dest='command', required=True).add_parser('plan')
    listing.add_argument('--target')
    listing.add_argument('--table', action='store_true')
    args = parser.parse_args(argv)
    doc = plan(args.target, **plan_kwargs)
    if args.table:
        out(table(doc))
    else:
        out(json.dumps(dict(ok=True, evaluatedAt=datetime.now(timezone.utc).isoformat(), operation='backup.plan',
                            readOnly=True, result=doc)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
