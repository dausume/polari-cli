#!/bin/bash
# Verify a COMPLETE core medium before any host configuration is changed.
set -eu
POOL="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 - "$POOL" <<'PYVERIFY'
import hashlib,io,json,pathlib,re,subprocess,sys,tarfile,zipfile
root=pathlib.Path(sys.argv[1]).resolve()
def need(ok,msg):
    if not ok: raise ValueError(msg)
def path(name):
    p=root/name
    need(not p.is_symlink() and p.resolve().is_relative_to(root),'unsafe medium path: '+name)
    need(p.is_file(),'missing medium file: '+name)
    return p
try:
    path('ISLE_OFFLINE_BUNDLE')
    path('scripts/offline-apt.sh')
    m=json.loads(path('manifest.json').read_text())
    need(m.get('flavor')=='offline','manifest flavor must be offline')
    need(m.get('polari'),'manifest missing polari version')
    sections=('debs','apt','images','router','modules','engines','hardware','scripts')
    for s in sections:
        need((root/s).is_dir(),'missing section: '+s+'/')
    for s in ('debs','apt','images','router','scripts'):
        need(m.get('sections',{}).get(s,{}).get('present') is True and not (root/s/'EMPTY').exists(),'mandatory section incomplete: '+s+'/')
    # Every consumed file must be covered, not merely the files somebody chose
    # to list in SHA256SUMS. Hashes provide integrity, not publisher identity.
    sums={}
    for line in path('SHA256SUMS').read_text().splitlines():
        need(len(line)>66 and re.fullmatch('[0-9a-fA-F]{64}',line[:64]),'malformed SHA256SUMS')
        name=line[66:]
        if name.startswith('./'): name=name[2:]
        need(name not in sums,'duplicate checksum: '+name)
        sums[name]=line[:64].lower()
    for p in root.rglob('*'):
        need(not p.is_symlink(),'symlinks are not permitted in medium: '+str(p))
        if not p.is_file() or p.name=='SHA256SUMS': continue
        name=str(p.relative_to(root));need(name in sums,'file omitted from SHA256SUMS: '+name)
    for name,digest in sums.items():
        p=path(name);h=hashlib.sha256()
        with p.open('rb') as f:
            for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
        need(h.hexdigest()==digest,'SHA256SUMS mismatch: '+name)
    osinfo={}
    for line in pathlib.Path('/etc/os-release').read_text().splitlines():
        if '=' in line:
            k,v=line.split('=',1);osinfo[k]=v.strip('"')
    host=osinfo.get('ID','')+'-'+osinfo.get('VERSION_ID','')
    need(m.get('target')==host,'incompatible target: medium %s, host %s'%(m.get('target'),host))
    arch=subprocess.check_output(['dpkg','--print-architecture'],text=True).strip()
    need(m.get('architecture')==arch,'incompatible/missing architecture: medium %s, host %s'%(m.get('architecture'),arch))
    deps=m.get('requiredPackages');need(isinstance(deps,list) and deps,'apt/: requiredPackages must be nonempty')
    cached=m.get('cachedPackages',[]);need(isinstance(cached,list),'apt/: cachedPackages must be a list')
    deps=deps+cached
    for dep in deps:
        need(isinstance(dep,str) and all(re.fullmatch(r'[a-z0-9][a-z0-9+.-]*(?::[a-z0-9-]+)?(?: \((?:>=|<=|=|>>|<<) [A-Za-z0-9.+:~_-]+\))?',alternative.strip()) for alternative in dep.split('|')),'unsupported requiredPackages dependency: '+str(dep))
    path('apt/Packages');need(any((root/'apt').glob('*.deb')),'apt/: no closure debs')
    # A flat repository must not refer outside itself, even with trusted=yes.
    packages={}
    for stanza in (root/'apt/Packages').read_text().split('\n\n'):
        fields=dict(line.split(': ',1) for line in stanza.splitlines() if ': ' in line and not line.startswith(' '))
        if not fields: continue
        filename=fields.get('Filename','');need(filename and not filename.startswith('/'),'apt/: invalid Filename')
        p=path('apt/'+filename);need(p.suffix=='.deb','apt/: non-deb Filename')
        need(fields.get('Architecture') in (arch,'all'),'apt/: incompatible package architecture: '+filename)
        need(fields.get('SHA256')==sums.get(str(p.relative_to(root))),'apt/: Package index checksum mismatch: '+filename)
        packages.setdefault(fields.get('Package'),[]).append(fields.get('Version'))
    for dep in deps:
        available=False
        for alternative in dep.split('|'):
            match=re.fullmatch(r'([^ (]+)(?: \(([^ ]+) ([^)]+)\))?',alternative.strip());pkg,op,version=match.groups()
            candidates=packages.get(pkg.split(':')[0],[])
            available=available or any(not op or subprocess.run(['dpkg','--compare-versions',v,op,version]).returncode==0 for v in candidates)
        need(available,'apt/: required dependency absent or too old: '+dep)
    debname=m.get('debs',{}).get('polari-complete-offline')
    need(isinstance(debname,str),'debs/: missing polari-complete-offline entry')
    deb=path('debs/'+debname)
    need(subprocess.check_output(['dpkg-deb','-f',str(deb),'Package'],text=True).strip()=='polari-complete-offline','debs/: wrong platform package')
    need(subprocess.check_output(['dpkg-deb','-f',str(deb),'Architecture'],text=True).strip() in (arch,'all'),'debs/: wrong architecture')
    runtime=m.get('desktopRuntime')
    need(isinstance(runtime,dict) and runtime.get('package')=='polari-shell-core','debs/: mandatory desktopRuntime package inventory missing')
    runtime_name=runtime.get('file')
    need(isinstance(runtime_name,str) and pathlib.PurePosixPath(runtime_name).name==runtime_name,'debs/: invalid desktopRuntime filename')
    runtime_deb=path('debs/'+runtime_name)
    need(subprocess.check_output(['dpkg-deb','-f',str(runtime_deb),'Package'],text=True).strip()=='polari-shell-core','debs/: desktopRuntime is not polari-shell-core')
    need(arch=='amd64' and subprocess.check_output(['dpkg-deb','-f',str(runtime_deb),'Architecture'],text=True).strip()=='amd64','debs/: desktopRuntime requires linux-amd64')
    def validate_jcef(package_deb):
        native_prefix='opt/polari-shell/lib/jcef-natives/'
        native_names={'libcef.so','libjcef.so','jcef_helper','icudtl.dat','resources.pak','build_meta.json'}
        found=set();native_metadata=None;api_metadata=None
        process=subprocess.Popen(['dpkg-deb','--fsys-tarfile',str(package_deb)],stdout=subprocess.PIPE)
        try:
            # Stream past the large native binaries. Only small JSON/JAR members
            # are retained, with explicit limits; never unpack or execute natives.
            with tarfile.open(fileobj=process.stdout,mode='r|*') as filesystem:
                for member in filesystem:
                    name=str(pathlib.PurePosixPath(member.name))
                    if name.startswith(native_prefix) and name[len(native_prefix):] in native_names:
                        leaf=name[len(native_prefix):]
                        need(member.isfile() and member.size>0 and leaf not in found,'debs/: missing/invalid bundled JCEF native: '+leaf)
                        found.add(leaf)
                        if leaf=='build_meta.json':
                            need(member.size<=65536,'debs/: oversized native build metadata')
                            native_metadata=json.load(filesystem.extractfile(member))
                    if name.startswith('opt/polari-shell/lib/app/jcef-api') and name.endswith('.jar'):
                        need(api_metadata is None and member.isfile() and member.size<=16*1024*1024,'debs/: invalid/duplicate JCEF API JAR')
                        with zipfile.ZipFile(io.BytesIO(filesystem.extractfile(member).read())) as jar:
                            info=jar.getinfo('build_meta.json')
                            need(info.file_size<=65536,'debs/: oversized JCEF API metadata')
                            api_metadata=json.loads(jar.read(info))
            process.stdout.close()
            need(process.wait()==0,'debs/: could not read desktop runtime filesystem')
        finally:
            process.stdout.close()
            if process.poll() is None:process.terminate()
            process.wait()
        need(found==native_names,'debs/: bundled JCEF native files missing: '+', '.join(sorted(native_names-found)))
        need(isinstance(native_metadata,dict) and native_metadata.get('platform')=='linux-amd64','debs/: JCEF native platform must be linux-amd64')
        need(isinstance(api_metadata,dict) and native_metadata.get('release_tag') and native_metadata['release_tag']==api_metadata.get('release_tag'),'debs/: JCEF native/API release tags differ or API metadata missing')
        return native_metadata['release_tag']
    runtime_release=validate_jcef(runtime_deb)
    need(validate_jcef(deb)==runtime_release,'debs/: merged platform JCEF release differs from selected desktopRuntime')
    entries=json.loads(path('images/images.json').read_text());required=m.get('requiredImages')
    need(isinstance(required,list) and required,'images/: requiredImages must be nonempty')
    refs={}
    for e in entries:
        ref=e['name']+':'+e['tag'];need(ref not in refs,'images/: duplicate '+ref);refs[ref]=e
        need(re.fullmatch(r'sha256:[0-9a-f]{64}',e.get('id','')),'images/: invalid image ID for '+ref)
        archive=path('images/'+e['file'])
        with tarfile.open(archive) as tar:
            manifests=json.load(tar.extractfile('manifest.json'))
            matching=[entry for entry in manifests if ref in (entry.get('RepoTags') or [])]
            need(len(matching)==1,'images/: archive does not contain exactly one '+ref)
            config=tar.extractfile(matching[0]['Config'])
            need(config is not None,'images/: missing config for '+ref)
            content=config.read()
            need('sha256:'+hashlib.sha256(content).hexdigest()==e['id'],'images/: archive image ID mismatch for '+ref)
            metadata=json.loads(content)
            need(metadata.get('architecture')=={'i386':'386','armhf':'arm'}.get(arch,arch) and metadata.get('os')=='linux','images/: incompatible OS/architecture for '+ref)
    need(all(ref in refs for ref in required),'images/: missing required image inventory')
    router=m.get('router',{});need(router.get('file'),'router/: missing image entry')
    need(path('router/'+router['file']).stat().st_size>0,'router/: empty image')
    ipks=router.get('packages');need(isinstance(ipks,list) and ipks,'router/: missing offline IPK closure')
    for name in ipks: need(path('router/'+name).stat().st_size>0 and name.endswith('.ipk'),'router/: invalid IPK '+name)
    metadata_name=router.get('metadata')
    need(isinstance(metadata_name,str),'router/: missing build metadata entry')
    metadata=json.loads(path('router/'+metadata_name).read_text())
    image_key=str(path('router/'+router['file']).relative_to(root))
    need(re.fullmatch(r'[0-9a-f]{64}',metadata.get('imageSha256','')) and metadata['imageSha256']==sums.get(image_key),'router/: image does not match pristine build metadata')
    need(re.fullmatch(r'[0-9a-f]{64}',metadata.get('baseSha256','')),'router/: missing pinned base checksum')
    roots=metadata.get('roots');base=metadata.get('basePackages');selected=metadata.get('packages')
    need(isinstance(roots,list) and {'avahi-dbus-daemon','avahi-utils','ip-full','tcpdump'}.issubset(roots),'router/: required root package inventory incomplete')
    need(isinstance(base,dict) and base and all(isinstance(v,str) and v for v in base.values()),'router/: missing base package versions')
    need(isinstance(selected,dict) and selected,'router/: missing selected package inventory')
    inventory=[]
    for package,entry in selected.items():
        filename=entry['file']
        need(isinstance(filename,str) and pathlib.PurePosixPath(filename).name==filename,'router/: invalid selected package filename')
        relative='router/packages/'+filename;inventory.append('packages/'+filename)
        ipk=path(relative)
        need(entry.get('sha256')==sums.get(relative),'router/: IPK checksum does not match build metadata: '+package)
        # OpenWrt's IPKs are tar containers with a compressed control archive.
        # Read metadata in memory; never extract package contents to disk.
        with tarfile.open(ipk) as outer:
            controls=[member for member in outer.getmembers() if pathlib.PurePosixPath(member.name).name=='control.tar.gz' and member.isfile()]
            need(len(controls)==1,'router/: invalid IPK control archive: '+filename)
            with tarfile.open(fileobj=io.BytesIO(outer.extractfile(controls[0]).read())) as inner:
                control_files=[member for member in inner.getmembers() if pathlib.PurePosixPath(member.name).name=='control' and member.isfile()]
                need(len(control_files)==1,'router/: missing IPK control file: '+filename)
                fields={};key=None
                for line in inner.extractfile(control_files[0]).read().decode().splitlines():
                    if line.startswith((' ','\t')) and key:fields[key]+=' '+line.strip()
                    elif ': ' in line:key,value=line.split(': ',1);fields[key]=value
        need(fields.get('Package')==package and fields.get('Version')==entry.get('version'),'router/: IPK package/version differs from inventory: '+package)
        need(fields.get('Architecture') in ('all','noarch','x86_64'),'router/: incompatible IPK architecture: '+package)
        normalize=lambda text: [item.strip() for item in text.split(',') if item.strip()]
        need(normalize(fields.get('Depends',''))==normalize(entry.get('depends','')),'router/: IPK dependency metadata differs: '+package)
    need(len(inventory)==len(set(inventory)) and sorted(inventory)==sorted(ipks),'router/: package inventory and manifest differ')
    need(sorted(p.name for p in (root/'router/packages').glob('*.ipk'))==sorted(pathlib.PurePosixPath(name).name for name in inventory),'router/: unindexed or missing IPK files')
    versions=dict(base);versions.update({name:entry['version'] for name,entry in selected.items()})
    requirements=list(roots)
    for entry in selected.values():requirements.extend(normalize(entry.get('depends','')))
    for requirement in requirements:
        match=re.fullmatch(r'([a-zA-Z0-9+_.-]+)(?:\s*\(([<>=]+)\s*([^()]+)\))?',requirement.strip())
        need(match is not None,'router/: unsupported dependency: '+requirement)
        package,operator,wanted=match.groups()
        need(package in versions,'router/: missing dependency: '+requirement)
        need(not operator or subprocess.run(['dpkg','--compare-versions',versions[package],operator,wanted]).returncode==0,'router/: unsatisfied dependency version: '+requirement)
    print('[ OK ] complete offline core medium verified: '+str(root))
except (ValueError,KeyError,TypeError,OSError,tarfile.TarError,zipfile.BadZipFile,subprocess.SubprocessError) as e:
    print('[FAIL] '+str(e),file=sys.stderr);sys.exit(1)
PYVERIFY
