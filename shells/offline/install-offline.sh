#!/bin/bash
# A complete core medium is mandatory even when this host already has some
# dependencies. Never fall back to system apt sources or Docker pulls.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POOL="$(cd "$HERE/.." && pwd)"
CORE_INSTALL=0; SKIP_IMAGES=0; SKIP_APT=0
while [ $# -gt 0 ]; do case "$1" in
    --core-install) CORE_INSTALL=1; shift ;;
    --skip-images) SKIP_IMAGES=1; shift ;;
    --skip-apt) SKIP_APT=1; shift ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
esac; done
ok(){ printf '[ OK ] %s\n' "$*"; }
refuse(){ printf '[REFUSED] offline: %s\n' "$*" >&2; exit 2; }
[ "$(id -u)" = 0 ] || refuse "run as root: sudo bash $0"
bash "$HERE/verify-offline.sh" "$POOL" || refuse "medium verification failed; host configuration unchanged"

# Only temporary planning files are written until completeness, compatibility,
# installed versions and the local apt transaction have all been checked.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
python3 - "$POOL" > "$WORK/plan" <<'PY'
import json,pathlib,re,subprocess,sys
root=pathlib.Path(sys.argv[1]);m=json.loads((root/'manifest.json').read_text())
def satisfies(v,op,wanted):
    return not op or subprocess.run(['dpkg','--compare-versions',v,op,wanted]).returncode==0
for dep in m['requiredPackages']:
    alternatives=[re.fullmatch(r'([^ (]+)(?: \(([^ ]+) ([^)]+)\))?',part.strip()).groups() for part in dep.split('|')]
    satisfied=False
    for pkg,op,version in alternatives:
        installed=subprocess.run(['dpkg-query','-W','-f=${db:Status-Status}\t${Version}',pkg],capture_output=True,text=True)
        state,_,current=installed.stdout.partition('\t')
        if installed.returncode==0 and state=='installed' and satisfies(current,op,version): satisfied=True;break
    if satisfied: continue
    for pkg,op,version in alternatives:
        choices=[]
        for stanza in (root/'apt/Packages').read_text().split('\n\n'):
            f=dict(line.split(': ',1) for line in stanza.splitlines() if ': ' in line and not line.startswith(' '))
            if f.get('Package')==pkg.split(':')[0] and satisfies(f['Version'],op,version): choices.append(f['Version'])
        if not choices: continue
        best=choices[0]
        for candidate in choices[1:]:
            if subprocess.run(['dpkg','--compare-versions',candidate,'gt',best]).returncode==0: best=candidate
        print(pkg+'='+best);break

PY
mapfile -t NEED < "$WORK/plan"
if [ "$SKIP_APT" = 1 ] && [ "${#NEED[@]}" -gt 0 ]; then
    refuse "--skip-apt requires satisfied installed versions; missing: ${NEED[*]} (section apt/)"
fi
DEB=$(python3 - "$POOL" <<'PY'
import json,sys
p=sys.argv[1];print(p+'/debs/'+json.load(open(p+'/manifest.json'))['debs']['polari-complete-offline'])
PY
)
DEB_VERSION=$(dpkg-deb -f "$DEB" Version)
INSTALLED=$(dpkg-query -W -f='${db:Status-Status} ${Version}' polari-complete-offline 2>/dev/null || true)
INSTALL_DEB=1
[ "$INSTALLED" != "installed $DEB_VERSION" ] || INSTALL_DEB=0

# --skip-images means VERIFY installed content IDs, not blindly accept tags.
# Without this flag an incorrect existing tag is replaced from the archive.
python3 - "$POOL" "$SKIP_IMAGES" > "$WORK/images" <<'PY'
import json,subprocess,sys
root,skip=sys.argv[1:];entries=json.load(open(root+'/images/images.json'))
for e in entries:
    ref=e['name']+':'+e['tag']
    try:r=subprocess.run(['docker','image','inspect','--format','{{.Id}}',ref],capture_output=True,text=True)
    except FileNotFoundError:r=None
    if r is not None and r.returncode==0 and r.stdout.strip()==e['id']: continue
    if skip=='1':
        print('[REFUSED] offline: missing/incorrect installed image '+ref+' (--skip-images)',file=sys.stderr);sys.exit(2)
    print(ref+'\t'+e['file']+'\t'+e['id'])
PY

# Isolate apt configuration, sources, indexes and caches. Download-only
# staging uses only the verified flat file repository, then --no-download
# installation cannot fetch a missing package. System apt hooks are excluded.
mkdir -p "$WORK/lists/partial" "$WORK/archives/partial" "$WORK/sourceparts" "$WORK/log" "$WORK/cache"
printf 'deb [trusted=yes] file:%s/apt ./\n' "$POOL" > "$WORK/sources.list"
chmod 755 "$WORK" "$WORK/lists" "$WORK/lists/partial" "$WORK/archives" "$WORK/archives/partial"
cat > "$WORK/apt.conf" <<'APTCONF'
Dir::Etc::main "/dev/null";
Dir::Etc::parts "/dev/null";
APTCONF
APT_OPTS=(-o "Dir::Etc::SourceList=$WORK/sources.list" -o "Dir::Etc::SourceParts=$WORK/sourceparts"
    -o "Dir::State::lists=$WORK/lists" -o "Dir::Cache::archives=$WORK/archives"
    -o "Dir::Log=$WORK/log" -o "Dir::Cache=$WORK/cache"
    -o "Dir::State::extended_states=$WORK/extended_states"
    -o Acquire::Retries=0 -o APT::Get::List-Cleanup=0)
TARGETS=("${NEED[@]}")
[ "$INSTALL_DEB" = 0 ] || TARGETS+=("$DEB")
if [ "${#TARGETS[@]}" -gt 0 ]; then
    APT_CONFIG="$WORK/apt.conf" apt-get "${APT_OPTS[@]}" update -qq || refuse "local apt/ index could not be read"
    APT_CONFIG="$WORK/apt.conf" apt-get "${APT_OPTS[@]}" --simulate --no-download --no-remove install --no-install-recommends "${TARGETS[@]}" \
        || refuse "apt/ does not satisfy platform dependencies; host configuration unchanged"
    APT_CONFIG="$WORK/apt.conf" apt-get "${APT_OPTS[@]}" --download-only --no-remove install -y --no-install-recommends "${TARGETS[@]}" \
        || refuse "apt/: local package staging failed; host configuration unchanged"
fi

mkdir -p /etc/polari
printf 'offline\n' > /etc/polari/install-mode
printf '%s\n' "$POOL" > /etc/polari/offline-source
if [ "${#TARGETS[@]}" -gt 0 ]; then
    APT_CONFIG="$WORK/apt.conf" DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" --no-download --no-remove install -y --no-install-recommends "${TARGETS[@]}" \
        || refuse "installation from local apt/ failed; see apt output"
fi
systemctl enable --now docker || refuse "Docker could not start"
while IFS=$'\t' read -r ref file expected; do
    [ -n "$ref" ] || continue
    docker load -q -i "$POOL/images/$file" || refuse "images/: load failed for $file"
    actual=$(docker image inspect --format '{{.Id}}' "$ref") || refuse "images/: loaded archive did not provide $ref"
    [ "$actual" = "$expected" ] || refuse "images/: loaded $ref has incorrect content ID"
    ok "loaded verified image $ref"
done < "$WORK/images"
# Check all identities once more; an archive containing multiple tags must not
# silently replace an earlier required image with different content.
python3 - "$POOL" <<'PY'
import json,subprocess,sys
for e in json.load(open(sys.argv[1]+'/images/images.json')):
    ref=e['name']+':'+e['tag'];actual=subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',ref],text=True).strip()
    if actual!=e['id']:sys.exit('offline images/: final image ID mismatch: '+ref)
PY
printf '%s\n' "$POOL" > /etc/polari/offline-source
if [ "$CORE_INSTALL" = 1 ]; then
    isle core-install
else
    echo "Next: open Isle App Store → Create my own isle. Router artifacts and dependencies are on this medium."
fi
ok "offline platform staged; every image content ID verified"
