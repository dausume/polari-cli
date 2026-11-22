"""pol build image: a recorded docker and git, temp folders; no image is built and no network is used."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / 'lib'))
import layer_image as li

OLD, NEW = 'a' * 40, 'b' * 40
BASE, TAG = 'polari-framework/prf-backend:one', 'polari-framework/prf-backend:two'
M, A, D = ':100644 100644 %s %s M' % ('1' * 40, '2' * 40), ':000000 100644 %s %s A' % ('0' * 40, '2' * 40), ':100644 000000 %s %s D' % ('1' * 40, '0' * 40)
LINK = ':160000 160000 %s %s M' % ('1' * 40, '2' * 40)


def raw(*pairs): return ''.join('%s\0%s\0' % pair for pair in pairs)


class Fake(li.Io):
    """Docker holds BASE (three layers, built from OLD); a build adds `adds` layers and the label of the commit."""
    def __init__(self, diff='', label=OLD, ancestor=True, adds=None, files=None):
        self.diff, self.label, self.ancestor, self.adds, self.files = diff, label, ancestor, adds, files or {}
        self.said, self.ran, self.recipe, self.context, self.built = [], [], None, None, False
        self.layer, self.image, self.removed = {}, None, []     # image: what a container of TAG holds, when not what was built

    def say(self, text): self.said.append(text)

    def run(self, argv, cwd=None, env=None, log=None):
        self.ran.append(list(argv))
        if argv[:3] == ['docker', 'image', 'inspect']:
            what, ref = argv[4], argv[5]
            if ref not in (BASE, TAG) or (ref == TAG and not self.built): return 1, ''
            if 'RootFS' in what: return 0, ' '.join('sha256:l%d' % n for n in range(3 + (self.adds if ref == TAG else 0)))
            if 'Labels' in what: return 0, (self.label if ref == BASE else NEW) + '\n'
            if 'WorkingDir' in what: return 0, '/app\n'
            return 0, 'sha256:' + ('1' if ref == BASE else '2') * 64 + '\n'
        if argv[0] == 'docker' and argv[1] == 'build':
            self.recipe = Path(argv[argv.index('-f') + 1]).read_text()
            self.context = sorted(str(p.relative_to(argv[-1])) for p in Path(argv[-1]).rglob('*') if p.is_file())
            if self.adds is None: self.adds = self.recipe.count('\nRUN ') + self.recipe.count('\nCOPY ')
            self.layer = {str(p.relative_to(argv[-1])): p.read_bytes() for p in Path(argv[-1]).rglob('*') if p.is_file()}
            self.built = True
            return 0, ''
        if argv[:2] == ['docker', 'run']:
            assert argv[2:5] == ['--rm', '--network', 'none'], argv          # never the network
            pages = li.PAGES in argv[-1]
            has = self.image if self.image is not None else (
                {n[5:]: b for n, b in self.layer.items() if n.startswith('html/')} if pages else {n: b for n, b in self.files.items() if n != '.gitignore'})
            return 0, ''.join('%s  ./%s\n' % (hashlib.sha256(b).hexdigest(), n) for n, b in sorted(has.items()))
        if argv[:3] == ['docker', 'image', 'rm']:
            self.removed.append(argv[3]); return 0, ''
        if 'rev-parse' in argv: return 0, NEW + '\n'
        if 'merge-base' in argv: return (0 if self.ancestor else 1), ''
        if 'diff' in argv: return 0, self.diff
        if argv[0] == 'npx':
            out = Path(cwd) / 'dist' / 'polari-platform'
            out.mkdir(parents=True); (out / 'index.html').write_text('<html>'); (out / 'main-1.js').write_text('x')
            return 0, ''
        raise AssertionError('not expected: %s' % argv)

    def read(self, source, sha, path): return self.files.get(path)

    def tree(self, source, sha, dest, only=None):
        names = [n for n in self.files if only is None or n in only]
        for name in names:
            (Path(dest) / name).parent.mkdir(parents=True, exist_ok=True); (Path(dest) / name).write_bytes(self.files[name])
        return len(names)


def run(io, argv):
    code = li.main(argv, io)
    return code, '\n'.join(io.said)


class Backend(unittest.TestCase):
    ARGV = ['backend', '--base', BASE, '--tag', TAG, '--source', '/nowhere']

    def test_changed_and_added_files_go_on_top_as_one_layer(self):
        io = Fake(raw((M, 'modules/hal/a.py'), (A, 'modules/hal/b b.py')), files={'modules/hal/a.py': b'1', 'modules/hal/b b.py': b'2', 'other.py': b'3'})
        code, said = run(io, self.ARGV)
        self.assertEqual(code, 0, said)
        self.assertEqual(io.recipe, 'FROM %s\nCOPY . /app/\nLABEL %s=%s\n' % (BASE, li.REVISION, NEW))
        self.assertEqual(io.context, ['modules/hal/a.py', 'modules/hal/b b.py'])       # the unchanged file is not in the layer
        build = next(a for a in io.ran if a[:2] == ['docker', 'build'])
        self.assertIn('--pull=false', build); self.assertEqual(build[build.index('--network') + 1], 'none')
        self.assertIn('the 3 of %s, and 1 new' % BASE, said); self.assertIn('2 in the new layer', said)

    def test_the_files_of_the_commit_are_compared_with_what_the_image_holds(self):
        files = {'modules/hal/a.py': b'1', 'other.py': b'3', '.gitignore': b'x'}
        io = Fake(raw((M, 'modules/hal/a.py')), files=files)
        code, said = run(io, self.ARGV)
        self.assertEqual(code, 0, said)
        self.assertIn('2 files of the commit are in the image byte for byte', said)
        self.assertIn('1 files of the commit are not in the image: .gitignore', said)
        io = Fake(raw((M, 'modules/hal/a.py')), files=files); io.image = {'modules/hal/a.py': b'1', 'other.py': b'not the commit'}
        code, said = run(io, self.ARGV)
        self.assertEqual(code, 1); self.assertIn('1 differ (other.py)', said); self.assertEqual(io.removed, [TAG])

    def test_a_file_the_dockerignore_leaves_out_may_stay_as_the_base_has_it(self):
        files = {'a.py': b'1', '.gitignore': b'new', 'deep/.gitignore': b'new', '.dockerignore': b'# no\n**/.gitignore\n'}
        io = Fake(raw((M, 'a.py'), (M, '.gitignore')), files=files); io.image = dict(files, **{'.gitignore': b'old'})
        code, said = run(io, self.ARGV)
        self.assertEqual(code, 0, said)
        self.assertIn('3 files of the commit are in the image byte for byte', said)
        self.assertIn('1 files of the commit the .dockerignore leaves out of every build, and the image holds as its base has them: .gitignore', said)

    def test_the_lines_of_a_dockerignore(self):
        rules = li.ignore_rules('# c\n**/.gitignore\n**/bin\nREADME.md\n**/compose*\n*.tmp\ndocs/**\n!docs/keep.md\n/top\n')
        for path, out in (('.gitignore', True), ('a/b/.gitignore', True), ('a/bin/x.py', True), ('bin', True), ('cabin/x', False), ('README.md', True),
                          ('a/README.md', False), ('a/compose.yml', True), ('x.tmp', True), ('a/x.tmp', False), ('docs/a/b.md', True), ('docs/keep.md', False),
                          ('top/a', True), ('a/top', False), ('modules/hal/a.py', False)):
            self.assertEqual(li.left_out(rules, path), out, path)

    def test_a_removed_file_is_removed_in_a_layer_before_the_copy(self):
        io = Fake(raw((M, 'a.py'), (D, "old it's.py")), files={'a.py': b'1'})
        code, said = run(io, self.ARGV)
        self.assertEqual(code, 0, said)
        self.assertEqual(io.recipe.splitlines()[1:3], ['RUN rm -f -- \'/app/old it\'"\'"\'s.py\'', 'COPY . /app/'])
        self.assertIn('1 removed', said)

    def test_what_a_layer_cannot_carry_is_refused_before_docker_builds(self):
        for diff, label, ancestor, word in ((raw((M, 'requirements.txt')), OLD, True, 'build the image whole'),
                                            (raw((LINK, 'polariMaterialsScienceModule')), OLD, True, 'submodule'),
                                            (raw((M, 'a.py')), OLD, False, 'not in the history'),
                                            (raw((M, 'a.py')), '3e26ebdf', True, 'does not say which revision')):
            io = Fake(diff, label=label, ancestor=ancestor, files={'a.py': b'1'})
            code, said = run(io, self.ARGV)
            self.assertEqual(code, 1); self.assertIn(word, said)
            self.assertFalse(io.built)

    def test_an_image_that_is_not_the_base_plus_the_new_layer_is_refused(self):
        code, said = run(Fake(raw((M, 'a.py')), adds=2, files={'a.py': b'1'}), self.ARGV)
        self.assertEqual(code, 1); self.assertIn('plus 1 layer(s)', said)

    def test_a_base_built_from_the_commit_already_builds_nothing(self):
        io = Fake(label=NEW)
        code, said = run(io, self.ARGV)
        self.assertEqual(code, 0); self.assertIn('Nothing to build', said); self.assertFalse(io.built)

    def test_the_name_must_be_new(self):
        self.assertEqual(run(Fake(), ['backend', '--base', BASE, '--tag', BASE])[0], 2)
        io = Fake(); io.built = True                       # Docker holds TAG already
        code, said = run(io, self.ARGV)
        self.assertEqual(code, 1); self.assertIn('choose another --tag', said)


class Frontend(unittest.TestCase):
    def checkout(self, lock):
        folder = Path(tempfile.mkdtemp(prefix='li-test-'))
        self.addCleanup(__import__('shutil').rmtree, folder, True)
        (folder / 'node_modules').mkdir(); (folder / 'package-lock.json').write_bytes(lock)
        return folder

    def test_the_built_pages_replace_the_pages_of_the_base(self):
        io = Fake(files={'package-lock.json': b'{}', 'nginx.conf': b'events {}', 'src/main.ts': b''})
        code, said = run(io, ['frontend', '--base', BASE, '--tag', TAG, '--source', str(self.checkout(b'{}'))])
        self.assertEqual(code, 0, said)
        self.assertEqual(io.recipe.splitlines()[1:4], ['RUN rm -rf /usr/share/nginx/html', 'COPY nginx.conf /etc/nginx/nginx.conf',
                                                       'COPY html /usr/share/nginx/html'])
        self.assertEqual(io.context, ['html/index.html', 'html/main-1.js', 'nginx.conf'])
        self.assertIn('and 3 new', said); self.assertIn('2 files of the built pages are in the image byte for byte', said)

    def test_pages_of_the_base_that_stayed_refuse_the_image(self):
        io = Fake(files={'package-lock.json': b'{}', 'nginx.conf': b'events {}'})
        io.image = {'index.html': b'<html>', 'main-1.js': b'x', 'main-0.js': b'old'}
        code, said = run(io, ['frontend', '--base', BASE, '--tag', TAG, '--source', str(self.checkout(b'{}'))])
        self.assertEqual(code, 1); self.assertIn('1 more than the built ones (main-0.js)', said); self.assertEqual(io.removed, [TAG])

    def test_packages_of_another_lock_file_are_refused(self):
        io = Fake(files={'package-lock.json': b'{"new": 1}', 'nginx.conf': b''})
        code, said = run(io, ['frontend', '--base', BASE, '--tag', TAG, '--source', str(self.checkout(b'{}'))])
        self.assertEqual(code, 1); self.assertIn('not the ones the commit asks for', said)
        self.assertFalse(any(a[0] == 'npx' for a in io.ran))


class Parsing(unittest.TestCase):
    def test_the_raw_diff_is_read_by_its_separators(self):
        self.assertEqual(li.changes(raw((M, 'a b.py'), (D, 'c.py'), (LINK, 'sub'))), [('M', 'a b.py', False), ('D', 'c.py', False), ('M', 'sub', True)])
        self.assertEqual(li.changes(''), [])

    def test_usage_errors(self):
        for argv in ([], ['both'], ['backend', '--base', BASE], ['backend', '--base', BASE, '--tag'], ['frontend', '--nope', 'x']):
            self.assertEqual(li.main(argv, Fake()), 2)


if __name__ == '__main__':
    unittest.main()
