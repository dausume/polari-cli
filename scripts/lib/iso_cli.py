#!/usr/bin/env python3
"""iso_cli.py — the `pol iso` verbs against a core's /api/iso (see iso.sh for the surface). Streams the image to a
file with its sha256 checked; the Ventoy verb makes a stick bootable once (D-P1) — erases the stick, needs sudo."""
import hashlib
import io
import json
import os
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

B = os.environ.get('POLARI_ISO_FROM', 'http://127.0.0.1:3300').rstrip('/')
CTX = ssl._create_unverified_context() if os.environ.get('POLARI_INSECURE') == '1' else None


def call(method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(B + path, data=data, method=method, headers={'Content-Type': 'application/json'} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            raw = r.read(); return r.status, dict(r.headers), raw
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def j(raw):
    try:
        return json.loads(raw or b'{}')
    except ValueError:
        return {'raw': raw[:200].decode('utf-8', 'replace')}


def opts(argv):
    out = {'_': []}; i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith('--'):
            k = a[2:].replace('-', '_')
            if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
                out[k] = argv[i + 1]; i += 2
            else:
                out[k] = True; i += 1
        else:
            out['_'].append(a); i += 1
    return out


def cmd_kit(o):
    dest = o['_'][0] if o['_'] else '.'
    code, _, raw = call('GET', '/api/iso/probe-kit')
    if code != 200:
        sys.exit(f'probe kit: {code} {j(raw).get("refusal", "")}')
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        z.extractall(dest)
        for info in z.infolist():
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                try:
                    os.chmod(os.path.join(dest, info.filename), mode)
                except OSError:
                    pass
    print(f'probe kit unpacked into {dest}: open README.html on the computer to probe (Windows / Mac / Linux buttons)')


def cmd_probe(o):
    path = o['_'][0] if o['_'] else sys.exit('probe <report.json | a probe/cache dir | a stick mountpoint>')
    if os.path.isdir(path):   # a stick (its probe/cache) or the cache dir itself: post every report
        d = os.path.join(path, 'probe', 'cache') if os.path.isdir(os.path.join(path, 'probe', 'cache')) else path
        files = sorted(f for f in os.listdir(d) if f.endswith('.json'))
        if not files:
            sys.exit(f'no probe reports under {d}')
        for f in files:
            cmd_probe({'_': [os.path.join(d, f)]})
        return
    report = json.load(open(path))
    code, _, raw = call('POST', '/api/iso/probe', report)
    d = j(raw)
    if code >= 400:
        sys.exit(f'refused: {d.get("refusal")}')
    v = d['verdict']
    print(f"{report.get('hostname') or report.get('model') or d['hw_hash']} ({d['hw_hash']}): {v['verdict'].upper()}")
    print('  ' + v['text'])
    for t in v.get('traps', []):
        print('  before installing: ' + t['text'])
    if d.get('suggested_role'):
        print(f"  suggested role: {d['suggested_role']} — {d['suggested_reason']}")
    if d.get('next'):
        print('  next: ' + d['next'])


def cmd_probes(o):
    d = j(call('GET', '/api/iso/probes')[2])
    for p in d.get('probes', []):
        print(f"{p['hw_hash']}  {p['label'] or '-':<24} {p['os_name']} {p['os_version']:<12} {p['memory_gb']:g} GB  {p['verdict']:<22} role {p['suggested_role'] or '-'}")
    print(f"{d.get('count', 0)} probed computer(s)")


def cmd_bases(o):
    d = j(call('GET', '/api/iso/bases')[2])
    for b in d.get('bases', []):
        st = f"cached {b['bytes'] >> 20} MB" if b.get('cached') else 'not cached'
        kt = 'kernel table ready' if b.get('kernel_table') else 'kernel table not fetched'
        job = b.get('job'); jt = f" — {job['step']} {job.get('progress', 0)}%" if job and job['state'] == 'running' else ''
        print(f"{b['name']:<22} Ubuntu {b['release']} {b['arch']}  {st}, {kt}{jt}{'  (default)' if b.get('default') else ''}")


def cmd_fetch_base(o):
    name = o['_'][0] if o['_'] else sys.exit('fetch-base <name>')
    code, _, raw = call('POST', f'/api/iso/bases/{name}/fetch'); d = j(raw)
    if code >= 400:
        sys.exit(f'refused: {d.get("refusal")}')
    print(f"{name}: {d['state']} — {d['step']} (a 2–3 GB download; 'pol iso bases' shows progress)")
    if o.get('wait'):
        while True:
            time.sleep(10); b = next((x for x in j(call('GET', '/api/iso/bases')[2]).get('bases', []) if x['name'] == name), {})
            job = b.get('job')
            if not job or job['state'] != 'running':
                print(f"{name}: {'cached' if b.get('cached') else 'not cached'}; {'kernel table ready' if b.get('kernel_table') else 'no kernel table'}"); break
            print(f"  {job['step']} {job.get('progress', 0)}%")


def choices(o):
    b = {'role': o.get('role'), 'shape': o.get('shape'), 'base': o.get('base'), 'posture': o.get('posture'), 'look': o.get('look'), 'hostname': o.get('hostname'),
         'target_hash': o.get('target'), 'join_core': o.get('join_core'), 'join_fingerprint': o.get('fingerprint'), 'ssh_keys': o.get('ssh_key'), 'apps': o.get('apps'),
         'encryption': bool(o.get('encryption')), 'secure_boot': o.get('secure_boot') or 'on'}
    return {k: v for k, v in b.items() if v not in (None, False, '')} | {'encryption': bool(o.get('encryption'))}


def cmd_preview(o):
    q = '&'.join(f'{k}={urllib.request.quote(str(v))}' for k, v in choices(o).items())
    code, _, raw = call('GET', '/api/iso/autoinstall/preview?' + q); d = j(raw)
    if not d.get('ok'):
        sys.exit(f"refused: {d.get('refusal')}")
    for w in d.get('warnings', []):
        print('warning: ' + w)
    print(json.dumps(d['autoinstall'], indent=1))


def cmd_build(o):
    code, _, raw = call('POST', '/api/iso/build', choices(o)); d = j(raw)
    if code >= 400:
        sys.exit(f"refused: {d.get('refusal')}")
    for w in d.get('warnings', []):
        print('warning: ' + w)
    print(f"build {d['build']}: {d['state']} — {d['step']}   (pol iso status {d['build']})")
    if o.get('wait'):
        while True:
            time.sleep(10); s = j(call('GET', f"/api/iso/builds/{d['build']}/status")[2])
            if s.get('state') in ('ready', 'refused'):
                print(f"{d['build']}: {s['state']} {s.get('refusal', '') or s.get('file', '')} {s.get('bytes', '')}"); break
            print(f"  {s.get('step')}")


def cmd_status(o):
    bid = o['_'][0] if o['_'] else sys.exit('status <build id>')
    d = j(call('GET', f'/api/iso/builds/{bid}/status')[2])
    if not d.get('ok'):
        sys.exit(f"refused: {d.get('refusal')}")
    print(f"{bid}: {d['state']} {d.get('step', '')} {d.get('refusal', '')}")
    print(f"  {d['role']} · {d['shape']} · {d['base']} · posture {d['posture']} · encryption {'on' if d['encryption'] else 'off'} · Secure Boot {d['secure_boot']}")
    if d.get('file'):
        h = d.get('hold', {}); print(f"  {d['file']} {int(d['bytes']) >> 20} MB sha256 {d['sha256'][:16]}… held {h.get('hold_remaining_seconds', 0) // 60} more min")
    if d.get('warnings'):
        print('  ' + d['warnings'])


def cmd_fetch(o):
    bid = o['_'][0] if o['_'] else sys.exit('fetch <build id> -o file.iso')
    out = o.get('o') or o.get('output') or f'{bid}.iso'
    for _ in range(720):
        s = j(call('GET', f'/api/iso/builds/{bid}/status')[2])
        if s.get('state') in ('ready', 'refused'):
            break
        print(f"  {s.get('step')}"); time.sleep(10)
    if s.get('state') != 'ready':
        sys.exit(f"not ready: {s.get('state')} {s.get('refusal', '')}")
    req = urllib.request.Request(B + f'/api/iso/builds/{bid}/download')
    with urllib.request.urlopen(req, timeout=3600, context=CTX) as r, open(out, 'wb') as fh:
        want = r.headers.get('X-Polari-Sha256', ''); h = hashlib.sha256(); n = 0
        while True:
            chunk = r.read(1 << 22)
            if not chunk:
                break
            fh.write(chunk); h.update(chunk); n += len(chunk)
    ok = (not want) or h.hexdigest() == want
    print(f"saved {out} ({n >> 20} MB) sha256 {'verified' if ok else 'MISMATCH'}")
    sys.exit(0 if ok else 1)


def cmd_ventoy(o):
    """Make the stick a Ventoy stick (his decision D-P1): the release tarball from Ventoy's GitHub releases
    (GPL-3.0), Ventoy2Disk.sh -i on the device — erases it. Pin: POLARI_VENTOY_VERSION (else the latest release)."""
    dev = o['_'][0] if o['_'] else sys.exit('ventoy /dev/sdX')
    if not dev.startswith('/dev/'):
        sys.exit('ventoy needs the whole device, e.g. /dev/sdb')
    ver = os.environ.get('POLARI_VENTOY_VERSION', '')
    api = 'https://api.github.com/repos/ventoy/Ventoy/releases/' + (f'tags/v{ver}' if ver else 'latest')
    with urllib.request.urlopen(urllib.request.Request(api, headers={'User-Agent': 'polari'}), timeout=60) as r:
        rel = json.load(r)
    asset = next((a for a in rel.get('assets', []) if a['name'].endswith('linux.tar.gz')), None)
    if not asset:
        sys.exit('no linux tarball in the Ventoy release')
    tmp = tempfile.mkdtemp(prefix='ventoy-'); tgz = os.path.join(tmp, asset['name'])
    print(f"downloading {asset['name']} ({asset['size'] >> 20} MB) from Ventoy's releases (GPL-3.0)…")
    with urllib.request.urlopen(asset['browser_download_url'], timeout=600) as r, open(tgz, 'wb') as fh:
        shutil.copyfileobj(r, fh)
    with tarfile.open(tgz) as t:
        t.extractall(tmp)
    vdir = next((os.path.join(tmp, d) for d in os.listdir(tmp) if d.startswith('ventoy-')), None)
    if not vdir:
        sys.exit('unexpected tarball layout')
    print(f'THIS ERASES {dev}. Ventoy2Disk.sh asks for confirmation; the data partition (exFAT) is where the probe kit, the cache and the ISOs go.')
    rc = subprocess.call(['sudo', 'bash', os.path.join(vdir, 'Ventoy2Disk.sh'), '-i', '-g', dev])
    if rc == 0:
        print(f'{dev} is a Ventoy stick. Next: mount its data partition and run: pol iso kit <mountpoint>   (then copy ISOs onto it as plain files)')
    sys.exit(rc)


def main(argv):
    if not argv:
        sys.exit('verb required')
    verb, o = argv[0], opts(argv[1:])
    fn = {'kit': cmd_kit, 'probe': cmd_probe, 'probes': cmd_probes, 'bases': cmd_bases, 'fetch-base': cmd_fetch_base, 'preview': cmd_preview, 'build': cmd_build, 'status': cmd_status, 'fetch': cmd_fetch, 'ventoy': cmd_ventoy}.get(verb)
    if fn is None:
        sys.exit(f'unknown verb {verb}')
    fn(o)


if __name__ == '__main__':
    main(sys.argv[1:])
