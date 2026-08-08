#!/usr/bin/env bash
# isle-dev-setup.sh — one-command developer onboarding for the
# ISLE-ORIENTED deployment process (handoff §25.3/§28). Wires a
# fresh machine to build polari here and deploy it THROUGH the isle:
# trust the isle CA (browser + docker registry), reach the isle
# host, and expose the dev-loop verbs. Idempotent, consent-first,
# narrates every step; skips anything already done.
#
#   isle-dev-setup.sh [--isle-host <ip>] [--registry-host <ip>]
#                     [--registry-port 5000] [--ca <root.crt>]
#                     [--yes]
#
# Defaults target this repo's staging isle (isle-core @ 192.168.0.24,
# registry on the home-LAN address). Override for another isle.
set -u
SUITE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ISLE_HOST="${ISLE_HOST:-192.168.0.24}"
REGISTRY_HOST="${REGISTRY_HOST:-192.168.0.24}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
CA="${ISLE_CA:-$SUITE_ROOT/polari-rf-node/ca/root_ca.crt}"
ASSUME_YES=0
while [ $# -gt 0 ]; do case "$1" in
    --isle-host) ISLE_HOST="$2"; shift 2 ;;
    --registry-host) REGISTRY_HOST="$2"; shift 2 ;;
    --registry-port) REGISTRY_PORT="$2"; shift 2 ;;
    --ca) CA="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
esac; done

G="\033[0;32m"; Y="\033[1;33m"; R="\033[0;31m"; C="\033[0;36m"; N="\033[0m"
ok(){ echo -e "${G}[ OK ]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*"; }
skip(){ echo -e "${C}[skip]${N} $*"; }
step(){ echo; echo -e "${Y}==> $*${N}"; }
die(){ echo -e "${R}[FAIL]${N} $*"; exit 1; }
confirm(){ [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "  $1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }

REGISTRY="$REGISTRY_HOST:$REGISTRY_PORT"
echo "Isle developer setup"
echo "  isle host:  $ISLE_HOST"
echo "  registry:   $REGISTRY"
echo "  isle CA:    $CA"
[ -f "$CA" ] || die "isle CA not found at $CA (--ca <path>)"
FP=$(openssl x509 -in "$CA" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
echo "  CA SHA-256: $FP"

# ---- 1. prerequisites ------------------------------------------------
step "1/6 prerequisites"
MISSING=""
for c in docker openssl ssh; do command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"; done
[ -n "$MISSING" ] && die "install first:$MISSING"
command -v node >/dev/null 2>&1 || warn "node not found — the pol CLI needs it (apt install nodejs)"
docker info >/dev/null 2>&1 || warn "docker daemon not reachable / user not in docker group (sudo usermod -aG docker \$USER; re-login)"
ok "docker, openssl, ssh present"

# ---- 2. pol CLI ------------------------------------------------------
step "2/6 pol CLI"
if command -v pol >/dev/null 2>&1; then
    skip "pol already installed ($(command -v pol))"
else
    if confirm "install the pol CLI (polari-cli/shells/install-cli.sh)?"; then
        bash "$SUITE_ROOT/polari-cli/shells/install-cli.sh" && ok "pol installed" \
            || warn "pol install failed — run it manually"
    else skip "pol CLI"; fi
fi

# ---- 3. registry trust (docker certs.d) ------------------------------
step "3/6 trust the mesh registry ($REGISTRY)"
CERTS_D="/etc/docker/certs.d/$REGISTRY"
if [ -f "$CERTS_D/ca.crt" ] && cmp -s "$CA" "$CERTS_D/ca.crt"; then
    skip "already trusted"
else
    echo "  docker will trust images pushed/pulled from $REGISTRY."
    echo "  needs sudo (writes $CERTS_D/ca.crt)."
    if confirm "trust it now?"; then
        sudo install -D -m 0644 "$CA" "$CERTS_D/ca.crt" \
            && ok "registry trusted" || warn "sudo failed — run: sudo install -D -m 0644 '$CA' '$CERTS_D/ca.crt'"
    else skip "registry trust (do it before pushing)"; fi
fi

# ---- 4. isle CA in the system + browser (via isle trust if present) --
step "4/6 isle CA trust (system + browser)"
if ssh -o BatchMode=yes -o ConnectTimeout=6 "detts@$ISLE_HOST" true 2>/dev/null; then
    ok "isle host reachable over SSH"
else
    warn "cannot SSH detts@$ISLE_HOST (key not set up?) — deploys need it"
fi
if command -v isle >/dev/null 2>&1; then
    isle trust install ${ASSUME_YES:+--yes} || warn "isle trust install skipped"
else
    if [ -f /usr/local/share/ca-certificates/isle-root.crt ] && cmp -s "$CA" /usr/local/share/ca-certificates/isle-root.crt; then
        skip "isle CA already in system store"
    elif confirm "add the isle CA to the system store (curl/tools)?"; then
        sudo install -D -m 0644 "$CA" /usr/local/share/ca-certificates/isle-root.crt \
            && sudo update-ca-certificates >/dev/null 2>&1 && ok "system store trusts the isle CA" \
            || warn "system trust failed"
        command -v certutil >/dev/null 2>&1 || warn "for Chrome/.isle in a browser: apt install libnss3-tools, then re-run (or use https://trust.isle)"
    else skip "isle CA system trust"; fi
fi

# ---- 5. the dev-loop helper (pol isle deploy) ------------------------
step "5/6 dev-loop shortcut"
WRAP="$HOME/.local/bin/isle-dev-deploy"
mkdir -p "$HOME/.local/bin"
cat > "$WRAP" <<EOF
#!/usr/bin/env bash
# Build polari here, push to the mesh registry, deploy on the isle.
set -e
IMG=\${1:-backend}
echo "==> pol node build \$IMG"; pol node build "\$IMG"
echo "==> push prf-\$IMG:staging -> $REGISTRY"
docker tag  "prf-\$IMG:staging" "$REGISTRY/prf-\$IMG:staging"
docker push "$REGISTRY/prf-\$IMG:staging"
echo "==> deploy on the isle"
ssh "detts@$ISLE_HOST" isle-polari-deploy --pull
EOF
chmod +x "$WRAP"
ok "isle-dev-deploy installed ($WRAP) — 'isle-dev-deploy backend' = build+push+deploy"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "add \$HOME/.local/bin to PATH (echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc)";; esac

# ---- 6. verify ------------------------------------------------------
step "6/6 verify"
if docker pull "$REGISTRY/prf-backend:staging" >/dev/null 2>&1; then
    ok "registry reachable + trusted (pulled prf-backend)"
    docker rmi "$REGISTRY/prf-backend:staging" >/dev/null 2>&1 || true
else
    warn "registry pull failed — trust (step 3) or reachability. Is the isle registry up? (isle-registry-setup on the CA host)"
fi
echo
ok "developer environment ready."
echo "  dev loop:   isle-dev-deploy backend      (build -> push -> deploy on the isle)"
echo "  browse:     https://polari.isle/isle-store   (import the isle CA / see https://trust.isle)"
echo "  teardown:   ssh detts@$ISLE_HOST isle-polari-teardown"
