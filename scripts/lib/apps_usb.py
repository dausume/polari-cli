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


def cmd_write(mount, apps_arg, base, platform, platform_from):
    if not os.path.isdir(mount):
        sys.exit(f'{mount} is not a mounted directory')
    dest = os.path.join(mount, 'polari-apps')
    os.makedirs(dest, exist_ok=True)
    index = {'schema': 'polari-app-stick/1', 'created': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'source': base, 'flavor': 'offline',
             'note': 'A Polari app stick: every app here is the OFFLINE flavour and carries what it needs; installs need no internet. '
                     'The platform (when present) installs first, then the apps — each only if this computer lacks it. '
                     'Plug it in and open the Isle App Store, or run install-apps.sh.', 'installers': [], 'apps': [], 'shared_wheels': {}}
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
    with open(INSTALLER) as src, open(os.path.join(dest, 'install-apps.sh'), 'w') as dst:
        dst.write(src.read())
    os.chmod(os.path.join(dest, 'install-apps.sh'), 0o755)
    n = len([a for a in index['apps'] if 'file' in a])
    print(f"stick written: {dest} | {len(index['installers'])} platform installer(s), {n} app(s), "
          f"{len(index['shared_wheels'])} librar{'y' if len(index['shared_wheels']) == 1 else 'ies'} shared between apps (installed once) "
          '— index.json + install-apps.sh (offline flavour)')
    return 0


def cmd_install(mount, args):
    if not mount:
        mount = next((s['mount'] for s in sticks() if s['stick']), '')
    script = os.path.join(mount or '', 'polari-apps', 'install-apps.sh')
    if not mount or not os.path.isfile(script):
        sys.exit('no Polari app stick found (pol apps usb list)')
    return subprocess.call(['sudo', 'bash', script] + list(args))


def main(argv):
    sub = argv[0] if argv else 'list'
    global INSECURE
    INSECURE = os.environ.get('POLARI_INSECURE') == '1'
    if sub == 'list':
        return cmd_list()
    if sub == 'write':
        mount = argv[1] if len(argv) > 1 else sys.exit('usage: write <mountpoint> [--apps all|a,b|none] [--platform auto|yes|no] [--from <core>]')
        apps = 'all'; base = os.environ.get('POLARI_API', 'http://127.0.0.1:3300'); platform = 'auto'; platform_from = DISTRIBUTION_POINT
        rest = argv[2:]
        while rest:
            if rest[0] == '--apps' and len(rest) > 1: apps = rest[1]; rest = rest[2:]
            elif rest[0] in ('--from', '--api') and len(rest) > 1: base = rest[1]; rest = rest[2:]
            elif rest[0] == '--platform' and len(rest) > 1: platform = rest[1]; rest = rest[2:]
            elif rest[0] == '--platform-from' and len(rest) > 1: platform_from = rest[1]; rest = rest[2:]
            elif rest[0] == '--insecure': INSECURE = True; rest = rest[1:]
            else: rest = rest[1:]
        if platform not in ('auto', 'yes', 'no'):
            sys.exit('--platform takes auto | yes | no')
        return cmd_write(mount, apps, base.rstrip('/'), platform, platform_from.rstrip('/') if platform_from else '')
    if sub == 'install':
        mount = argv[1] if len(argv) > 1 and not argv[1].startswith('-') else ''
        return cmd_install(mount, argv[2:] if mount else argv[1:])
    print('pol apps usb list | write <mountpoint> [--apps all|a,b|none] [--platform auto|yes|no] [--from <core>] '
          '| install [<mountpoint>] [--no-platform] [app ...]   (always the OFFLINE flavour)')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
