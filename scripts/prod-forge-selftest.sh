#!/bin/bash
# prod-forge-selftest.sh — `pol prod selftest`: frg-2's checks for the forge as a `pol prod`
# stack service. No swarm, no network, no deploy: prod.sh runs `plan` and `render` against a
# SCRATCH suite (symlinks to the real compose files, templates, polari-forge; its own
# .generated/ and its own vault dir), and the lib/prod-forge.sh functions run with fake
# docker / curl / vault. The only real docker call is `docker compose config` (render_stack).
#
#   prod-forge-selftest.sh [-v] [--help]      → prints N/N and exits non-zero on a miss
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$(cd "$HERE/../.." && pwd)"          # the real suite
VERBOSE=0
case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,9p' "$0"; exit 0 ;; esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad()  { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "NOT …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
nocolor() { sed 's/\x1b\[[0-9;]*m//g'; }

# ---------------------------------------------------------------- the scratch suite
S="$T/suite"; mkdir -p "$S/.generated" "$S/pol-proxy"
touch "$S/setup-polari-security.sh"   # log.sh's "is this the suite" probe
for f in docker-compose.lean.yml docker-compose.prod.yml pol-build polari-forge polari-rf-node pol-hub; do
    [ -e "$R/$f" ] && ln -s "$R/$f" "$S/$f"
done
# the credential files the full compose file names: STUBS (never the real ones — compose config inlines env files)
mkdir -p "$S/pol-keycloak" "$S/pol-mariadb" "$S/pol-file-store"
ln -s "$R/pol-keycloak/environments" "$S/pol-keycloak/environments"
printf 'KEYCLOAK_ADMIN=admin\nKEYCLOAK_ADMIN_PASSWORD=stub\n' > "$S/pol-keycloak/keycloak-admin.env"
printf 'MARIADB_ROOT_PASSWORD=stub\nKC_DB_PASSWORD=stub\nPSC_DB_PASSWORD=stub\n' > "$S/pol-mariadb/mariadb.env"
printf 'MINIO_ROOT_USER=stub\nMINIO_ROOT_PASSWORD=stub\n' > "$S/pol-file-store/minio.env"
printf 'MINIO_ACCESS_KEY=stub\nMINIO_SECRET_KEY=stub\n' > "$S/pol-file-store/client.env"
for t in "$R"/pol-proxy/*.template; do ln -s "$t" "$S/pol-proxy/"; done   # templates only: no CA → self-signed edge, nothing written into the real tree
answers() {  # answers KEY=VAL … → a fresh answers file (the arguments override the base set: load_answers keeps the FIRST line of a key)
    { printf '%s\n' "$@"; printf '%s\n' POL_PROD_ROUTE=swarm POL_PROD_DOMAIN=example.invalid POL_PROD_CERT_MODE=self-signed POL_PROD_AUTH=off \
        POL_PROD_DEBS=skip POL_PROD_DEMO=off POL_PROD_IMAGE_REPO=ghcr.io/dausume/ POL_PROD_IMAGE_TAG=polari-v2026.09.12-core; } > "$S/.generated/prod-answers.env"
}
export POL_VAULT_DIR="$T/vault"
prod() { ( cd "$S" && env -u POL_RF_NODE POL_SUITE_ROOT="$S" bash "$HERE/prod.sh" "$@" 2>&1 | nocolor ); }
PIN="$(awk '/^[[:space:]]*image:[[:space:]]*/{print $2; exit}' "$R/polari-forge/compose/forge.yml")"

# ---------------------------------------------------------------- names follow enabled components
answers POL_PROD_FORGE=on
out="$(prod plan)"
names="$(printf '%s\n' "$out" | sed -n 's/.*names: //p')"
has   "names: forge on → forge.<D>" "forge.example.invalid" "$names"
has   "names: forge on → apt.<D> (served BY the forge)" "apt.example.invalid" "$names"
has   "plan: the forge line (service, owner path)" "forge.example.invalid + apt.example.invalid (→ /api/packages/dausume/debian)" "$out"
has   "plan: no published port, ssh not exposed" "no published port (pol-proxy → forge:3000) · ssh NOT exposed (https only)" "$out"
has   "plan: the apply steps name the seed + the re-measure" "app.ini seeded into polari_forge_data first" "$out"
answers POL_PROD_FORGE=off
names="$(prod plan | sed -n 's/.*names: //p')"
hasnt "names: forge off → no forge.<D>" "forge.example.invalid" "$names"
hasnt "names: forge off (installers skipped) → no apt.<D>" "apt.example.invalid" "$names"
answers
out="$(prod plan)"
has   "an answers file written before the answer existed → forge off" "forge        off" "$out"
answers POL_PROD_FORGE=off POL_PROD_DEBS=release:polari-v2026.09.12
names="$(prod plan | sed -n 's/.*names: //p')"
has   "forge off + installers handed out → the old static apt.<D> rule stays" "apt.example.invalid" "$names"
hasnt "…and no forge.<D>" "forge.example.invalid" "$names"
answers POL_PROD_FORGE=on POL_PROD_DEBS=release:polari-v2026.09.12
names="$(prod plan | sed -n 's/.*names: //p')"
eq    "forge on + installers: apt.<D> appears ONCE (the forge's row, not both)" 1 "$(printf '%s' "$names" | tr ' ' '\n' | grep -cx 'apt.example.invalid')"
has   "LE SANs are the names (issue_cert: LE_SANS from names)" 'LE_SANS="$(names "$POL_PROD_DOMAIN"' "$(cat "$HERE/prod.sh")"

# ---------------------------------------------------------------- render (forge on, lean)
answers POL_PROD_FORGE=on
out1="$(prod render)"
has "render: 5 secrets generated into the vault [forge]" "forge: 5 secret(s) generated into the vault [forge]" "$out1"
has "render: app.ini for https://forge.<D>/" "app.ini rendered for https://forge.example.invalid/" "$out1"
G="$S/.generated"
san="$(openssl x509 -in "$G/certs/edge/fullchain.pem" -noout -ext subjectAltName 2>/dev/null)"
has "edge certificate SANs: forge.<D>" "DNS:forge.example.invalid" "$san"
has "edge certificate SANs: apt.<D>"   "DNS:apt.example.invalid" "$san"
# the stack
stk() { python3 - "$G/stack-lean.yml" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); f = (d.get("services") or {}).get("forge")
q = sys.argv[2]
if q == "present": print("yes" if f else "no")
elif q == "image": print(f["image"])
elif q == "ports": print("ports" in f)
elif q == "volume": print(f["volumes"][0]["source"], (d.get("volumes") or {}).get(f["volumes"][0]["source"], {}).get("name"))
elif q == "mem": print(f["deploy"]["resources"]["limits"]["memory"])
elif q == "restart": print(f["deploy"]["restart_policy"]["condition"])
elif q == "placement": print(f["deploy"]["placement"]["constraints"])
elif q == "env": print(f.get("environment"))
elif q == "health": print(f["healthcheck"]["test"])
PY
}
eq  "stack: the forge service is rendered" yes "$(stk present)"
eq  "stack: image = THE pin from polari-forge/compose/forge.yml" "$PIN" "$(stk image)"
eq  "stack: NO ports: (swarm ingress would publish on every interface)" False "$(stk ports)"
eq  "stack: the named volume polari_forge_data (fixed name)" "polari_forge_data polari_forge_data" "$(stk volume)"
eq  "stack: memory limit 512M" 536870912 "$(stk mem)"
eq  "stack: restart_policy on-failure" on-failure "$(stk restart)"
eq  "stack: placed on the manager like the other lean services" "['node.role == manager']" "$(stk placement)"
has "stack: env from the rendered container.env (USER_UID)" "'USER_UID': '" "$(stk env)"
hasnt "stack: no secret in the container environment" "SECRET_KEY" "$(stk env)"
has "stack: the healthcheck of the compose file" "http://localhost:3000/api/healthz" "$(stk health)"
has "env file: POLARI_FORGE_IMAGE = the pin (read at render time)" "POLARI_FORGE_IMAGE=$PIN" "$(cat "$G/.env.lean")"
# the proxy
NG="$(cat "$G/nginx.lean.conf")"
has "proxy: forge.<D> server block" "server_name forge.example.invalid;" "$NG"
has "proxy: forge → forge:3000 (overlay, lazy)" 'set $up_forge http://forge:3000;' "$NG"
has "proxy: X-Forwarded-Proto https for Forgejo" "proxy_set_header X-Forwarded-Proto https;" "$NG"
has "proxy: X-Real-IP" 'proxy_set_header X-Real-IP $remote_addr;' "$NG"
has "proxy: 1g bodies (a 300 MB deb/image upload)" "client_max_body_size 1g;" "$NG"
has "proxy: apt.<D> server block" "server_name apt.example.invalid;" "$NG"
has "proxy: apt.<D>/<x> → /api/packages/<owner>/debian/<x>" 'rewrite ^/(.*)$ /api/packages/dausume/debian/$1 break;' "$NG"
has "proxy: apt.<D> is read-only" "limit_except GET { deny all; }" "$NG"
hasnt "proxy: the static /srv/apt tree is gone with the forge on" "root /srv/apt;" "$NG"
hasnt "proxy: no marker left" '${' "$NG"
# app.ini for the production home
INI="$G/forge/app.ini"
ini() { awk -v s="$1" -v k="$2" '/^[ \t]*[;#]/{next} /^[ \t]*\[/{c=$0; gsub(/^[ \t]*\[|\][ \t]*$/,"",c); next} c==s{i=index($0,"="); if(!i)next; kk=substr($0,1,i-1); v=substr($0,i+1); gsub(/^[ \t]+|[ \t]+$/,"",kk); gsub(/^[ \t]+|[ \t]+$/,"",v); if(kk==k){print v; exit}}' "$INI"; }
eq "app.ini: ROOT_URL https://forge.<D>/" "https://forge.example.invalid/" "$(ini server ROOT_URL)"
eq "app.ini: DOMAIN forge.<D>" forge.example.invalid "$(ini server DOMAIN)"
eq "app.ini: SSH_DOMAIN forge.<D>" forge.example.invalid "$(ini server SSH_DOMAIN)"
eq "app.ini: PROTOCOL http behind the proxy" http "$(ini server PROTOCOL)"
eq "app.ini: ssh not exposed → DISABLE_SSH true" true "$(ini server DISABLE_SSH)"
eq "app.ini: registration off (the public posture)" true "$(ini service DISABLE_REGISTRATION)"
eq "app.ini: mode 600" 600 "$(stat -c %a "$INI")"
eq "forge.env: mode 600" 600 "$(stat -c %a "$G/forge/forge.env")"
case "$(git -C "$R" check-ignore -q .generated/forge/app.ini && echo ignored)" in ignored) ok ".generated/forge/ is gitignored by the suite's .generated/ rule" ;; *) bad ".generated/forge/ gitignored" ignored "tracked?" ;; esac
# the vault: the five keys, ONCE
source "$HERE/lib/vault.sh"
for k in SECRET_KEY INTERNAL_TOKEN JWT_SECRET LFS_JWT_SECRET ADMIN_PASSWORD; do
    v="$(vault_get forge "$k" || true)"
    eq "vault [forge] $k = the value in the rendered forge.env" "$(sed -n "s/^$k=//p" "$G/forge/forge.env")" "$v"
    hasnt "render never prints $k" "$v" "$out1"
done
eq "vault: SECRET_KEY reached app.ini" "$(vault_get forge SECRET_KEY)" "$(ini security SECRET_KEY)"
vsha="$(sha256sum "$POL_VAULT_DIR/vault.enc" | cut -d' ' -f1)"
out2="$(prod render)"
has "a second render: the secrets kept (no vault write)" "forge: secrets kept (vault [forge])" "$out2"
eq  "…the vault file is byte-identical (zero puts)" "$vsha" "$(sha256sum "$POL_VAULT_DIR/vault.enc" | cut -d' ' -f1)"
# the vault wins over a drifted forge.env
sk="$(vault_get forge SECRET_KEY)"; sed -i 's/^SECRET_KEY=.*/SECRET_KEY=drifted/' "$G/forge/forge.env"
prod render >/dev/null
eq "the vault wins over a drifted forge.env (re-assembled on render)" "$sk" "$(ini security SECRET_KEY)"
# the owner knob
answers POL_PROD_FORGE=on POL_PROD_FORGE_OWNER=polari
prod render >/dev/null
has "POL_PROD_FORGE_OWNER: the apt rewrite follows it" 'rewrite ^/(.*)$ /api/packages/polari/debian/$1 break;' "$(cat "$G/nginx.lean.conf")"

# ---------------------------------------------------------------- render (forge on, FULL profile)
answers POL_PROD_FORGE=on POL_PROD_AUTH=keycloak POL_PROD_PROFILE=full
prod render >/dev/null || true
if [ -s "$G/stack-prod.yml" ]; then
    eq "full profile: the forge service in stack-prod.yml" yes "$(python3 -c 'import sys,yaml; print("yes" if "forge" in yaml.safe_load(open(sys.argv[1]))["services"] else "no")' "$G/stack-prod.yml")"
    has "full profile: nginx.prod.conf has the forge block" "server_name forge.example.invalid;" "$(cat "$G/nginx.prod.conf")"
    hasnt "full profile: …and no static /srv/apt" "root /srv/apt;" "$(cat "$G/nginx.prod.conf")"
    has "full profile: POLARI_FORGE_IMAGE in .env.prod" "POLARI_FORGE_IMAGE=$PIN" "$(cat "$G/.env.prod")"
else
    bad "full profile render" "stack-prod.yml" "$(cat "$G/compose-config.err" 2>/dev/null | tail -2)"
fi

# ---------------------------------------------------------------- render (forge off)
answers POL_PROD_FORGE=off
prod render >/dev/null
eq    "forge off: no forge service in the stack" no "$(stk present)"
NG="$(cat "$G/nginx.lean.conf")"
hasnt "forge off: no forge server block" "server_name forge.example.invalid;" "$NG"
has   "forge off: the static apt tree as before" "root /srv/apt;" "$NG"
hasnt "forge off: no marker left" '${' "$NG"
hasnt "forge off: no POLARI_FORGE_IMAGE" "POLARI_FORGE_IMAGE" "$(cat "$G/.env.lean")"

# ---------------------------------------------------------------- lib/prod-forge.sh with fakes
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/docker" <<'SH'
#!/bin/bash
S="$FAKE_STATE"; printf '%s\n' "$*" >> "$S/docker.log"
case "$1" in
  image) exit 0 ;;
  pull)  exit 0 ;;
  run)   case "$*" in
           *"sha256sum /data/gitea/conf/app.ini"*) [ -n "${FAKE_SHA:-}" ] && echo "$FAKE_SHA  /data/gitea/conf/app.ini"; exit 0 ;;
           *"cat > /data/gitea/conf/app.ini"*)     cat > "$S/seeded.ini"; exit 0 ;;
         esac ;;
  ps)    case "$*" in *"com.docker.swarm.service.name=polari-lean_forge"*) echo fakecid0123456789 ;; esac; exit 0 ;;
  service) case "$*" in *Endpoint.Ports*) printf '%s' "${FAKE_SVC_PORTS:-}" ;; esac; exit 0 ;;
  inspect) case "$*" in *swarm.service.name*) echo polari-lean_forge ;; *HostConfig.Memory*) echo 536870912 ;; esac; exit 0 ;;
esac
exit 0
SH
chmod +x "$T/bin/docker"
export FAKE_STATE="$T/state"
lib() {  # lib '<bash>' — prod-forge.sh sourced with the answers + stubs (fake vault: a file, counted puts)
    PATH="$T/bin:$PATH" bash -c '
        set -u
        SUITE="'"$S"'"; GEN="$SUITE/.generated"; SCRIPT_DIR="'"$HERE"'"
        log_info(){ echo "[INFO] $*"; }; log_success(){ echo "[ OK ] $*"; }; log_warn(){ echo "[WARN] $*"; }; die(){ echo "[FAIL] $*"; exit 1; }
        stack_name(){ echo polari-lean; }; role(){ echo lean; }
        VF="'"$T"'/fakevault"; touch "$VF"
        vault_get(){ grep -s "^$1|$2=" "$VF" | tail -n1 | cut -d= -f2-; grep -qs "^$1|$2=" "$VF"; }
        vault_put(){ echo "put $1 $2" >> "$VF.log"; grep -v "^$1|$2=" "$VF" > "$VF.n" || true; echo "$1|$2=$3" >> "$VF.n"; mv "$VF.n" "$VF"; }
        POL_PROD_DOMAIN=example.invalid; POL_PROD_FORGE=on; POL_PROD_FORGE_OWNER=dausume
        source "$SCRIPT_DIR/lib/prod-forge.sh"
        '"$1"
}
# the vault receives the five keys ONCE (fake vault, counted)
rm -rf "$G/forge"; : > "$T/env.test"
out="$(lib 'write_configs_forge "'"$T"'/env.test"')"
eq  "fake vault: first render → exactly 5 puts" 5 "$(grep -c '^put forge ' "$T/fakevault.log")"
for k in SECRET_KEY INTERNAL_TOKEN JWT_SECRET LFS_JWT_SECRET ADMIN_PASSWORD; do has "fake vault: put forge $k" "put forge $k" "$(cat "$T/fakevault.log")"; done
out="$(lib 'write_configs_forge "'"$T"'/env.test"')"
eq  "fake vault: second render → still 5 puts (none added)" 5 "$(grep -c '^put forge ' "$T/fakevault.log")"
has "fake vault: second render says kept" "secrets kept" "$out"
# a partial vault (one key lost) → only that one is put again
grep -v '^forge|INTERNAL_TOKEN=' "$T/fakevault" > "$T/fv" && mv "$T/fv" "$T/fakevault"
lib 'write_configs_forge "'"$T"'/env.test"' >/dev/null
eq  "fake vault: a lost key is put back alone (6th put = INTERNAL_TOKEN)" "put forge INTERNAL_TOKEN" "$(tail -n1 "$T/fakevault.log")"
# the volume seed: copied over stdin, idempotent
: > "$T/state/docker.log"
out="$(lib 'forge_seed_volume; echo "seeded=$FORGE_SEEDED"')"
has "seed: an absent/different app.ini is copied into polari_forge_data" "seeded=1" "$out"
eq  "seed: the copied bytes are the rendered app.ini" "$(sha256sum "$G/forge/app.ini" | cut -d' ' -f1)" "$(sha256sum "$T/state/seeded.ini" | cut -d' ' -f1)"
has "seed: a one-shot container on the volume" "run --rm -i -v polari_forge_data:/data --entrypoint sh $PIN" "$(cat "$T/state/docker.log")"
has "seed: owned by USER_UID, mode 600" 'chown "$1:$2" /data/gitea /data/gitea/conf /data/gitea/conf/app.ini; chmod 600' "$(cat "$T/state/docker.log")"
hasnt "seed: the secrets never ride docker's argv" "$(sed -n 's/^SECRET_KEY=//p' "$G/forge/forge.env")" "$(cat "$T/state/docker.log")"
out="$(FAKE_SHA="$(sha256sum "$G/forge/app.ini" | cut -d' ' -f1)" lib 'forge_seed_volume; echo "seeded=$FORGE_SEEDED"')"
has "seed: unchanged file → no copy" "no copy" "$out"
has "seed: …seeded=0" "seeded=0" "$out"
# deploy_stack calls the seed BEFORE docker stack deploy
p="$(cat "$HERE/prod.sh")"
ls_="$(grep -n 'forge_seed_volume; fi' "$HERE/prod.sh" | head -1 | cut -d: -f1)"; ld_="$(grep -n 'docker stack deploy "${wra\[@\]}"' "$HERE/prod.sh" | head -1 | cut -d: -f1)"
eq "deploy_stack: forge_seed_volume runs before docker stack deploy" yes "$([ -n "$ls_" ] && [ -n "$ld_" ] && [ "$ls_" -lt "$ld_" ] && echo yes || echo no)"
has "render_stack: the forge profile (both keys)" 'forge_on && { pargs="$pargs --profile forge"; extra+=(--with-profile forge); }' "$p"
# verify: the two checks, an empty registry tolerated
cat > "$T/verify.sh" <<'SH'
pass=0; fail=0; warn=0
ok(){ pass=$((pass+1)); echo "OK $1"; }; bad(){ fail=$((fail+1)); echo "BAD $1"; }; log_warn(){ warn=$((warn+1)); echo "WARN $*"; }
curl() { local u="${!#}" w=0; for a in "$@"; do [ "$a" = '-w' ] && w=1; done
    case "$u" in
      */api/v1/version) c="$FAKE_V" ;;
      */dists/stable/Release) c="$FAKE_R" ;;
    esac
    case "$*" in *"-o /dev/null"*) printf '%s' "$c" ;; *) printf '{"version":"11.0.16+gitea-1.22.0"}'; [ "$w" = 1 ] && printf '\n%s' "$c" ;; esac; }
forge_verify_checks; echo "pass=$pass fail=$fail warn=$warn"
SH
out="$(FAKE_V=200 FAKE_R=404 lib 'source '"$T"'/verify.sh')"
has "verify: forge.<D>/api/v1/version 200 → pass" "OK forge: https://forge.example.invalid/api/v1/version 200 (Forgejo 11.0.16+gitea-1.22.0)" "$out"
has "verify: Release 404 → 'empty — publish first'" "empty — publish first" "$out"
has "verify: …and NOT a failure" "pass=1 fail=0 warn=1" "$out"
out="$(FAKE_V=200 FAKE_R=200 lib 'source '"$T"'/verify.sh')"
has "verify: Release 200 → both pass" "pass=2 fail=0 warn=0" "$out"
out="$(FAKE_V=502 FAKE_R=502 lib 'source '"$T"'/verify.sh')"
has "verify: a 502 is a failure (both)" "pass=0 fail=2" "$out"
out="$(lib 'POL_PROD_FORGE=off; source '"$T"'/verify.sh')"
has "verify: forge off → no forge checks" "pass=0 fail=0 warn=0" "$out"
has "do_verify runs the forge checks" "forge_verify_checks" "$p"
# the re-measure gate
out="$(lib 'forge_verdict 900 "{\"rss_mib\":101.5,\"peak_mib\":455.0}"')"
has "re-measure: 900 MiB available < 2×512 → WARN" "re-measure: WARN — 900 MiB available (free -m) < 2 × the forge's 512 MiB limit (1024 MiB); forge rss 101.5 MiB, peak 455.0 MiB" "$out"
out="$(lib 'forge_verdict 1500 "{\"rss_mib\":94.0,\"peak_mib\":null}"')"
has "re-measure: 1500 MiB → OK (peak unknown shown as ?)" "re-measure: OK — 1500 MiB available (free -m) ≥ 2 × the forge's 512 MiB limit; forge rss 94.0 MiB, peak ? MiB" "$out"
has "apply: forge_after_deploy after deploy_stack" "deploy_stack
    forge_after_deploy" "$p"
has "status: the forge row" "forge_status_rows" "$p"

# ---------------------------------------------------------------- pol forge against the swarm home
answers POL_PROD_FORGE=on
FORGE_CLI="$HERE/forge.sh"
pf() { PATH="$T/bin:$PATH" POL_SUITE_ROOT="$S" bash "$FORGE_CLI" "$@" 2>&1 | nocolor; }
out="$(pf posture || true)"
has "pol forge posture (swarm): ports — none published (behind pol-proxy)" "none published (behind pol-proxy) — service polari-lean_forge" "$out"
hasnt "pol forge posture (swarm): no loopback row" "loopback only" "$out"
out="$(FAKE_SVC_PORTS='3000->3000 ' pf posture || true)"
has "pol forge posture (swarm): a published port is a WARN" "published on every interface (swarm ingress)" "$out"
out="$(pf up || true)"
has "pol forge up refuses on production" "this forge is a pol prod service — pol prod apply / pol prod down" "$out"
out="$(pf down || true)"
has "pol forge down refuses on production" "this forge is a pol prod service" "$out"
out="$(pf apt-source)"
has "pol forge apt-source on production: the apt.<D> line" "deb [signed-by=/etc/apt/keyrings/polari-forge.asc] https://apt.example.invalid stable main" "$out"

# ---------------------------------------------------------------- answers, profiles, guide
P="$HERE/../prod-profiles"
for pr in distribution-server public-server; do eq "profile $pr answers POL_PROD_FORGE=on" on "$(sed -n 's/^POL_PROD_FORGE=//p' "$P/$pr.env")"; done
for pr in local-instance demo-server; do eq "profile $pr answers POL_PROD_FORGE=off" off "$(sed -n 's/^POL_PROD_FORGE=//p' "$P/$pr.env")"; done
eq "save_answers / profile_save / facts / guide-fresh all carry FORGE + FORGE_OWNER" 4 "$(grep -c 'APP_PERMISSIONS FORGE FORGE_OWNER; do' "$HERE/prod.sh")"
q='Host the forge (git mirrors, releases, the apt repository people install from) on this server?'
has "guide: the forge question" "$q" "$p"
lg="$(grep -n 'POL_PROD_AUTH=$(tui_menu "User logins"' "$HERE/prod.sh" | cut -d: -f1)"; fq="$(grep -nF "$q" "$HERE/prod.sh" | cut -d: -f1)"
eq "guide: the forge question comes after the logins step" yes "$([ -n "$lg" ] && [ -n "$fq" ] && [ "$fq" -gt "$lg" ] && echo yes || echo no)"

echo "pol prod (forge) selftest: $PASS/$((PASS+FAIL))"
[ "$FAIL" = 0 ]
