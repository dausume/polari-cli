#!/usr/bin/env python3
"""Isolated complete-medium and installer tests; no services or host writes."""
import hashlib,io,json,os,pathlib,shutil,subprocess,tarfile,tempfile,unittest
SOURCE=pathlib.Path(__file__).resolve().parent
class OfflineCore(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.work=pathlib.Path(self.tmp.name);self.pool=self.work/'medium';self.pool.mkdir()
        self.host=self.work/'host';self.bin=self.work/'bin';self.bin.mkdir()
        self.log=self.work/'commands';self.state=self.work/'state.json'
        self.config=b'{"architecture":"amd64","os":"linux"}'
        self.iid='sha256:'+hashlib.sha256(self.config).hexdigest()
        self.state.write_text(json.dumps({'images':{},'installed':{}}))
        for section in ('debs','apt','images','router','modules','engines','hardware','scripts'):(self.pool/section).mkdir()
        for name in ('install-offline.sh','verify-offline.sh'):
            text=(SOURCE/name).read_text().replace('/etc/polari',str(self.host))
            (self.pool/'scripts'/name).write_text(text)
        (self.pool/'ISLE_OFFLINE_BUNDLE').write_text('fixture')
        (self.pool/'debs/platform.deb').write_bytes(b'fixture platform')
        content=b'fixture apt package';digest=hashlib.sha256(content).hexdigest()
        (self.pool/'apt/tool_2_all.deb').write_bytes(content)
        (self.pool/'apt/Packages').write_text('Package: tool\nVersion: 2\nArchitecture: all\nFilename: ./tool_2_all.deb\nSHA256: '+digest+'\n\n')
        (self.pool/'router/router.qcow2').write_bytes(b'fixture router')
        (self.pool/'router/packages').mkdir()
        self.router_metadata={'openwrt':'23.05.3','baseSha256':'a'*64,'imageSha256':hashlib.sha256((self.pool/'router/router.qcow2').read_bytes()).hexdigest(),
            'roots':['avahi-dbus-daemon','avahi-utils','ip-full','tcpdump'],
            'basePackages':{'libc':'1','avahi-utils':'2','ip-full':'2','tcpdump':'2'},'packages':{}}
        self.router_ipk()
        self.image_archive()
        (self.pool/'images/images.json').write_text(json.dumps([{'name':'test/core','tag':'release','file':'core.tar','id':self.iid}]))
        osinfo=dict(line.split('=',1) for line in pathlib.Path('/etc/os-release').read_text().splitlines() if '=' in line)
        self.manifest={'polari':'test','flavor':'offline','target':osinfo['ID'].strip('"')+'-'+osinfo['VERSION_ID'].strip('"'),'architecture':'amd64','sections':{s:{'present':True} for s in ('debs','apt','images','router','scripts')},'requiredPackages':['tool (>= 2)'],'requiredImages':['test/core:release'],'debs':{'polari-complete-offline':'platform.deb'},'router':{'file':'router.qcow2','packages':['packages/a.ipk'],'metadata':'build.json'}}
        stub='''#!/usr/bin/python3
import json,os,pathlib,subprocess,sys
name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:]
with open(os.environ['TEST_LOG'],'a') as f:f.write(json.dumps([name]+a)+'\\n')
p=pathlib.Path(os.environ['TEST_STATE']);s=json.loads(p.read_text())
if name=='id':print('0')
elif name=='dpkg':
 if a==['--print-architecture']:print('amd64')
 else:sys.exit(subprocess.run(['/usr/bin/dpkg']+a).returncode)
elif name=='dpkg-deb':
 field=a[-1];print({'Package':'polari-complete-offline','Architecture':'amd64','Version':'1'}[field])
elif name=='dpkg-query':
 value=s['installed'].get(a[-1])
 if not value:sys.exit(1)
 print(value,end='')
elif name=='docker':
 if a[:2]==['image','inspect']:
  image=s['images'].get(a[-1])
  if not image:sys.exit(1)
  print(image)
 elif a[0]=='load':s['images']['test/core:release']=os.environ['TEST_IID'];p.write_text(json.dumps(s))
 else:sys.exit(2)
elif name=='apt-get':
 if '--simulate' in a and os.environ.get('TEST_APT_FAIL'):sys.exit(100)
elif name=='systemctl':pass
else:sys.exit(3)
'''
        for name in ('id','dpkg','dpkg-deb','dpkg-query','docker','apt-get','systemctl'):
            f=self.bin/name;f.write_text(stub);f.chmod(0o755)
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],TEST_LOG=str(self.log),TEST_STATE=str(self.state),TEST_IID=self.iid)
    def router_ipk(self,depends='libc (>= 1)',version='2'):
        package='avahi-dbus-daemon'
        control=('Package: '+package+'\nVersion: '+version+'\nArchitecture: x86_64\nDepends: '+depends+'\n').encode()
        content=io.BytesIO()
        with tarfile.open(fileobj=content,mode='w:gz') as inner:
            entry=tarfile.TarInfo('./control');entry.size=len(control);inner.addfile(entry,io.BytesIO(control))
        payload=content.getvalue()
        with tarfile.open(self.pool/'router/packages/a.ipk',mode='w:gz') as outer:
            entry=tarfile.TarInfo('./control.tar.gz');entry.size=len(payload);outer.addfile(entry,io.BytesIO(payload))
        self.router_metadata['packages'][package]={'file':'a.ipk','version':version,'depends':depends,'sha256':hashlib.sha256((self.pool/'router/packages/a.ipk').read_bytes()).hexdigest()}
    def image_archive(self,config=None):
        config=self.config if config is None else config
        with tarfile.open(self.pool/'images/core.tar','w') as tar:
            for name,data in [('config.json',config),('manifest.json',json.dumps([{'Config':'config.json','RepoTags':['test/core:release'],'Layers':[]}]).encode())]:
                info=tarfile.TarInfo(name);info.size=len(data);tar.addfile(info,io.BytesIO(data))
    def seal(self):
        (self.pool/'router/build.json').write_text(json.dumps(self.router_metadata))
        (self.pool/'manifest.json').write_text(json.dumps(self.manifest))
        (self.pool/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  ./'+str(p.relative_to(self.pool))+'\n' for p in sorted(self.pool.rglob('*')) if p.is_file() and p.name!='SHA256SUMS'))
    def run_install(self,*args,**env):
        self.seal();return subprocess.run(['bash',str(self.pool/'scripts/install-offline.sh'),*args],env=dict(self.env,**env),capture_output=True,text=True)
    def commands(self):return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
    def assert_unmodified(self):
        self.assertFalse(self.host.exists());self.assertFalse(any(c[0] in ('systemctl','apt-get') or c[:2]==['docker','load'] for c in self.commands()))
    def test_missing_router_refused_before_mutation(self):
        (self.pool/'router/router.qcow2').unlink();r=self.run_install();self.assertNotEqual(r.returncode,0,r.stdout);self.assert_unmodified()
    def test_wrong_os_and_arch_refused(self):
        for key,value in [('target','ubuntu-0'),('architecture','arm64')]:
            with self.subTest(key=key):
                old=self.manifest[key];self.manifest[key]=value;r=self.run_install();self.assertNotEqual(r.returncode,0);self.assert_unmodified();self.manifest[key]=old
    def test_wrong_archive_identity_refused(self):
        self.image_archive(b'wrong config');r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('image ID mismatch',r.stderr);self.assert_unmodified()
    def test_empty_required_section_refused(self):
        for name in ('apt','images','router','debs'):
            with self.subTest(section=name):
                self.manifest['sections'][name]['present']=False;r=self.run_install();self.assertNotEqual(r.returncode,0);self.assert_unmodified();self.manifest['sections'][name]['present']=True
    def test_skip_images_rejects_wrong_tag_id(self):
        self.state.write_text(json.dumps({'images':{'test/core:release':'sha256:'+'0'*64},'installed':{}}))
        r=self.run_install('--skip-images');self.assertNotEqual(r.returncode,0);self.assert_unmodified()
    def test_matching_ids_reused_and_satisfied_versions_not_requested(self):
        self.state.write_text(json.dumps({'images':{'test/core:release':self.iid},'installed':{'tool':'installed\t3','polari-complete-offline':'installed 1'}}))
        r=self.run_install('--skip-images','--skip-apt');self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertFalse(any(c[0]=='apt-get' or c[:2]==['docker','load'] for c in self.commands()))
    def test_config_files_and_old_versions_are_installed_locally(self):
        for installed in ('config-files\t3','installed\t1'):
            with self.subTest(installed=installed):
                self.state.write_text(json.dumps({'images':{},'installed':{'tool':installed}}));r=self.run_install();self.assertEqual(r.returncode,0,r.stderr+r.stdout)
                installs=[c for c in self.commands() if c[0]=='apt-get' and 'install' in c and '--download-only' not in c]
                self.assertTrue(installs);self.assertTrue(all('tool=2' in c and '--no-download' in c and '--no-remove' in c for c in installs))
    def test_apt_simulation_failure_before_mode_or_image_load(self):
        r=self.run_install(TEST_APT_FAIL='1');self.assertNotEqual(r.returncode,0);self.assertFalse(self.host.exists());self.assertFalse(any(c[:2]==['docker','load'] for c in self.commands()))
    def test_newer_platform_refused_without_downgrade(self):
        self.state.write_text(json.dumps({'images':{'test/core:release':self.iid},'installed':{'tool':'installed\t3','polari-complete-offline':'installed 2'}}))
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('no downgrade',r.stderr);self.assert_unmodified()
    def test_installed_alternative_preserved(self):
        self.manifest['requiredPackages']=['tool (>= 2) | compatible-tool (>= 3)']
        self.state.write_text(json.dumps({'images':{'test/core:release':self.iid},'installed':{'compatible-tool':'installed\t4','polari-complete-offline':'installed 1'}}))
        r=self.run_install('--skip-images','--skip-apt');self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        self.assertFalse(any(c[0]=='apt-get' for c in self.commands()))
    def test_traversal_rejected(self):
        outside=self.work/'outside.qcow2';outside.write_bytes(b'outside')
        self.manifest['router']['file']='../../outside.qcow2'
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('unsafe medium path',r.stderr);self.assert_unmodified()
    def test_router_image_must_match_build_metadata_even_if_resealed(self):
        (self.pool/'router/router.qcow2').write_bytes(b'wrong router content')
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('pristine build metadata',r.stderr);self.assert_unmodified()
    def test_router_missing_dependency_refused_before_mutation(self):
        self.router_ipk(depends='libc, missing-library (>= 2)')
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('missing dependency',r.stderr);self.assert_unmodified()
    def test_router_dependency_version_checked(self):
        self.router_ipk(depends='libc (>= 2)')
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('unsatisfied dependency version',r.stderr);self.assert_unmodified()
    def test_router_ipk_control_must_match_selected_metadata(self):
        self.router_metadata['packages']['avahi-dbus-daemon']['version']='99'
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('package/version differs',r.stderr);self.assert_unmodified()
    def test_router_missing_root_refused(self):
        del self.router_metadata['basePackages']['tcpdump']
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('missing dependency',r.stderr);self.assert_unmodified()
    def test_router_metadata_required(self):
        del self.manifest['router']['metadata']
        r=self.run_install();self.assertNotEqual(r.returncode,0);self.assertIn('build metadata',r.stderr);self.assert_unmodified()
    def test_checksum_omission_rejected(self):
        self.seal();p=self.pool/'SHA256SUMS';p.write_text('\n'.join(line for line in p.read_text().splitlines() if 'router.qcow2' not in line)+'\n')
        r=subprocess.run(['bash',str(self.pool/'scripts/verify-offline.sh'),str(self.pool)],env=self.env,capture_output=True,text=True);self.assertNotEqual(r.returncode,0);self.assertIn('omitted',r.stderr)
if __name__=='__main__':unittest.main()
