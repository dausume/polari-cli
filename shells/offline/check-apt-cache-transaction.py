#!/usr/bin/env python3
"""Exercise the installer's real apt cache layout and dpkg path, offline.

Installs one small dependency and a direct-path local DEB inside a disposable, network-disabled container.
Unlike the fixture tests and closure simulation, this reaches real dpkg.
"""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('medium', type=Path)
args = parser.parse_args()
medium = args.medium.resolve()
manifest = json.loads((medium / 'manifest.json').read_text())
if manifest['target'] not in ('ubuntu-22.04', 'ubuntu-24.04'):
    parser.error('unsupported target')
helper = Path(__file__).with_name('offline-apt.sh').resolve()
script = r'''set -euo pipefail
POOL=/medium
WORK=$(mktemp -d)
source /test/offline-apt.sh
mkdir -p /tmp/cache-fixture/DEBIAN
printf 'Package: polari-cache-fixture\nVersion: 1\nArchitecture: all\nMaintainer: Test <test@localhost>\nDescription: offline transaction fixture\n' > /tmp/cache-fixture/DEBIAN/control
dpkg-deb --build /tmp/cache-fixture /tmp/polari-cache-fixture_1_all.deb
TARGETS=(libinotifytools0 /tmp/polari-cache-fixture_1_all.deb)
offline_apt_prepare
find "$WORK/archives" -maxdepth 1 -name 'libinotifytools0_*.deb' -print -quit | grep -q .
offline_apt_install
test "$(dpkg-query -W -f='${db:Status-Status}' libinotifytools0)" = installed
offline_apt_prepare
offline_apt_install
test "$(dpkg-query -W -f='${db:Status-Status}' polari-cache-fixture)" = installed
'''
subprocess.run([
    'docker', 'run', '--rm', '--pull', 'never', '--network', 'none',
    '--memory', '384m', '--cpus', '1',
    '--mount', f'type=bind,src={medium},dst=/medium,readonly',
    '--mount', f'type=bind,src={helper},dst=/test/offline-apt.sh,readonly',
    manifest['target'].replace('-', ':'), 'bash', '-c', script,
], check=True, timeout=180)
print('PASS: real local-cache apt install and repeat run, network disabled; host untouched')
