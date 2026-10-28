#!/usr/bin/env python3
"""Prove the bundled apt closure in pristine Ubuntu with networking disabled.

Does not install packages, bind the Docker socket, or touch host configuration.
The target base image must already exist locally (--pull never).
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('medium', type=Path)
args = parser.parse_args()
medium = args.medium.resolve()
manifest = json.loads((medium / 'manifest.json').read_text())
if manifest['target'] not in ('ubuntu-22.04', 'ubuntu-24.04'):
    parser.error('unsupported target')
packages = set()
for stanza in (medium / 'apt/Packages').read_text().split('\n\n'):
    match = re.search(r'^Package: (.+)$', stanza, re.MULTILINE)
    if match:
        packages.add(match[1])
roots = []
for dependency in manifest['requiredPackages']+manifest.get('cachedPackages',[]):
    for alternative in dependency.split('|'):
        name = alternative.strip().split()[0].split(':')[0]
        if name in packages:
            roots.append(name)
            break
    else:
        parser.error('no bundled candidate for ' + dependency)
deb = manifest['debs']['polari-complete-offline']
if Path(deb).name != deb:
    parser.error('invalid platform filename')
script = r'''
set -eu
mkdir -p /work/lists/partial /work/cache/partial /work/sourceparts
printf 'deb [trusted=yes] file:/medium/apt ./\n' > /work/sources.list
apt-get -o Dir::Etc::SourceList=/work/sources.list -o Dir::Etc::SourceParts=/work/sourceparts -o Dir::State::lists=/work/lists update -qq
apt-get -o Dir::Etc::SourceList=/work/sources.list -o Dir::Etc::SourceParts=/work/sourceparts -o Dir::State::lists=/work/lists --simulate --no-download --no-remove install --no-install-recommends "$@"
'''
subprocess.run([
    'docker', 'run', '--rm', '--pull', 'never', '--network', 'none',
    '--memory', '384m', '--cpus', '1',
    '--mount', f'type=bind,src={medium},dst=/medium,readonly',
    manifest['target'].replace('-', ':'), 'bash', '-c', script, 'closure',
    *sorted(set(roots)), '/medium/debs/' + deb,
], check=True, timeout=180)
print('PASS: pristine Ubuntu resolves the complete offline core using only bundled apt files, network disabled')
