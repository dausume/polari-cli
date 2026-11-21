#!/usr/bin/env python3
"""The checks of a medium take the target's image from the record of supported operating systems.

Nothing here starts a container or reads the installed isle CLI: the checks run in a copy of the forest's shape made
of fixtures, with a `docker` that only writes down how it was called.
"""
import json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE))
import supported_target as st

READER = '''import json
from pathlib import Path
def load():
    systems = json.loads((Path(__file__).parent / 'record.json').read_text())
    if not systems: raise ValueError('The record of supported operating systems cannot be read: fixture')
    return systems
'''
RECORD = [{'id': 'ubuntu-24.04', 'baseImage': 'ubuntu:24.04'}, {'id': 'pebble-7', 'baseImage': 'registry.example/pebble:seven'}]
DOCKER = '#!/bin/sh\nprintf \'%s\\n\' "$@" > "$CALLED"\n'


class Fixture(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.scripts = self.root / 'forest/Isle-Mesh/isle-cli/scripts'; self.scripts.mkdir(parents=True)
        (self.scripts / 'supported_os.py').write_text(READER)
        (self.scripts / 'record.json').write_text(json.dumps(RECORD))
        self.checks = self.root / 'forest/polari-cli/shells/offline'; self.checks.mkdir(parents=True)
        for name in ('supported_target.py', 'check-apt-closure.py', 'check-apt-cache-transaction.py', 'offline-apt.sh'):
            shutil.copy(SOURCE / name, self.checks / name)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        (self.bin / 'docker').write_text(DOCKER); (self.bin / 'docker').chmod(0o755)
        self.called = self.root / 'called'
        self.medium = self.root / 'medium'; (self.medium / 'apt').mkdir(parents=True)
        (self.medium / 'apt/Packages').write_text('Package: tool\nVersion: 2\n\n')

    def manifest(self, target):
        (self.medium / 'manifest.json').write_text(json.dumps({'target': target, 'requiredPackages': ['absent | tool (>= 1)'],
                                                                'debs': {'polari-complete-offline': 'platform.deb'}}))

    def check(self, name, target):
        self.manifest(target)
        if self.called.exists(): self.called.unlink()
        env = dict(os.environ, PATH='%s:%s' % (self.bin, os.environ['PATH']), CALLED=str(self.called))
        done = subprocess.run([sys.executable, str(self.checks / name), str(self.medium)], capture_output=True, text=True, env=env)
        return done, self.called.read_text().splitlines() if self.called.exists() else None


class TheImage(Fixture):
    def test_the_image_is_the_one_the_record_gives_the_target(self):
        places = (self.scripts,)
        self.assertEqual(st.base_image('pebble-7', places), 'registry.example/pebble:seven')
        self.assertEqual(st.base_image('ubuntu-24.04', places), 'ubuntu:24.04')

    def test_a_target_the_record_does_not_have_is_refused_with_the_ones_it_has(self):
        for target in ('ubuntu-22.04', 'pebble:seven', '', None, ['pebble-7']):
            with self.assertRaises(ValueError) as caught: st.base_image(target, (self.scripts,))
            self.assertIn('is not in the record of supported operating systems (ubuntu-24.04, pebble-7).', str(caught.exception))

    def test_the_first_place_that_has_a_reader_is_the_one_read(self):
        other = self.root / 'installed'; other.mkdir()
        (other / 'supported_os.py').write_text(READER)
        (other / 'record.json').write_text(json.dumps([{'id': 'pebble-7', 'baseImage': 'other:image'}]))
        self.assertEqual(st.base_image('pebble-7', (self.root / 'absent', other, self.scripts)), 'other:image')
        self.assertEqual(st.base_image('pebble-7', (self.scripts, other)), 'registry.example/pebble:seven')

    def test_no_reader_and_an_unreadable_record_are_said_in_plain_words(self):
        with self.assertRaises(ValueError) as caught: st.base_image('pebble-7', (self.root / 'absent',))
        self.assertIn('was not found (looked for supported_os.py in: %s).' % (self.root / 'absent'), str(caught.exception))
        (self.scripts / 'record.json').write_text('[]')
        with self.assertRaises(ValueError) as caught: st.base_image('pebble-7', (self.scripts,))
        self.assertIn('cannot be read', str(caught.exception))

    def test_the_places_are_this_forest_first_and_then_the_installed_isle_cli(self):
        self.assertEqual(st.PLACES, (SOURCE.parents[2] / 'Isle-Mesh/isle-cli/scripts', Path('/usr/share/isle-mesh/isle-cli/scripts')))


class TheChecks(Fixture):
    def test_each_check_starts_the_container_of_the_record_s_image(self):
        for name in ('check-apt-closure.py', 'check-apt-cache-transaction.py'):
            done, argv = self.check(name, 'pebble-7')
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(argv[:6], ['run', '--rm', '--pull', 'never', '--network', 'none'])
            self.assertEqual(argv[argv.index('bash') - 1], 'registry.example/pebble:seven')
            self.assertNotIn('pebble:7', argv)

    def test_the_closure_check_passes_the_bundled_candidate_and_the_platform_package(self):
        done, argv = self.check('check-apt-closure.py', 'ubuntu-24.04')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(argv[-3:], ['closure', 'tool', '/medium/debs/platform.deb'])
        self.assertEqual(argv[argv.index('bash') - 1], 'ubuntu:24.04')

    def test_a_target_the_record_does_not_have_starts_no_container(self):
        for name in ('check-apt-closure.py', 'check-apt-cache-transaction.py'):
            for target in ('ubuntu-22.04', 'pebble:seven'):
                done, argv = self.check(name, target)
                self.assertEqual((done.returncode, argv, done.stdout), (2, None, ''))
                self.assertIn('is not in the record of supported operating systems (ubuntu-24.04, pebble-7).', done.stderr)
                self.assertNotIn('Traceback', done.stderr)

    def test_an_unreadable_record_starts_no_container(self):
        (self.scripts / 'record.json').write_text('[]')
        for name in ('check-apt-closure.py', 'check-apt-cache-transaction.py'):
            done, argv = self.check(name, 'pebble-7')
            self.assertEqual((done.returncode, argv), (2, None))
            self.assertIn('cannot be read', done.stderr); self.assertNotIn('Traceback', done.stderr)


if __name__ == '__main__':
    unittest.main()
