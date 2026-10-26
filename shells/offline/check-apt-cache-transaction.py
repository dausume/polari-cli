#!/usr/bin/env python3
"""Exercise the installer's real apt cache layout and dpkg path, offline.

Installs one small dependency inside a disposable, network-disabled container.
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
source = Path(__file__).with_name('install-offline.sh').read_text()
# Use the actual configuration block so switching copy: back to file: makes
# this test fail, rather than accidentally testing an independent good setup.
setup = source[source.index('mkdir -p "$WORK/lists/partial"'):source.index('TARGETS=')]
script = '''set -euo pipefail
POOL=/medium
WORK=$(mktemp -d)
''' + setup + '''
export APT_CONFIG="$WORK/apt.conf"
apt-get "${APT_OPTS[@]}" update -qq
apt-get "${APT_OPTS[@]}" --download-only --no-remove install -y --no-install-recommends libinotifytools0
find "$WORK/archives" -maxdepth 1 -name 'libinotifytools0_*.deb' -print -quit | grep -q .
apt-get "${APT_OPTS[@]}" --no-download --no-remove install -y --no-install-recommends libinotifytools0
test "$(dpkg-query -W -f='${db:Status-Status}' libinotifytools0)" = installed
apt-get "${APT_OPTS[@]}" --no-download --no-remove install -y --no-install-recommends libinotifytools0
'''
subprocess.run([
    'docker', 'run', '--rm', '--pull', 'never', '--network', 'none',
    '--memory', '384m', '--cpus', '1',
    '--mount', f'type=bind,src={medium},dst=/medium,readonly',
    manifest['target'].replace('-', ':'), 'bash', '-c', script,
], check=True, timeout=180)
print('PASS: real local-cache apt install and repeat run, network disabled; host untouched')
