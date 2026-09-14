#!/usr/bin/env python3
"""
apps_usb.py — the USB app stick (his rulings 2026-09-13): Polari LOOKS for a prepared stick, the stick is the
ADVISED path for app installs, and a stick is ALWAYS the offline flavour (everything the apps need travels on it).
One stick serves three cases (his rulings, same day): apps only; ALL OF POLARI as an app alongside other apps
(the platform installer rides on the stick and installs first, only when the computer lacks it); and a BULK
install of many apps from one stick. Nothing is installed twice: dpkg skips present packages, pip skips present
libraries, and the index records which libraries are shared between the apps on the stick.

  apps_usb.py list                              mounted removable drives; the ones carrying polari-apps/index.json are app sticks
  apps_usb.py write <mountpoint> [--apps all|a,b|none] [--platform auto|yes|no] [--from <core url>]
                                 [--platform-from <url>] [--insecure]
                                                the platform installer (from the core, else the distribution point) + the chosen
                                                OFFLINE app debs + index.json + install-apps.sh
  apps_usb.py install [<mountpoint>] [--no-platform] [app ...]
                                                run the stick's installer (sudo), presence-checked, no internet
Non-destructive: writes files onto the drive's existing filesystem, never formats it.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import ssl
import urllib.error
import urllib.request

INSECURE = False   # --insecure / POLARI_INSECURE=1: accept a self-signed core (a home stack) — never the default
DISTRIBUTION_POINT = os.environ.get('POLARI_DISTRIBUTION_POINT', 'https://polari-systems.org')   # where the platform deb always is

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.join(HERE, 'install-apps.sh')
STICK_SCRIPTS = {'install-apps.sh': 'install-apps.sh', 'on-insert.sh': 'stick-on-insert.sh', 'wipe-stick.sh': 'stick-wipe.sh'}
AUTORUN = '#!/bin/bash\n# A Polari app stick: the desktop offers to run this when the stick is plugged in (ext4 sticks; FAT is mounted noexec).\nexec bash "$(dirname "$0")/polari-apps/on-insert.sh" "$@"\n'
HOST_CONFIG = os.path.expanduser('~/.config/polari/usb.json')   # {"on_insert": "ask|never", "after_install": "ask|wipe|keep"}
USER_UNIT = os.path.expanduser('~/.config/systemd/user/polari-app-stick.service')


def host_config():
    try:
        return json.load(open(HOST_CONFIG))
    except Exception:
        return {}


def write_stick_scripts(dest):
    """The stick is self-contained: installer, the on-insert prompt, the guarded wipe, and autorun.sh at the root."""
    for name, src in STICK_SCRIPTS.items():
        with open(os.path.join(HERE, src)) as f, open(os.path.join(dest, name), 'w') as out:
            out.write(f.read())
        os.chmod(os.path.join(dest, name), 0o755)
    root = os.path.dirname(dest)
    with open(os.path.join(root, 'autorun.sh'), 'w') as out:
        out.write(AUTORUN)
    os.chmod(os.path.join(root, 'autorun.sh'), 0o755)


def sticks():
    try:
        out = subprocess.run(['lsblk', '-J', '-o', 'NAME,SIZE,RM,MOUNTPOINT,LABEL,TRAN'], capture_output=True, text=True).stdout
        devices = json.loads(out or '{"blockdevices": []}')['blockdevices']
    except Exception:
        devices = []
    found = []
    for d in devices:
        for p in (d.get('children') or [d]):
            if (d.get('tran') == 'usb' or d.get('rm')) and p.get('mountpoint'):
                idx = os.path.join(p['mountpoint'], 'polari-apps', 'index.json')
                apps = 0; platform = False
                if os.path.isfile(idx):
                    try:
                        i = json.load(open(idx))
                        apps = len([a for a in i.get('apps', []) if 'file' in a]); platform = bool(i.get('installers'))
                    except Exception:
                        apps = 0
                found.append({'mount': p['mountpoint'], 'label': p.get('label') or '', 'size': p.get('size'), 'stick': os.path.isfile(idx),
                              'apps': apps, 'platform': platform})
    return found


def cmd_list():
    found = sticks()
    if not found:
        print('no mounted USB drive found (plug one in and mount it; then: pol apps usb write <mountpoint> --apps all)')
        return 0
    for s in found:
        if s['stick']:
            what = f"{s['apps']} app(s)" + (' + the platform' if s['platform'] else '')
            print(f"{s['mount']}  {s['label'] or '-'}  {s['size']}  POLARI APP STICK: {what} — the advised install path: pol apps usb install {s['mount']}")
        else:
            print(f"{s['mount']}  {s['label'] or '-'}  {s['size']}  plain drive (pol apps usb write {s['mount']} --apps all makes it an app stick)")
    return 0


def _ctx():
    return ssl._create_unverified_context() if INSECURE else None


def call(base, method, path, timeout=600):
    req = urllib.request.Request(base + path, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()
    except (urllib.error.URLError, OSError) as e:
        return 0, {}, str(e).encode()


def fetch_to(url, dest, timeout=3600):
    """Stream a download to a file (a platform deb can be large); returns (status, bytes, sha256). A file already
    on the stick under that name is kept and re-hashed, never downloaded twice (adding apps to a stick is cheap)."""
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        h = hashlib.sha256(open(dest, 'rb').read())
        return 200, os.path.getsize(dest), h.hexdigest()
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r, open(dest, 'wb') as f:
            h = hashlib.sha256(); n = 0
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk); h.update(chunk); n += len(chunk)
            return r.status, n, h.hexdigest()
    except urllib.error.HTTPError as e:
        return e.code, 0, ''
    except (urllib.error.URLError, OSError):
        return 0, 0, ''


def platform_installers(base):
    """The platform deb(s) a source offers: the JSON route when it has one, else the links on its /downloads page
    (the distribution point may run an older image without /api/downloads)."""
    code, _, body = call(base, 'GET', '/api/downloads')
    if code == 200:
        try:
            return [{'file': i['file'], 'url': i['url']} for i in json.loads(body).get('installers', [])]
        except Exception:
            pass
    code, _, body = call(base, 'GET', '/downloads?flavor=offline')
    if code != 200:
        return []
    seen = []
    for href in re.findall(r'href="([^"]*polari-complete[^"]*\.deb)"', body.decode('utf-8', 'replace')):
        f = href.rsplit('/', 1)[-1]
        if f not in [s['file'] for s in seen]:
            seen.append({'file': f, 'url': href})
    return seen


def deb_wheels(path):
    """The wheel files carried inside an offline app deb (dpkg-deb listing) — for the shared-library accounting."""
    try:
        out = subprocess.run(['dpkg-deb', '-c', path], capture_output=True, text=True).stdout
    except Exception:
        return []
    return sorted({line.rsplit('/', 1)[-1] for line in out.splitlines() if line.strip().endswith('.whl')})


def cmd_write(mount, apps_arg, base, platform, platform_from, on_insert='ask', after_install='ask'):
    if not os.path.isdir(mount):
        sys.exit(f'{mount} is not a mounted directory')
    dest = os.path.join(mount, 'polari-apps')
    os.makedirs(dest, exist_ok=True)
    index = {'schema': 'polari-app-stick/1', 'created': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'source': base, 'flavor': 'offline',
             'note': 'A Polari app stick: every app here is the OFFLINE flavour and carries what it needs; installs need no internet. '
                     'The platform (when present) installs first, then the apps — each only if this computer lacks it. '
                     'Plug it in and open the Isle App Store, or run install-apps.sh.', 'installers': [], 'apps': [], 'shared_wheels': {},
             'on_insert': on_insert, 'after_install': after_install}
    # 1. the platform as an app: from the core when it stages one, else from the distribution point
    if platform != 'no':
        found = platform_installers(base); origin = base
        if not found and platform_from:
            found = platform_installers(platform_from); origin = platform_from
        if not found and platform == 'yes':
            sys.exit(f'--platform yes: no platform installer at {base}' + (f' or {platform_from}' if platform_from else ''))
        for inst in found:
            url = inst['url'] if inst['url'].startswith('http') else origin + inst['url']
            path = os.path.join(dest, inst['file'])
            code, n, sha = fetch_to(url, path)
            if code != 200:
                print('  skip installer', inst['file'], ':', code); os.path.exists(path) and os.remove(path); continue
            index['installers'].append({'file': inst['file'], 'bytes': n, 'sha256': sha, 'from': origin})
            print('installer', inst['file'], n, 'bytes', 'from', origin)
        if not found:
            print('platform: none available — an apps-only stick (the platform must already be on the target)')
    # 2. the apps: OFFLINE flavour only, generated by the core on request
    wanted = []
    if apps_arg != 'none':
        code, _, body = call(base, 'GET', '/api/apps')
        if code != 200:
            sys.exit(f'{base}/api/apps answered {code} — is the core reachable?')
        cat = json.loads(body)
        wanted = [a['module'] for a in cat['apps']] if apps_arg == 'all' else [x.strip() for x in apps_arg.split(',') if x.strip()]
    wheels_by_app = {}
    for mod in wanted:
        code, _, body = call(base, 'POST', f'/api/apps/{mod}/request?flavor=offline')
        d = json.loads(body) if code else {'refusal': body.decode('utf-8', 'replace')}
        if code >= 400 or code == 0:
            print('  skip', mod, ':', d.get('refusal')); index['apps'].append({'module': mod, 'skipped': d.get('refusal')}); continue
        for _ in range(900):
            code, _, body = call(base, 'GET', f'/api/apps/{mod}/status?flavor=offline'); d = json.loads(body)
            if d.get('state') in ('ready', 'refused'):
                break
            time.sleep(2)
        if d.get('state') != 'ready':
            print('  skip', mod, ':', d.get('refusal')); index['apps'].append({'module': mod, 'skipped': d.get('refusal')}); continue
        path = os.path.join(dest, d['file'])
        code, n, sha = fetch_to(base + f'/api/apps/{mod}/download?flavor=offline', path)
        if code != 200:
            print('  skip', mod, ': download', code); continue
        ok = sha == d['sha256']
        wheels_by_app[mod] = deb_wheels(path)
        index['apps'].append({'module': mod, 'file': d['file'], 'bytes': n, 'sha256': sha, 'flavor': 'offline', 'verified': ok,
                              'carries': d['differences']['carries'], 'engines': d['differences'].get('engines', {}),
                              'wheels': wheels_by_app[mod], 'hardware': (d.get('hardware') or {}).get('notice', '')})
        print('  app', mod, d['file'], n, 'bytes', 'verified' if ok else 'SHA MISMATCH')
    # 3. the accounting: a library carried by several apps is on the stick several times but installed ONCE
    #    (pip --no-index skips what is present) — recorded so the store can say so
    owners = {}
    for mod, ws in wheels_by_app.items():
        for w in ws:
            owners.setdefault(w, []).append(mod)
    index['shared_wheels'] = {w: mods for w, mods in owners.items() if len(mods) > 1}
    json.dump(index, open(os.path.join(dest, 'index.json'), 'w'), indent=1)
    write_stick_scripts(dest)
    n = len([a for a in index['apps'] if 'file' in a])
    print(f"stick written: {dest} | {len(index['installers'])} platform installer(s), {n} app(s), "
          f"{len(index['shared_wheels'])} librar{'y' if len(index['shared_wheels']) == 1 else 'ies'} shared between apps (installed once) "
          f'— on insert: {on_insert}; after a confirmed install: {after_install} (index.json, install-apps.sh, on-insert.sh, wipe-stick.sh, autorun.sh)')
    try:
        fs = subprocess.run(['findmnt', '-no', 'FSTYPE', mount], capture_output=True, text=True).stdout.strip()
    except Exception:
        fs = ''
    if fs in ('vfat', 'exfat', 'ntfs'):
        print(f'note: this stick is {fs} — the desktop cannot run autorun.sh from it (mounted with showexec); the prompt comes from '
              'Polari\'s watcher on a computer that has Polari, or run polari-apps/on-insert.sh. For a self-prompting stick: pol apps usb prepare <device> --fs ext4')
    return 0


def find_stick(mount):
    if not mount:
        mount = next((s['mount'] for s in sticks() if s['stick']), '')
    if not mount or not os.path.isfile(os.path.join(mount, 'polari-apps', 'on-insert.sh')):
        sys.exit('no Polari app stick found (pol apps usb list)')
    return mount


def cmd_prompt(mount, args):
    """The stick's own prompt: Install / Not now / Wipe — then, after a CONFIRMED finished install, its after_install policy."""
    mount = find_stick(mount)
    return subprocess.call(['bash', os.path.join(mount, 'polari-apps', 'on-insert.sh')] + list(args))


def cmd_install(mount, args):
    """Install straight away (the prompt's Install answer): the platform if missing, then the apps, then --verify and
    the after-install policy (ask = a human is asked; scripted installs never wipe unless --after wipe)."""
    mount = find_stick(mount)
    apps = [a for a in args if not a.startswith('-')]
    if apps or '--no-platform' in args:
        return subprocess.call(['sudo', 'bash', os.path.join(mount, 'polari-apps', 'install-apps.sh')] + list(args))
    after = next((args[i + 1] for i, a in enumerate(args) if a == '--after' and i + 1 < len(args)), host_config().get('after_install', ''))
    return subprocess.call(['bash', os.path.join(mount, 'polari-apps', 'on-insert.sh'), '--answer', 'install'] + (['--after', after] if after else []))


def cmd_wipe(target, args):
    """Erase the stick (guarded: removable/USB only, never a system disk, named before it happens, --yes required).
    --polari-only removes just Polari's files."""
    if not target:
        target = find_stick('')
    return subprocess.call(['sudo', 'bash', os.path.join(HERE, 'stick-wipe.sh'), target] + list(args))


def cmd_prepare(device, args):
    """Make a blank stick: erase the device and put one filesystem on it (--fs ext4 = self-prompting, Linux only;
    --fs vfat = readable everywhere, Polari's watcher prompts), then mount it and say where to write."""
    if not device.startswith('/dev/'):
        sys.exit('usage: prepare /dev/sdX --fs ext4|vfat [--label NAME] --yes')
    rc = subprocess.call(['sudo', 'bash', os.path.join(HERE, 'stick-wipe.sh'), device, '--owner', f'{os.getuid()}:{os.getgid()}'] + list(args))
    if rc != 0:
        return rc
    out = subprocess.run(['udisksctl', 'mount', '-b', device], capture_output=True, text=True)
    print(out.stdout.strip() or out.stderr.strip())
    mp = subprocess.run(['findmnt', '-no', 'TARGET', device], capture_output=True, text=True).stdout.strip()
    if mp:
        print(f'now: pol apps usb write {mp} --apps all')
    return 0


def cmd_config(args):
    cfg = host_config()
    rest = list(args)
    while rest:
        if rest[0] == '--on-insert' and len(rest) > 1 and rest[1] in ('ask', 'never'): cfg['on_insert'] = rest[1]; rest = rest[2:]
        elif rest[0] == '--after-install' and len(rest) > 1 and rest[1] in ('ask', 'wipe', 'keep'): cfg['after_install'] = rest[1]; rest = rest[2:]
        else: sys.exit('config [--on-insert ask|never] [--after-install ask|wipe|keep]')
    os.makedirs(os.path.dirname(HOST_CONFIG), exist_ok=True)
    json.dump(cfg, open(HOST_CONFIG, 'w'), indent=1)
    after = cfg.get('after_install', "the stick's own policy")
    print(f"{HOST_CONFIG}: on insert = {cfg.get('on_insert', 'ask')}, after a confirmed install = {after}")
    return 0


def cmd_watch(args):
    """Polari looks for a stick: every few seconds, a NEWLY mounted app stick raises the prompt (its on_insert and
    the host config both say 'ask'). --enable installs this as a user service; --once checks a single time."""
    if '--enable' in args or '--disable' in args:
        if '--disable' in args:
            subprocess.call(['systemctl', '--user', 'disable', '--now', 'polari-app-stick.service'], stderr=subprocess.DEVNULL)
            print('watcher disabled'); return 0
        os.makedirs(os.path.dirname(USER_UNIT), exist_ok=True)
        with open(USER_UNIT, 'w') as f:
            f.write('[Unit]\nDescription=Polari looks for a plugged-in app stick and offers to install from it\nAfter=graphical-session.target\n\n'
                    f'[Service]\nExecStart=/usr/bin/python3 {os.path.abspath(__file__)} watch\nRestart=on-failure\n\n[Install]\nWantedBy=default.target\n')
        subprocess.call(['systemctl', '--user', 'daemon-reload'])
        rc = subprocess.call(['systemctl', '--user', 'enable', '--now', 'polari-app-stick.service'])
        print('watcher enabled (systemd --user polari-app-stick.service)' if rc == 0 else 'could not enable the user service'); return rc
    seen = set(s['mount'] for s in sticks()) if '--once' not in args else set()
    while True:
        for s in sticks():
            if s['stick'] and s['mount'] not in seen:
                seen.add(s['mount'])
                if host_config().get('on_insert', 'ask') == 'never':
                    print(f"app stick at {s['mount']} (prompt off: pol apps usb config --on-insert ask)"); continue
                try:
                    if json.load(open(os.path.join(s['mount'], 'polari-apps', 'index.json'))).get('on_insert', 'ask') == 'none':
                        print(f"app stick at {s['mount']} (it asks not to prompt; pol apps usb install {s['mount']})"); continue
                except Exception:
                    pass
                cmd_prompt(s['mount'], [])
        seen &= set(s['mount'] for s in sticks())
        if '--once' in args:
            return 0
        time.sleep(3)


def main(argv):
    sub = argv[0] if argv else 'list'
    global INSECURE
    INSECURE = os.environ.get('POLARI_INSECURE') == '1'
    if sub == 'list':
        return cmd_list()
    if sub == 'write':
        mount = argv[1] if len(argv) > 1 else sys.exit('usage: write <mountpoint> [--apps all|a,b|none] [--platform auto|yes|no] [--from <core>]')
        apps = 'all'; base = os.environ.get('POLARI_API', 'http://127.0.0.1:3300'); platform = 'auto'; platform_from = DISTRIBUTION_POINT
        on_insert = 'ask'; after_install = 'ask'
        rest = argv[2:]
        while rest:
            if rest[0] == '--on-insert' and len(rest) > 1: on_insert = rest[1]; rest = rest[2:]; continue
            if rest[0] == '--after-install' and len(rest) > 1: after_install = rest[1]; rest = rest[2:]; continue
            if rest[0] == '--apps' and len(rest) > 1: apps = rest[1]; rest = rest[2:]
            elif rest[0] in ('--from', '--api') and len(rest) > 1: base = rest[1]; rest = rest[2:]
            elif rest[0] == '--platform' and len(rest) > 1: platform = rest[1]; rest = rest[2:]
            elif rest[0] == '--platform-from' and len(rest) > 1: platform_from = rest[1]; rest = rest[2:]
            elif rest[0] == '--insecure': INSECURE = True; rest = rest[1:]
            else: rest = rest[1:]
        if platform not in ('auto', 'yes', 'no'):
            sys.exit('--platform takes auto | yes | no')
        if on_insert not in ('ask', 'none') or after_install not in ('ask', 'wipe', 'keep'):
            sys.exit('--on-insert takes ask | none; --after-install takes ask | wipe | keep')
        return cmd_write(mount, apps, base.rstrip('/'), platform, platform_from.rstrip('/') if platform_from else '', on_insert, after_install)
    first = argv[1] if len(argv) > 1 and not argv[1].startswith('-') else ''
    rest = argv[2:] if first else argv[1:]
    if sub == 'install':
        return cmd_install(first, rest)
    if sub == 'prompt':
        return cmd_prompt(first, rest)
    if sub == 'wipe':
        return cmd_wipe(first, rest)
    if sub == 'prepare':
        return cmd_prepare(first, rest)
    if sub == 'watch':
        return cmd_watch(argv[1:])
    if sub == 'config':
        return cmd_config(argv[1:])
    print('pol apps usb list | prepare /dev/sdX --fs ext4|vfat --yes | write <mountpoint> [--apps all|a,b|none] [--platform auto|yes|no] '
          '[--from <core>] [--on-insert ask|none] [--after-install ask|wipe|keep] | prompt [<mountpoint>] | install [<mountpoint>] '
          '[--after ask|wipe|keep] [--no-platform] [app ...] | wipe [<mountpoint>|/dev/sdX] [--polari-only] --yes | watch [--enable|--disable|--once] '
          '| config [--on-insert ask|never] [--after-install ask|wipe|keep]   (a stick is always the OFFLINE flavour)')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
