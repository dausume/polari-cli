"""pol backup plan: a recorded docker, temp folders and an injected disk; nothing real is read except through the dispatch test."""
from collections import namedtuple
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
import backup_plan as bp

ENTRY = Path(__file__).resolve().parents[1] / 'index.js'
ANON = 'a' * 64
VOLUMES = [dict(Name='stack_prf-mariadb-data', Size='110.8MB'), dict(Name='stack_backend-data', Size='161.9MB'),
           dict(Name='old_backend-data', Size='9.6MB'), dict(Name='stack_file-store-data', Size='51.45kB'),
           dict(Name='forge_forge-data', Size='0B'), dict(Name='erp_odoo-db-data', Size='1.2GB'),
           dict(Name='erp_odoo-filestore', Size='3MB'), dict(Name='someone_else', Size='5MB'), dict(Name=ANON, Size='1MB')]
PS = '\n'.join(['backend.1\trunning\t/host/ca.crt,stack_backend-data', 'backend.0\texited\tstack_backend-data',
                'db.1\trunning\tstack_prf-mariadb-data', 'old\texited\told_backend-data', 'pg\trunning\terp_odoo-db-data',
                'proxy\trunning\t'])
Usage = namedtuple('Usage', 'total used free')


def docker(volumes=VOLUMES, ps=PS, calls=None):
    def run(args):
        if calls is not None:
            calls.append(args)
        return json.dumps(volumes) if args[1] == 'system' else ps
    return run


class Sizes(unittest.TestCase):
    def test_docker_sizes(self):
        self.assertEqual([bp.docker_bytes(t) for t in ('0B', '51.45kB', '110.8MB', '1.2GB', '2TB')],
                         [0, 51450, 110800000, 1200000000, 2 * 10**12])
        self.assertEqual([bp.docker_bytes(t) for t in ('', None, 'N/A', '12', '5MiB', '-1MB')], [None] * 6)


class Volumes(unittest.TestCase):
    def setUp(self):
        self.reachable, self.items, self.not_covered, self.anonymous = bp.volumes(docker())
        self.by_name = {i['item']: i for i in self.items}

    def test_kinds(self):
        self.assertEqual({n: i['kind'] for n, i in self.by_name.items()}, {
            'stack_prf-mariadb-data': 'mariadb', 'stack_backend-data': 'instance-data', 'old_backend-data': 'instance-data',
            'stack_file-store-data': 'file-store', 'forge_forge-data': 'forge', 'erp_odoo-db-data': 'odoo-database',
            'erp_odoo-filestore': 'odoo-files'})

    def test_method_follows_whether_a_running_container_uses_it(self):
        self.assertEqual(self.by_name['stack_backend-data']['method'], 'write gate up, copy, gate down')
        self.assertEqual(self.by_name['stack_backend-data']['inUseBy'], ['backend.1'])
        self.assertEqual((self.by_name['old_backend-data']['method'], self.by_name['old_backend-data']['inUseBy']),
                         ('plain copy of the volume', []))
        self.assertEqual(self.by_name['stack_prf-mariadb-data']['method'], 'dump inside one transaction')
        self.assertEqual(self.by_name['erp_odoo-db-data']['method'], 'pol odoo backup')

    def test_unknown_volume_is_reported_not_dropped(self):
        self.assertEqual([(r['source'], r['sizeBytes']) for r in self.not_covered], [('someone_else', 5000000)])
        self.assertEqual(self.anonymous, 1)
        self.assertNotIn(ANON, self.by_name)

    def test_docker_silent(self):
        self.assertEqual(bp.volumes(lambda args: None), (False, [], [], 0))

    def test_only_reads(self):
        calls = []
        bp.volumes(docker(calls=calls))
        self.assertEqual([c[:3] for c in calls], [['docker', 'system', 'df'], ['docker', 'ps', '-a']])


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path, size in (('etc/ca/key', 100), ('etc/apt/pool/big', 5000), ('etc/device-name', 4), ('var/storage/b.json', 30),
                           ('var/artifacts/x/blob', 7000), ('var/operations/j', 900)):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_bytes(b'x' * size)
        os.symlink('/etc', self.root / 'etc' / 'ca' / 'link-out')
        self.folders = (('isle-settings', str(self.root / 'etc'), {'apt': 'packages'}),
                        ('isle-state', str(self.root / 'var'), {'artifacts': 'releases', 'operations': 'journals'}),
                        ('absent', str(self.root / 'nowhere'), {}))

    def mounted(self, answer=True):
        real = os.path.ismount
        os.path.ismount = lambda p: answer
        self.addCleanup(setattr, os.path, 'ismount', real)


class Folders(Fixture):

    def test_sizes_leave_out_the_named_folders_and_never_follow_links(self):
        items, left_out = bp.isle_state(self.folders)
        link = os.lstat(self.root / 'etc' / 'ca' / 'link-out').st_size
        self.assertEqual([(i['item'], i['sizeBytes'], i['unreadable']) for i in items],
                         [('isle-settings', 104 + link, 0), ('isle-state', 30, 0)])
        self.assertEqual([(os.path.basename(r['source']), r['sizeBytes'], r['reason']) for r in left_out],
                         [('apt', 5000, 'packages'), ('artifacts', 7000, 'releases'), ('operations', 900, 'journals')])

    def test_only_the_top_level_name_is_left_out(self):
        (self.root / 'etc' / 'ca' / 'apt').mkdir()
        (self.root / 'etc' / 'ca' / 'apt' / 'inner').write_bytes(b'x' * 11)
        items, _ = bp.isle_state(self.folders)
        self.assertEqual(items[0]['sizeBytes'] - os.lstat(self.root / 'etc' / 'ca' / 'link-out').st_size, 115)

    def test_a_hard_linked_file_counts_once(self):
        os.link(self.root / 'etc' / 'apt' / 'pool' / 'big', self.root / 'etc' / 'apt' / 'again')
        os.link(self.root / 'etc' / 'apt' / 'pool' / 'big', self.root / 'etc' / 'apt' / 'pool' / 'third')
        _, left_out = bp.isle_state(self.folders)
        self.assertEqual(left_out[0]['sizeBytes'], 5000)

    @unittest.skipIf(os.geteuid() == 0, 'root reads everything')
    def test_unreadable_folder_is_counted(self):
        locked = self.root / 'var' / 'storage' / 'locked'
        locked.mkdir()
        os.chmod(locked, 0)
        self.addCleanup(os.chmod, locked, 0o700)
        items, _ = bp.isle_state(self.folders)
        self.assertEqual(items[1]['unreadable'], 1)


class Target(Fixture):
    def place(self, path, needed=1000, free=5000, same=False, mount=True):
        self.mounted(mount)
        return bp.target(path, needed, usage=lambda p: Usage(0, 0, free), device_of=lambda p: 1 if same or p == '/' else 2)

    def test_none_chosen(self):
        doc = bp.target(None, 10)
        self.assertEqual((doc['chosen'], doc['usable']), (False, False))
        self.assertIn('--target', doc['reason'])

    def test_usable(self):
        doc = self.place(str(self.root))
        self.assertEqual((doc['usable'], doc['reason'], doc['freeBytes'], doc['neededBytes']), (True, None, 5000, 2000))

    def test_each_refusal(self):
        self.assertIn('not a folder', self.place(str(self.root / 'nowhere'))['reason'])
        self.assertIn('system filesystem', self.place(str(self.root), same=True)['reason'])
        self.assertIn('not a mount point', self.place(str(self.root), mount=False)['reason'])
        self.assertIn('twice', self.place(str(self.root), free=1999)['reason'])
        self.assertTrue(self.place(str(self.root), free=2000)['usable'])
        for doc in (self.place(str(self.root), same=True), self.place(str(self.root), free=1)):
            self.assertFalse(doc['usable'])


class Plan(Fixture):
    def plan(self, target=None, run=None, **kwargs):
        kwargs.setdefault('usage', lambda p: Usage(0, 0, 10**12))
        kwargs.setdefault('device_of', lambda p: 1 if p == '/' else 2)
        return bp.plan(target, run=run or docker([v for v in VOLUMES if v['Name'] != 'someone_else']), folders=self.folders,
                       device_file=str(self.root / 'etc' / 'device-name'), **kwargs)

    def test_ready_only_with_a_usable_target_and_everything_measured(self):
        self.mounted()
        doc = self.plan(str(self.root))
        self.assertEqual((doc['device'], doc['ready'], doc['sizesComplete'], doc['anonymousVolumes']), ('xxxx', True, True, 1))
        self.assertEqual(doc['totalBytes'], sum(i['sizeBytes'] for i in doc['items']))
        self.assertEqual(doc['target']['neededBytes'], 2 * doc['totalBytes'])
        self.assertFalse(self.plan()['ready'])

    def test_not_ready_while_a_volume_has_no_rule(self):
        self.mounted()
        doc = self.plan(str(self.root), run=docker())
        self.assertEqual((doc['ready'], len(doc['notCovered'])), (False, 1))

    def test_not_ready_when_docker_is_silent_or_a_size_is_missing(self):
        self.mounted()
        doc = self.plan(str(self.root), run=lambda args: None)
        self.assertEqual((doc['dockerReachable'], doc['ready'], doc['sizesComplete']), (False, False, False))
        self.assertEqual([i['kind'] for i in doc['items']], ['isle-folder', 'isle-folder'])
        doc = self.plan(str(self.root), run=docker([dict(Name='s_backend-data', Size='N/A')]))
        self.assertEqual((doc['ready'], doc['sizesComplete'], doc['items'][0]['sizeBytes']), (False, False, None))


class Main(Fixture):
    def main(self, *argv):
        lines = []
        code = bp.main(list(argv), out=lines.append, run=docker(), folders=self.folders,
                       device_file=str(self.root / 'absent'), usage=lambda p: Usage(0, 0, 10**12),
                       device_of=lambda p: 1 if p == '/' else 2)
        return code, lines[-1]

    def test_document(self):
        code, line = self.main('plan')
        data = json.loads(line)
        self.assertEqual((code, data['ok'], data['readOnly'], data['operation']), (0, True, True, 'backup.plan'))
        self.assertEqual(data['result']['target']['chosen'], False)
        self.assertTrue(data['result']['device'])

    def test_table_names_everything(self):
        code, text = self.main('plan', '--table')
        self.assertEqual(code, 0)
        for word in ('stack_backend-data', 'write gate up', 'Not covered', 'someone_else', 'Left out', 'journals', '--target'):
            self.assertIn(word, text)

    def test_unbuilt_verbs_answer_and_do_nothing(self):
        for verb in bp.NOT_BUILT:
            code, line = self.main(verb, 'anything')
            self.assertEqual((code, json.loads(line)['ok']), (2, False))
            self.assertIn('not built yet', line)

    def test_through_the_public_dispatch(self):
        (self.root / 'suite').mkdir()
        (self.root / 'suite' / 'setup-polari-security.sh').write_text('')
        env = dict(os.environ, POLARI_SUITE_ROOT=str(self.root / 'suite'))
        fake = self.root / 'bin'
        fake.mkdir()
        (fake / 'docker').write_text('#!/bin/sh\nexit 1\n')
        os.chmod(fake / 'docker', 0o755)
        env['PATH'] = str(fake) + os.pathsep + env['PATH']
        result = subprocess.run(['node', str(ENTRY), 'backup', 'plan', '--target', str(self.root / 'nowhere')],
                                env=env, capture_output=True, text=True, timeout=30)
        data = json.loads(result.stdout)
        self.assertEqual((result.returncode, data['operation'], data['result']['dockerReachable'], data['result']['ready']),
                         (0, 'backup.plan', False, False))


if __name__ == '__main__':
    unittest.main()
