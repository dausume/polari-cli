#!/usr/bin/env python3
"""pol build image: the next backend or frontend image of a release, made without the network.

  pol build image backend  --base <image> --tag <image> [--source <checkout>] [--commit <rev>]
  pol build image frontend --base <image> --tag <image> [--source <checkout>] [--commit <rev>]

  --base    the image the isle runs now (Docker on this machine holds it)
  --tag     the name of the image this makes
  --source  the checkout (default: polari-framework / polari-platform-angular of this suite)
  --commit  what to build (default: HEAD).  The commit is built, not the files on disk

The Dockerfiles build an image whole, and that needs the network (the image they start from, the packages).
A release that changes only the source needs none of it:

  backend   the base image carries the revision it was built from (the label org.opencontainers.image.revision).
            The files that differ between that revision and the commit go on top as ONE layer; files the commit
            no longer has are removed in a layer before it.  Refused, because a layer cannot carry it: a change of
            requirements.txt, Dockerfile or .dockerignore, a moved submodule, a base revision that is not in the
            history of the commit.  Those need the whole build on a machine with the network.
  frontend  `ng build --configuration=production` of the commit, with the packages installed in the checkout
            (refused when the commit's package-lock.json is not the checkout's), and the output replaces the
            pages of the base image: three layers (remove, nginx.conf, pages).

Docker builds with --pull=false --network none.  What is made is checked: the layers of the base, then exactly
the new ones, and the label of the commit; and the files, read from a container of the image that runs once with
no network: every file of the commit (backend) or of the built pages (frontend) that the image holds is the same
byte for byte, and one that differs refuses the image and removes it.  The one exception is named, not refused:
a file the commit's .dockerignore leaves out of every build stays as the base image has it, or is not there.
Nothing is published, installed or sent; `isle release build
--runtime-image <container>=<image>` puts the image into a release.
"""
import hashlib
import io as _io
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

REVISION = 'org.opencontainers.image.revision'
RECIPE = ('requirements.txt', 'Dockerfile', '.dockerignore')
PAGES = '/usr/share/nginx/html'
SHA1 = re.compile(r'[0-9a-f]{40}\Z')


class Refused(Exception): pass


class Io:
    def say(self, text): print(text, flush=True)

    def run(self, argv, cwd=None, env=None, log=None):
        if log is None:
            done = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            return done.returncode, done.stdout
        with open(log, 'a') as out:
            return subprocess.run(argv, cwd=cwd, env=env, stdout=out, stderr=subprocess.STDOUT).returncode, ''

    def read(self, source, sha, path):
        """The bytes of one file of the commit, or None when the commit has no such file."""
        done = subprocess.run(['git', '-C', str(source), 'show', '%s:%s' % (sha, path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return done.stdout if done.returncode == 0 else None

    def tree(self, source, sha, dest, only=None):
        """The files of the commit (all, or the ones named) under dest."""
        done = subprocess.run(['git', '-C', str(source), 'archive', '--format=tar', sha], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if done.returncode != 0: raise Refused('git archive of %s failed in %s' % (sha[:12], source))
        with tarfile.open(fileobj=_io.BytesIO(done.stdout)) as tar:
            members = [m for m in tar.getmembers() if only is None or m.name in only]
            try: tar.extractall(dest, members=members, filter='data')
            except TypeError: tar.extractall(dest, members=members)      # a Python before the filters
        return len([m for m in members if not m.isdir()])


def inspect(io, ref, what):
    status, out = io.run(['docker', 'image', 'inspect', '--format', what, ref])
    return out.strip() if status == 0 else None


def layers(io, ref):
    out = inspect(io, ref, '{{range .RootFS.Layers}}{{.}} {{end}}')
    if not out: raise Refused('Docker on this machine does not hold the image %s' % ref)
    return out.split()


def commit_of(io, source, commit):
    status, out = io.run(['git', '-C', str(source), 'rev-parse', '--verify', '--quiet', commit + '^{commit}'])
    if status != 0 or not SHA1.fullmatch(out.strip()): raise Refused('%s holds no commit %s' % (source, commit))
    return out.strip()


def changes(raw):
    """`git diff --raw --no-renames --no-abbrev -z` -> [(status, path, is a submodule)]."""
    parts, out = raw.split('\0'), []
    for meta, path in zip(parts[0::2], parts[1::2]):
        old, new, _a, _b, status = meta.lstrip(':').split()
        out.append((status[0], path, '160000' in (old, new)))
    return out


def backend_plan(base_rev, sha, rows):
    """-> (the files the layer holds, the files it removes).  Refuses what a layer cannot carry."""
    recipe = sorted(path for _s, path, _l in rows if path in RECIPE)
    if recipe:
        raise Refused('%s changed between the revision of the base image (%s) and the commit (%s). A layer cannot carry that: '
                      'build the image whole from the Dockerfile on a machine with the network' % (', '.join(recipe), base_rev[:12], sha[:12]))
    moved = sorted(path for _s, path, link in rows if link)
    if moved: raise Refused('the submodule %s moved between the base image and the commit; a layer made from this checkout cannot hold its files' % ', '.join(moved))
    odd = sorted(s for s, _p, _l in rows if s not in 'AMTD')
    if odd: raise Refused('git names a change of kind %s; this builder knows added, changed and removed files' % odd[0])
    return sorted(p for s, p, _l in rows if s != 'D'), sorted(p for s, p, _l in rows if s == 'D')


def build(io, work, base, tag, lines, context, sha, added):
    """Write the Dockerfile outside the context, build with no network, and check what Docker made."""
    was = layers(io, base)
    recipe = work / 'Dockerfile'
    recipe.write_text('FROM %s\n%s\nLABEL %s=%s\n' % (base, '\n'.join(lines), REVISION, sha))
    log = work / 'build.log'
    if io.run(['docker', 'build', '--pull=false', '--network', 'none', '-f', str(recipe), '-t', tag, str(context)], log=str(log))[0] != 0:
        tail = log.read_text(errors='replace').splitlines()[-12:] if log.is_file() else []
        raise Refused('docker build of %s failed:\n  %s' % (tag, '\n  '.join(tail)))
    now = layers(io, tag)
    if now[:len(was)] != was or len(now) != len(was) + added or inspect(io, tag, '{{index .Config.Labels "%s"}}' % REVISION) != sha:
        raise Refused('what Docker built as %s is not %s plus %d layer(s) with the label of the commit' % (tag, base, added))
    return {'tag': tag, 'id': inspect(io, tag, '{{.Id}}'), 'base': base, 'baseLayers': len(was), 'layers': len(now), 'revision': sha}


def held(io, ref, folder):
    """{path: sha256} of the files the image holds under the folder."""
    status, out = io.run(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'sh', ref, '-c',
                          'cd %s && find . -type f -exec sha256sum {} +' % shlex.quote(folder)])
    if status != 0: raise Refused('a container of %s could not list the files under %s' % (ref, folder))
    return {line[68:] if line[66:68] == './' else line[66:]: line[:64] for line in out.splitlines() if len(line) > 66}


def ignore_rules(text):
    """The lines of a .dockerignore as [(keeps, pattern)]: * and ? within one name, ** across folders, ! keeps; a
    pattern names a path and everything under it, and the last line that matches decides."""
    rules = []
    for line in (text or '').splitlines():
        line = line.strip()
        if not line or line.startswith('#'): continue
        keeps = line.startswith('!')
        pattern, out, i = line[keeps:].strip().strip('/'), '', 0
        while i < len(pattern):
            if pattern.startswith('**/', i): out += '(?:.*/)?'; i += 3
            elif pattern.startswith('**', i): out += '.*'; i += 2
            elif pattern[i] == '*': out += '[^/]*'; i += 1
            elif pattern[i] == '?': out += '[^/]'; i += 1
            else: out += re.escape(pattern[i]); i += 1
        rules.append((keeps, re.compile(out + r'(?:/.*)?\Z')))
    return rules


def left_out(rules, path):
    out = False
    for keeps, pattern in rules:
        if pattern.match(path): out = not keeps
    return out


def same_files(io, tag, folder, tree, whole, rules=()):
    """Compare the image's files under the folder with the files under tree.  -> {'same': how many, 'missing': the
    ones the image does not hold, 'stale': the ones .dockerignore leaves out and the image holds otherwise}.
    Another file that differs, or (whole) one the image holds beyond them, refuses and removes the image."""
    has = held(io, tag, folder)
    want = {str(p.relative_to(tree)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(tree).rglob('*')) if p.is_file() and not p.is_symlink()}
    differs = sorted(name for name, sha in want.items() if name in has and has[name] != sha)
    stale = [name for name in differs if left_out(rules, name)]
    differs = [name for name in differs if name not in stale]
    extra = sorted(set(has) - set(want)) if whole else []
    if differs or extra:
        io.run(['docker', 'image', 'rm', tag])
        raise Refused('the image built as %s does not hold the files it was built for: %d differ%s%s. It was removed'
                      % (tag, len(differs), ' (%s)' % ', '.join(differs[:5]) if differs else '',
                         '; %d more than the built ones (%s)' % (len(extra), ', '.join(extra[:5])) if extra else ''))
    return {'same': len([name for name in want if name in has]) - len(stale), 'missing': sorted(set(want) - set(has)), 'stale': stale}


def backend(io, base, source, commit, tag, work):
    sha, base_rev = commit_of(io, source, commit), inspect(io, base, '{{index .Config.Labels "%s"}}' % REVISION)
    if base_rev is None: raise Refused('Docker on this machine does not hold the image %s' % base)
    if not SHA1.fullmatch(base_rev):
        raise Refused('the image %s does not say which revision it was built from (the label %s), so what changed since cannot be known' % (base, REVISION))
    if base_rev == sha: return {'kept': True, 'tag': base, 'revision': sha}
    if io.run(['git', '-C', str(source), 'merge-base', '--is-ancestor', base_rev, sha])[0] != 0:
        raise Refused('the base image was built from %s, which is not in the history of %s (or not in this checkout); a layer on top would '
                      'keep files of another line' % (base_rev[:12], sha[:12]))
    app = inspect(io, base, '{{.Config.WorkingDir}}')
    if not app or not app.startswith('/'): raise Refused('the image %s names no working folder, so where its source lives is not known' % base)
    status, raw = io.run(['git', '-C', str(source), 'diff', '--raw', '--no-renames', '--no-abbrev', '-z', base_rev, sha])
    if status != 0: raise Refused('git diff %s..%s failed in %s' % (base_rev[:12], sha[:12], source))
    files, gone = backend_plan(base_rev, sha, changes(raw))
    context = work / 'context'
    context.mkdir(parents=True)
    io.tree(source, sha, context, set(files) | {'.dockerignore'})
    lines = (['RUN rm -f -- ' + ' '.join(shlex.quote('%s/%s' % (app.rstrip('/'), p)) for p in gone)] if gone else []) + ['COPY . %s/' % app.rstrip('/')]
    made = build(io, work, base, tag, lines, context, sha, 1 + bool(gone))
    whole = work / 'commit'
    whole.mkdir()
    io.tree(source, sha, whole)
    rules = ignore_rules((io.read(source, sha, '.dockerignore') or b'').decode('utf-8', 'replace'))
    return dict(made, baseRevision=base_rev, files=len(files), removed=len(gone), **same_files(io, tag, app, whole, False, rules))


def frontend(io, base, source, commit, tag, work, heap_mb=3072):
    sha = commit_of(io, source, commit)
    if inspect(io, base, '{{.Id}}') is None: raise Refused('Docker on this machine does not hold the image %s' % base)
    if inspect(io, base, '{{index .Config.Labels "%s"}}' % REVISION) == sha: return {'kept': True, 'tag': base, 'revision': sha}
    lock, held = io.read(source, sha, 'package-lock.json'), Path(source) / 'package-lock.json'
    if not (Path(source) / 'node_modules').is_dir(): raise Refused('%s holds no installed packages (node_modules); installing them is a download' % source)
    if lock is None or not held.is_file() or held.read_bytes() != lock:
        raise Refused('the package-lock.json of the commit is not the one in %s, so the packages installed there are not the ones the commit asks for' % source)
    src = work / 'src'
    src.mkdir(parents=True)
    io.tree(source, sha, src)
    (src / 'node_modules').symlink_to(Path(source).resolve() / 'node_modules')
    io.say('  ng build --configuration=production of %s (a few minutes)' % sha[:12])
    env = dict(os.environ, NODE_OPTIONS='--max-old-space-size=%d' % heap_mb, CI='1', NG_CLI_ANALYTICS='false')
    log = work / 'ng-build.log'
    if io.run(['npx', '--no-install', 'ng', 'build', '--configuration=production'], cwd=str(src), env=env, log=str(log))[0] != 0:
        tail = log.read_text(errors='replace').splitlines()[-15:] if log.is_file() else []
        raise Refused('ng build failed:\n  %s' % '\n  '.join(tail))
    pages = src / 'dist' / 'polari-platform'
    if not (pages / 'index.html').is_file(): raise Refused('ng build left no dist/polari-platform/index.html')
    context = work / 'context'
    context.mkdir()
    shutil.copytree(pages, context / 'html', symlinks=False)
    shutil.copyfile(src / 'nginx.conf', context / 'nginx.conf')
    lines = ['RUN rm -rf %s' % PAGES, 'COPY nginx.conf /etc/nginx/nginx.conf', 'COPY html %s' % PAGES]
    made = build(io, work, base, tag, lines, context, sha, 3)
    found = same_files(io, tag, PAGES, context / 'html', True)
    if found['missing']:
        io.run(['docker', 'image', 'rm', tag])
        raise Refused('the image built as %s lacks %d of the built pages (%s). It was removed' % (tag, len(found['missing']), ', '.join(found['missing'][:5])))
    return dict(made, files=found['same'], **found)


def parse(argv):
    if not argv or argv[0] not in ('backend', 'frontend'): raise ValueError('say which image: backend or frontend')
    one, i = {'--base': None, '--tag': None, '--source': None, '--commit': 'HEAD'}, 1
    while i < len(argv):
        if argv[i] not in one or i + 1 >= len(argv): raise ValueError('unknown option, or an option without its value: %s' % argv[i])
        one[argv[i]] = argv[i + 1]; i += 2
    if not one['--base'] or not one['--tag']: raise ValueError('--base <image> and --tag <image> are needed')
    if one['--base'] == one['--tag']: raise ValueError('--tag must be a new name: an image name does not change what it means')
    return argv[0], one


def main(argv, io=None):
    io = io or Io()
    if argv and argv[0] in ('-h', '--help', 'help'): io.say(__doc__); return 0
    try: kind, one = parse(argv)
    except ValueError as exc:
        io.say('pol build image: %s' % exc); io.say(__doc__.split('\n\n')[1]); return 2
    folder = 'polari-framework' if kind == 'backend' else 'polari-platform-angular'
    source = Path(os.path.abspath(one['--source'] or os.path.join(os.environ.get('POL_RF_NODE', '.'), folder)))
    work = Path(tempfile.mkdtemp(prefix='pol-image-'))
    try:
        if inspect(io, one['--tag'], '{{.Id}}') is not None:
            raise Refused('Docker here already holds an image named %s; an image name does not change what it means, so choose another --tag' % one['--tag'])
        made = (backend if kind == 'backend' else frontend)(io, one['--base'], source, one['--commit'], one['--tag'], work)
    except Refused as exc:
        io.say('REFUSED: pol build image %s: %s' % (kind, exc)); return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if made.get('kept'):
        io.say('Nothing to build: %s was built from the commit %s already.' % (made['tag'], made['revision'][:12])); return 0
    io.say('Built %s' % made['tag'])
    io.say('  image id   %s' % made['id'])
    io.say('  commit     %s' % made['revision'])
    io.say('  layers     the %d of %s, and %d new' % (made['baseLayers'], made['base'], made['layers'] - made['baseLayers']))
    io.say('  files      %d in the new layer%s' % (made['files'], ', %d removed' % made['removed'] if made.get('removed') else ''))
    io.say('  checked    %d files of the %s are in the image byte for byte' % (made['same'], 'commit' if kind == 'backend' else 'built pages'))
    for names, words in ((made['stale'], 'the .dockerignore leaves out of every build, and the image holds as its base has them'), (made['missing'], 'are not in the image')):
        if names: io.say('             %d files of the commit %s: %s%s' % (len(names), words, ', '.join(names[:8]), ' ...' if len(names) > 8 else ''))
    io.say('It is built only: Docker on this machine holds it. Into a release: isle release build ... --runtime-image <container>=%s' % made['tag'])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
