#!/bin/bash
# prod.sh — `pol prod`: ONE guided flow for a production Polari deployment
# (PRODUCTION_DEPLOY_PLAN §11, his ask 2026-09-09: "smooth and easy to guide
# a user through setting up everything they need to and choosing from all of
# their options").
#
# Two routes exist for production; this tool is the SERVER route:
#   swarm (this tool)   a small VM or the home swarm: the lean profile
#                       (docker-compose.lean.yml → stack polari-lean), for
#                       developers and AI-assisted deploys — every choice is
#                       an answer in a file, so it runs unattended too
#   apps / KVM          a home computer: install the polari-complete deb and
#                       open the Isle App Store ("Create my own isle") — the
#                       user-friendly door; `pol prod guide` points there
#
#   pol prod guide                 the walkthrough (whiptail menus when there is a terminal;
#                                  plain prompts otherwise); writes .generated/prod-answers.env
#   pol prod check                 preflight: docker/swarm, ports, DNS, images, certs, debs
#   pol prod plan                  what apply WOULD do, from the answers (no changes)
#   pol prod apply [--yes]         render + stage + deploy from the answers (idempotent)
#   pol prod status                the board: stack, services, cert issuer/expiry, DNS, health
#   pol prod cert                  (re)issue the edge certificate per the answers
#   pol prod debs [build|copy <dir>]   stage the platform debs the server hands out
#   pol prod render | deploy | down    the individual steps
# Answers: .generated/prod-answers.env (POL_PROD_ROUTE, DOMAIN, CERT_MODE,
# LE_CHALLENGE, LE_EMAIL, AUTH, MODULES, DEBS, DEMO). Any of them may also be
# passed as env vars (POL_PROD_DOMAIN=…), which is how an AI or a script
# drives it: `POL_PROD_DOMAIN=example.org POL_PROD_CERT_MODE=letsencrypt pol prod apply --yes`.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/state.sh"
SUITE="$POL_SUITE_ROOT"
GEN="$SUITE/.generated"
ANSWERS="$GEN/prod-answers.env"
CA_DIR="$SUITE/polari-rf-node/ca"
mkdir -p "$GEN"

# ---------------------------------------------------------------- answers
# defaults → file → env (env wins: the AI/script route)
POL_PROD_ROUTE="${POL_PROD_ROUTE:-}"; POL_PROD_DOMAIN="${POL_PROD_DOMAIN:-}"; POL_PROD_CERT_MODE="${POL_PROD_CERT_MODE:-}"
POL_PROD_LE_CHALLENGE="${POL_PROD_LE_CHALLENGE:-}"; POL_PROD_LE_EMAIL="${POL_PROD_LE_EMAIL:-}"; POL_PROD_AUTH="${POL_PROD_AUTH:-}"
POL_PROD_MODULES="${POL_PROD_MODULES:-}"; POL_PROD_DEBS="${POL_PROD_DEBS:-}"; POL_PROD_DEMO="${POL_PROD_DEMO:-}"; POL_PROD_IMAGE_TAG="${POL_PROD_IMAGE_TAG:-}"
load_answers() {
    if [ -f "$ANSWERS" ]; then
        while IFS='=' read -r k v; do
            case "$k" in POL_PROD_*) [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v" ;; esac
        done < "$ANSWERS"
    fi
    : "${POL_PROD_ROUTE:=swarm}"; : "${POL_PROD_CERT_MODE:=self-signed}"; : "${POL_PROD_LE_CHALLENGE:=http}"
    : "${POL_PROD_AUTH:=off}"; : "${POL_PROD_MODULES:=polariapps,appstore,islemesh,terms}"; : "${POL_PROD_DEBS:=skip}"
    : "${POL_PROD_DEMO:=on}"; : "${POL_PROD_IMAGE_TAG:=staging}"
}
save_answers() {
    {
        echo "# pol prod answers — $(date -Is). Edit and re-run: pol prod apply. Env vars POL_PROD_* override."
        for k in ROUTE DOMAIN CERT_MODE LE_CHALLENGE LE_EMAIL AUTH MODULES DEBS DEMO IMAGE_TAG; do
            v="POL_PROD_$k"; echo "$v=${!v}"
        done
    } > "$ANSWERS"
    log_success "answers saved: $ANSWERS"
}

# ---------------------------------------------------------------- TUI
HAS_TUI=0; [ -t 0 ] && [ -t 1 ] && command -v whiptail >/dev/null 2>&1 && HAS_TUI=1
tui_menu() {  # title text default item1 desc1 item2 desc2 … → chosen item
    local title=$1 text=$2 default=$3; shift 3
    if [ "$HAS_TUI" = 1 ]; then
        whiptail --title "$title" --default-item "$default" --menu "$text" 20 78 8 "$@" 3>&1 1>&2 2>&3
    else
        echo; echo "== $title"; echo "$text"; local i=1; local items=("$@")
        while [ $i -le $# ]; do printf "  %s) %s — %s\n" "${items[$((i-1))]}" "${items[$((i-1))]}" "${items[$i]}"; i=$((i+2)); done
        read -r -p "choice [$default]: " c; echo "${c:-$default}"
    fi
}
tui_input() {  # title text default → value
    if [ "$HAS_TUI" = 1 ]; then whiptail --title "$1" --inputbox "$2" 12 78 "$3" 3>&1 1>&2 2>&3
    else echo; echo "== $1"; read -r -p "$2 [$3]: " c; echo "${c:-$3}"; fi
}
tui_yesno() {  # title text → 0 yes / 1 no
    if [ "$HAS_TUI" = 1 ]; then whiptail --title "$1" --yesno "$2" 14 78
    else echo; echo "== $1"; read -r -p "$2 [y/N]: " c; [ "${c,,}" = y ]; fi
}
tui_msg() { if [ "$HAS_TUI" = 1 ]; then whiptail --title "$1" --msgbox "$2" 20 78; else echo; echo "== $1"; echo "$2"; fi; }

# ---------------------------------------------------------------- facts
public_ip() { curl -s --max-time 4 https://api.ipify.org 2>/dev/null || curl -s --max-time 4 https://ifconfig.me 2>/dev/null || true; }
resolve() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
lean_names() { echo "$1 www.$1 prf.$1 api.prf.$1 apt.$1"; }
edge_cert_issuer() { [ -s "$GEN/certs/edge/fullchain.pem" ] && openssl x509 -in "$GEN/certs/edge/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || echo "none"; }
edge_cert_expiry() { [ -s "$GEN/certs/edge/fullchain.pem" ] && openssl x509 -in "$GEN/certs/edge/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "-"; }
edge_cert_is_public() { edge_cert_issuer | grep -qiE "let's encrypt|letsencrypt|R1[0-9]|E[0-9]|ISRG|ZeroSSL|Buypass|DigiCert|Sectigo|GlobalSign|Google Trust"; }
LE_LIVE() { echo "${CERTBOT_CONFIG_DIR:-$CA_DIR/.generated/letsencrypt}/live/${LE_CERT_NAME:-pol-proxy-lean}"; }

# ---------------------------------------------------------------- guide
do_guide() {
    load_answers
    pol_box "pol prod — production deployment guide"
    local route
    route=$(tui_menu "Which kind of production deployment?" \
"Two routes exist. Pick the one for THIS machine." "$POL_PROD_ROUTE" \
        swarm "A server (VM or the home swarm): the lean profile, docker swarm — for developers / AI-assisted" \
        apps  "A home computer for people: the Isle App Store route (KVM isle) — not this tool")
    if [ "$route" = "apps" ]; then
        tui_msg "The user-friendly route" \
"That route is the Isle App Store, not a terminal:
  1. install the polari-complete deb (Download Polari on the site, or the offline medium)
  2. open 'Isle App Store' from the menu
  3. choose 'Create my own isle' — it runs the guided isle install in a window
Nothing else to do here. (pol prod is the server route.)"
        POL_PROD_ROUTE=apps; save_answers; return 0
    fi
    POL_PROD_ROUTE=swarm
    POL_PROD_DOMAIN=$(tui_input "Domain" "The public domain this server answers for (the site at the apex; prf., api.prf., apt. are made from it):" "${POL_PROD_DOMAIN:-polari-systems.org}")
    [ -n "$POL_PROD_DOMAIN" ] || die "a domain is required"
    local ip; ip=$(public_ip)
    local dnsmsg="Names this deployment serves, and where they resolve now (this host's public address: ${ip:-unknown}):\n"
    for n in $(lean_names "$POL_PROD_DOMAIN"); do dnsmsg+="  $n → $(resolve "$n" || true)\n"; done
    dnsmsg+="\nEvery name must point at this server before a provider-issued certificate can be approved."
    tui_msg "DNS check" "$(printf "$dnsmsg")"
    POL_PROD_CERT_MODE=$(tui_menu "HTTPS certificate" \
"Browsers trust a certificate signed by a public authority. Choose:" "$POL_PROD_CERT_MODE" \
        letsencrypt "Provider-issued, auto-approved (Let's Encrypt): trusted everywhere, renews itself — needs the DNS above" \
        self-signed "Auto-generated by this suite's own CA: works now, browsers warn until the root is imported")
    if [ "$POL_PROD_CERT_MODE" = letsencrypt ]; then
        POL_PROD_LE_CHALLENGE=$(tui_menu "How should the provider verify you own the names?" \
"Both give the same certificate: one for all five names." "$POL_PROD_LE_CHALLENGE" \
            http "HTTP challenge through this server's port 80 — any registrar, nothing to configure" \
            dns  "DNS challenge through the DigitalOcean API — needs DO_API_TOKEN; works before port 80 is open")
        POL_PROD_LE_EMAIL=$(tui_input "Contact e-mail" "Let's Encrypt sends expiry warnings here (never published):" "${POL_PROD_LE_EMAIL:-}")
    fi
    POL_PROD_AUTH=$(tui_menu "Logins" "A distribution server needs no accounts (D2 default). Keycloak adds ~1 GB." "$POL_PROD_AUTH" \
        off "No login server — browse, download, install (the lean profile)" \
        keycloak "Keycloak (the full profile: docker-compose.prod.yml, heavier; not the lean stack)")
    POL_PROD_MODULES=$(tui_input "Modules" "The floor set the server boots (comma-separated; more = more memory):" "$POL_PROD_MODULES")
    POL_PROD_DEBS=$(tui_menu "Installers to hand out" "The site's Download page serves the platform debs staged in .generated/debs." "$POL_PROD_DEBS" \
        build "Build them on this machine now (needs the suite checkout + dpkg-deb; ~minutes)" \
        copy  "Copy them from a release pool directory I will name" \
        skip  "Skip for now (the Download page will say none are staged)")
    if [ "$POL_PROD_DEBS" = copy ]; then POL_PROD_DEBS="copy:$(tui_input "Release pool" "Directory holding the release's debs/ (e.g. polari-jenkins/pool/<version>/debs):" "")"; fi
    if tui_yesno "Demonstration notice" "Show the 'demonstration instance — no personal information' notice and terms gate on the apps? (Answer No for a plain distribution server.)"; then POL_PROD_DEMO=on; else POL_PROD_DEMO=off; fi
    POL_PROD_IMAGE_TAG=$(tui_input "Image tag" "The prf-backend / prf-frontend image tag present on the manager (later: the GHCR release tag):" "$POL_PROD_IMAGE_TAG")
    save_answers
    do_plan
    if tui_yesno "Apply now?" "Render the configuration, stage the certificate and debs, and deploy stack polari-lean on this swarm?"; then do_apply --yes; else log_info "Not applied. Later: pol prod apply"; fi
}

# ---------------------------------------------------------------- plan / check
do_plan() {
    load_answers
    pol_box "pol prod — the plan"
    echo "  route        $POL_PROD_ROUTE   (lean profile: docker-compose.lean.yml → stack polari-lean)"
    echo "  domain       $POL_PROD_DOMAIN   names: $(lean_names "$POL_PROD_DOMAIN")"
    echo "  certificate  $POL_PROD_CERT_MODE$([ "$POL_PROD_CERT_MODE" = letsencrypt ] && echo " ($POL_PROD_LE_CHALLENGE challenge, $POL_PROD_LE_EMAIL)")   now: $(edge_cert_issuer) (expires $(edge_cert_expiry))"
    echo "  logins       $POL_PROD_AUTH"
    echo "  modules      $POL_PROD_MODULES"
    echo "  installers   $POL_PROD_DEBS   staged now: $(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l)"
    echo "  demo notice  $POL_PROD_DEMO"
    echo "  images       prf-backend:$POL_PROD_IMAGE_TAG prf-frontend:$POL_PROD_IMAGE_TAG pol-hub:$POL_PROD_IMAGE_TAG"
    echo
    echo "  apply will: 1 preflight · 2 write .generated/.env.lean + runtime configs · 3 render nginx.lean.conf"
    echo "              4 stage the edge certificate · 5 stage debs · 6 build pol-hub image · 7 render the stack"
    echo "              8 docker stack deploy polari-lean · 9 issue the Let's Encrypt cert (http mode needs the stack up) · 10 status"
}
do_check() {
    load_answers
    pol_box "pol prod — preflight"
    local fail=0
    command -v docker >/dev/null && log_success "docker present" || { log_error "docker missing"; fail=1; }
    local st; st=$(docker info --format '{{.Swarm.LocalNodeState}}/{{.Swarm.ControlAvailable}}' 2>/dev/null || echo "none")
    case "$st" in active/true) log_success "swarm manager on this node" ;; active/false) log_error "this node is a swarm WORKER — run pol prod on the manager"; fail=1 ;; *) log_warn "no swarm yet — apply will run: docker swarm init" ;; esac
    for p in 80 443; do if ss -ltn 2>/dev/null | grep -q ":$p "; then log_error "port $p is in use (a compose stack? pol suite down)"; fail=1; else log_success "port $p free"; fi; done
    for img in prf-backend prf-frontend; do docker image inspect "$img:$POL_PROD_IMAGE_TAG" >/dev/null 2>&1 && log_success "image $img:$POL_PROD_IMAGE_TAG present" || { log_error "image $img:$POL_PROD_IMAGE_TAG missing (pol node build, or pull the release tag)"; fail=1; }; done
    if [ -n "$POL_PROD_DOMAIN" ]; then
        local ip; ip=$(public_ip); local bad=0
        for n in $(lean_names "$POL_PROD_DOMAIN"); do r=$(resolve "$n" || true); if [ -n "$ip" ] && [ "$r" = "$ip" ]; then log_success "DNS $n → $r"; else log_warn "DNS $n → ${r:-unresolved} (this host: ${ip:-unknown})"; bad=1; fi; done
        [ "$bad" = 1 ] && [ "$POL_PROD_CERT_MODE" = letsencrypt ] && log_warn "a provider-issued certificate needs every name pointing here first"
    else log_warn "no domain answered yet (pol prod guide)"; fi
    if [ -s "$GEN/certs/edge/fullchain.pem" ]; then edge_cert_is_public && log_success "edge certificate: publicly trusted ($(edge_cert_issuer))" || log_warn "edge certificate: self-signed — browsers will warn (pol prod cert)"; else log_warn "no edge certificate staged yet (apply stages one)"; fi
    local n; n=$(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l); [ "$n" -gt 0 ] && log_success "$n platform deb(s) staged" || log_warn "no platform debs staged (pol prod debs build|copy)"
    [ -f "$SUITE/polari-jenkins/secrets/signing/apt_signing_keyid" ] && log_success "apt signing key present" || log_warn "apt repo signing key absent (polari-jenkins/secrets) — apt.$POL_PROD_DOMAIN will serve an unsigned/empty tree"
    [ "$POL_PROD_AUTH" = keycloak ] && log_warn "Keycloak chosen: use the full profile (start-prod.sh / docker-compose.prod.yml) and rotate its credentials first (pol security rotate prod)"
    return $fail
}

# ---------------------------------------------------------------- steps
write_configs() {
    load_answers; [ -n "$POL_PROD_DOMAIN" ] || die "no domain — pol prod guide (or POL_PROD_DOMAIN=…)"
    local D=$POL_PROD_DOMAIN
    cat > "$GEN/.env.lean" <<EOF
# generated by pol prod — the lean profile's inputs (docker-compose.lean.yml)
PROD_DOMAIN=$D
BASE_DOMAIN=$D
POLARI_IMAGE_TAG=$POL_PROD_IMAGE_TAG
POLARI_LEAN_MODULES=$POL_PROD_MODULES
POL_SUITE_ROOT=$SUITE
DEPLOY_ENV=production
EOF
    local demo_enabled=false; [ "$POL_PROD_DEMO" = on ] && demo_enabled=true
    cat > "$GEN/prf-runtime-config.lean.json" <<EOF
{
  "_comment": "LEAN PRODUCTION: generated by pol prod", "_generated": "$(date -Is)", "_domain": "$D",
  "demo": { "enabled": $demo_enabled, "title": "Demonstration instance",
            "message": "This is a public demonstration of Polari. It exists so you can try the software, not to hold anyone's data.",
            "termsUrl": "https://$D/docs/demo-terms.html", "version": "2026-09-09" },
  "backend":  { "http": { "protocol": "http", "url": "api.prf.$D", "port": "80" },
                "https": { "protocol": "https", "url": "api.prf.$D", "port": "443" },
                "ws": { "protocol": "wss", "url": "api.prf.$D", "port": "443" }, "preferHttps": true },
  "frontend": { "http": { "protocol": "http", "url": "prf.$D", "port": "80" },
                "https": { "protocol": "https", "url": "prf.$D", "port": "443" } },
  "connection": { "retryInterval": 3000, "maxRetryTime": 60000, "timeout": 30000 },
  "features": { "enableHttps": true, "enableRuntimeConfig": false, "allowBackendChange": false }
}
EOF
    cat > "$GEN/pol-hub-runtime-config.lean.json" <<EOF
{ "_comment": "LEAN PRODUCTION: generated by pol prod", "_generated": "$(date -Is)",
  "links": { "prf": "https://prf.$D", "dps": "https://$D/docs.html", "mesh": "${ISLE_MESH_URL:-https://$D/docs/networking-model.html}", "oseb": "https://$D/docs.html" } }
EOF
    sed "s/\${PROD_DOMAIN}/$D/g" "$SUITE/pol-proxy/nginx.lean.conf.template" > "$GEN/nginx.lean.conf"
    mkdir -p "$GEN/debs" "$GEN/apt" "$GEN/certbot-www" "$GEN/certs/edge"
    log_success "configs written: .env.lean, prf/pol-hub runtime configs, nginx.lean.conf"
}
stage_cert() {
    load_answers
    local live; live=$(LE_LIVE)
    mkdir -p "$GEN/certs/edge"
    if [ -s "$live/fullchain.pem" ] && [ -s "$live/privkey.pem" ]; then
        cp -L "$live/fullchain.pem" "$GEN/certs/edge/fullchain.pem"; cp -L "$live/privkey.pem" "$GEN/certs/edge/privkey.pem"; chmod 600 "$GEN/certs/edge/privkey.pem"
        log_success "edge certificate: Let's Encrypt (expires $(edge_cert_expiry))"
    elif [ -s "$GEN/certs/edge/fullchain.pem" ] && edge_cert_is_public; then
        log_success "edge certificate already publicly trusted ($(edge_cert_issuer))"
    else
        # self-signed for the lean names from the suite's own CA (openssl; the step-ca route can replace it)
        local D=$POL_PROD_DOMAIN; local san=""; for n in $(lean_names "$D"); do san="${san:+$san,}DNS:$n"; done
        if [ -s "$SUITE/pol-proxy/certs/ca/pol-ca.crt" ] && [ -s "$SUITE/pol-proxy/certs/ca/pol-ca.key" ]; then
            openssl req -new -newkey rsa:2048 -nodes -keyout "$GEN/certs/edge/privkey.pem" -subj "/CN=$D" -addext "subjectAltName=$san" -out "$GEN/certs/edge/req.csr" 2>/dev/null
            openssl x509 -req -in "$GEN/certs/edge/req.csr" -CA "$SUITE/pol-proxy/certs/ca/pol-ca.crt" -CAkey "$SUITE/pol-proxy/certs/ca/pol-ca.key" -CAcreateserial -days 825 -copy_extensions copy -out "$GEN/certs/edge/fullchain.pem" 2>/dev/null
            rm -f "$GEN/certs/edge/req.csr"
            log_warn "edge certificate: signed by the suite CA (import pol-proxy/certs/ca/pol-ca.crt to trust it) — browsers warn until 'pol prod cert' issues a public one"
        else
            openssl req -x509 -newkey rsa:2048 -nodes -keyout "$GEN/certs/edge/privkey.pem" -out "$GEN/certs/edge/fullchain.pem" -days 825 -subj "/CN=$D" -addext "subjectAltName=$san" 2>/dev/null
            log_warn "edge certificate: SELF-SIGNED (no suite CA found) — browsers warn until 'pol prod cert' issues a public one"
        fi
        chmod 600 "$GEN/certs/edge/privkey.pem"
    fi
}
stage_debs() {
    load_answers; mkdir -p "$GEN/debs"
    case "$POL_PROD_DEBS" in
        build) log_info "building the platform debs (this takes minutes)"; (cd "$SUITE" && bash build-polari-isle-deb.sh && bash build-polari-complete-deb.sh --flavor online) || log_warn "deb build failed — the Download page will list what is staged" ;;
        copy:*) local src=${POL_PROD_DEBS#copy:}; [ -d "$src" ] || die "release pool dir not found: $src"; cp -v "$src"/*.deb "$GEN/debs/" ;;
        *) : ;;
    esac
    log_info "platform debs staged: $(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l)"
}
build_hub() {
    load_answers
    docker build -q -t "pol-hub:$POL_PROD_IMAGE_TAG" "$SUITE/pol-hub" >/dev/null && log_success "image pol-hub:$POL_PROD_IMAGE_TAG built (site + docs)"
}
render_stack() {
    load_answers
    set -a; source "$GEN/.env.lean"; set +a
    docker compose -f "$SUITE/docker-compose.lean.yml" --env-file "$GEN/.env.lean" config 2>/dev/null \
        | python3 "$SUITE/pol-build/tools/stackify.py" > "$GEN/stack-lean.yml"
    [ -s "$GEN/stack-lean.yml" ] || die "stack render produced nothing"
    log_success "stack rendered: $GEN/stack-lean.yml"
}
deploy_stack() {
    load_answers
    docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active || { log_info "docker swarm init"; docker swarm init --advertise-addr "$(lan_ip)" >/dev/null; }
    set -a; source "$GEN/.env.lean"; set +a
    docker stack deploy -c "$GEN/stack-lean.yml" polari-lean
    record_build swarm lean production
    log_success "stack polari-lean deployed (pol prod status)"
}
issue_cert() {
    load_answers
    [ "$POL_PROD_CERT_MODE" = letsencrypt ] || { log_info "certificate mode is $POL_PROD_CERT_MODE — nothing to issue"; return 0; }
    [ -n "$POL_PROD_LE_EMAIL" ] || die "LE needs an e-mail (POL_PROD_LE_EMAIL)"
    log_info "issuing the Let's Encrypt certificate for $(lean_names "$POL_PROD_DOMAIN") ($POL_PROD_LE_CHALLENGE challenge)"
    LE_CERT_NAME=pol-proxy-lean LE_DOMAIN="$POL_PROD_DOMAIN" LE_EMAIL="$POL_PROD_LE_EMAIL" LE_CHALLENGE="$POL_PROD_LE_CHALLENGE" \
        LE_WEBROOT="$GEN/certbot-www" DEPLOY_ENV=prod PROD_DOMAIN="$POL_PROD_DOMAIN" BASE_DOMAIN="$POL_PROD_DOMAIN" \
        bash "$CA_DIR/setup-letsencrypt.sh" --non-interactive || die "certificate issue failed — see the certbot output above"
    stage_cert
    # a swarm secret is immutable: rotate by re-deploying the stack with the new files
    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx polari-lean; then render_stack; deploy_stack; fi
    bash "$SCRIPT_DIR/cert.sh" auto-renew install >/dev/null 2>&1 || true
    log_success "public certificate in place; weekly auto-renew installed"
}
do_apply() {
    load_answers
    [ "$POL_PROD_ROUTE" = swarm ] || die "route is '$POL_PROD_ROUTE' — pol prod applies the swarm (server) route"
    [ "$POL_PROD_AUTH" = off ] || die "logins=keycloak is the full profile: use start-prod.sh (docker-compose.prod.yml); the lean stack has no Keycloak"
    if [ "${1:-}" != "--yes" ] && [ "$HAS_TUI" = 1 ]; then do_plan; tui_yesno "Apply?" "Proceed with the plan above?" || return 0; fi
    pol_box "pol prod — apply"
    do_check || log_warn "preflight reported problems — continuing (fix and re-run apply; every step is idempotent)"
    write_configs; stage_cert; stage_debs; build_hub; render_stack; deploy_stack
    if [ "$POL_PROD_CERT_MODE" = letsencrypt ] && ! edge_cert_is_public; then
        log_info "waiting for the proxy before the HTTP challenge…"; sleep 8; issue_cert
    fi
    do_status
}
do_status() {
    load_answers
    pol_box "pol prod — status"
    echo "  domain       ${POL_PROD_DOMAIN:-?}"
    echo "  stack        $(docker stack ls --format '{{.Name}} ({{.Services}} services)' 2>/dev/null | grep polari-lean || echo 'polari-lean not deployed')"
    docker stack services polari-lean --format '  service      {{.Name}}  {{.Replicas}}  {{.Image}}' 2>/dev/null | sed 's/polari-lean_//'
    echo "  certificate  $(edge_cert_issuer)  expires $(edge_cert_expiry)  $(edge_cert_is_public && echo 'PUBLICLY TRUSTED' || echo 'NOT public — browsers warn (pol prod cert)')"
    local ip r; ip=$(public_ip); for n in $(lean_names "${POL_PROD_DOMAIN:-x}"); do r=$(resolve "$n" || true); printf "  dns          %-32s %s%s\n" "$n" "${r:-unresolved}" "$([ -n "$ip" ] && [ "$r" = "$ip" ] && echo '  ✓ this host')"; done
    echo "  installers   $(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l) staged (https://${POL_PROD_DOMAIN:-…}/downloads)   apt tree: $([ -d "$GEN/apt/dists" ] && echo present || echo 'not published')"
    local h; h=$(curl -sk --max-time 5 -H "Host: api.prf.${POL_PROD_DOMAIN:-x}" https://127.0.0.1/api/health 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('phase'), '—', d.get('onlineCount'), '/', d.get('moduleCount'), 'modules online')" 2>/dev/null || echo "not answering yet")
    echo "  backend      $h"
    local t; t=$(curl -sk --max-time 5 -H "Host: api.prf.${POL_PROD_DOMAIN:-x}" "https://127.0.0.1/api/terms/active" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('terms gate on' if d.get('pending') else 'no terms gate', '· demo bar', 'on' if d.get('show_bar') else 'off')" 2>/dev/null || echo "-")
    echo "  terms        $t"
    local nxt=""; edge_cert_is_public || nxt="pol prod cert (public certificate) · "; [ "$(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l)" -gt 0 ] || nxt="${nxt}pol prod debs build · "
    echo "  next         ${nxt}pol prod status"
}

# ---------------------------------------------------------------- dispatch
show_help() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }
COMMAND=${1:-guide}; shift || true
case "$COMMAND" in
    guide)   do_guide ;;
    plan)    do_plan ;;
    check)   do_check ;;
    apply)   do_apply "$@" ;;
    status)  do_status ;;
    cert)    load_answers; issue_cert ;;
    debs)    load_answers; case "${1:-}" in build) POL_PROD_DEBS=build ;; copy) POL_PROD_DEBS="copy:${2:?dir}" ;; esac; stage_debs ;;
    render)  write_configs; stage_cert; render_stack ;;
    deploy)  render_stack; deploy_stack ;;
    down)    docker stack rm polari-lean; log_success "stack polari-lean removed (data volume kept)" ;;
    help|-h|--help) show_help ;;
    *) die "unknown verb '$COMMAND' — pol prod help" ;;
esac
