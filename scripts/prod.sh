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
#   pol prod bootstrap             a fresh VM: install docker, swarm init, then the guide
# Profiles: logins=off → the LEAN stack (docker-compose.lean.yml, stack polari-lean);
# logins=keycloak → the FULL stack (docker-compose.prod.yml, stack polari-prod: Keycloak,
# MariaDB, MinIO, the scorecard; odoo with POL_PROD_ODOO=on). Both deploy the same way.
# Images: POL_PROD_IMAGE_REPO=ghcr.io/dausume/ pulls the release images; empty = build locally.
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
POL_PROD_IMAGE_REPO="${POL_PROD_IMAGE_REPO:-}"; POL_PROD_ODOO="${POL_PROD_ODOO:-}"
load_answers() {
    if [ -f "$ANSWERS" ]; then
        while IFS='=' read -r k v; do
            case "$k" in POL_PROD_*) [ -n "${!k:-}" ] || printf -v "$k" '%s' "$v" ;; esac
        done < "$ANSWERS"
    fi
    : "${POL_PROD_ROUTE:=swarm}"; : "${POL_PROD_CERT_MODE:=self-signed}"; : "${POL_PROD_LE_CHALLENGE:=http}"
    : "${POL_PROD_AUTH:=off}"; : "${POL_PROD_MODULES:=polariapps,appstore,islemesh,terms}"; : "${POL_PROD_DEBS:=skip}"
    : "${POL_PROD_DEMO:=on}"; : "${POL_PROD_IMAGE_TAG:=staging}"; : "${POL_PROD_ODOO:=off}"
}
save_answers() {
    {
        echo "# pol prod answers — $(date -Is). Edit and re-run: pol prod apply. Env vars POL_PROD_* override."
        for k in ROUTE DOMAIN CERT_MODE LE_CHALLENGE LE_EMAIL AUTH MODULES DEBS DEMO IMAGE_TAG IMAGE_REPO ODOO; do
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
full_names() { echo "$1 www.$1 auth.$1 psc.$1 api.psc.$1 prf.$1 api.prf.$1 files.$1 s3.$1 odoo.$1 apt.$1"; }
profile() { load_answers; [ "$POL_PROD_AUTH" = keycloak ] && echo full || echo lean; }
stack_name() { [ "$(profile)" = full ] && echo polari-prod || echo polari-lean; }
names() { if [ "$(profile)" = full ]; then full_names "$1"; else lean_names "$1"; fi; }
cert_row() { [ "$(profile)" = full ] && echo pol-proxy-public || echo pol-proxy-lean; }
edge_cert_issuer() { [ -s "$GEN/certs/edge/fullchain.pem" ] && openssl x509 -in "$GEN/certs/edge/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || echo "none"; }
edge_cert_expiry() { [ -s "$GEN/certs/edge/fullchain.pem" ] && openssl x509 -in "$GEN/certs/edge/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "-"; }
edge_cert_is_public() { edge_cert_issuer | grep -qiE "let's encrypt|letsencrypt|R1[0-9]|E[0-9]|ISRG|ZeroSSL|Buypass|DigiCert|Sectigo|GlobalSign|Google Trust"; }
LE_LIVE() { echo "${CERTBOT_CONFIG_DIR:-$CA_DIR/.generated/letsencrypt}/live/${LE_CERT_NAME:-$(cert_row)}"; }

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
"A PUBLICLY TRUSTED certificate is one signed by an authority every browser and phone already trusts, so visitors see the padlock with no warning. Let's Encrypt issues them free and automatically. Choose:" "$POL_PROD_CERT_MODE" \
        letsencrypt "Publicly trusted (Let's Encrypt): recognised instantly by anyone on the internet, renews itself — needs the DNS above" \
        self-signed "Auto-generated by this suite's own CA: works now, browsers warn until the root is imported")
    if [ "$POL_PROD_CERT_MODE" = letsencrypt ]; then
        POL_PROD_LE_CHALLENGE=$(tui_menu "How should the provider verify you own the names?" \
"Both give the same certificate: one for all five names." "$POL_PROD_LE_CHALLENGE" \
            http "HTTP challenge through this server's port 80 — any registrar, nothing to configure" \
            dns  "DNS challenge through the DigitalOcean API — needs DO_API_TOKEN; works before port 80 is open")
        POL_PROD_LE_EMAIL=$(tui_input "Contact e-mail" "Let's Encrypt sends expiry warnings here (never published):" "${POL_PROD_LE_EMAIL:-}")
    fi
    POL_PROD_AUTH=$(tui_menu "Logins" "A distribution server needs no accounts (D2 default). Keycloak adds ~1 GB and brings the scorecard + file store." "$POL_PROD_AUTH" \
        off "No login server — the LEAN profile: site, docs, downloads, one Polari backend (4 services)" \
        keycloak "Keycloak logins — the FULL profile: + scorecard, MariaDB, MinIO (11 names, ~7 GB of limits)")
    [ "$POL_PROD_AUTH" = keycloak ] && { tui_yesno "Odoo" "Also deploy the Odoo ERP pair? (off unless you use it)" && POL_PROD_ODOO=on || POL_PROD_ODOO=off; }
    POL_PROD_MODULES=$(tui_input "Modules" "The floor set the server boots (comma-separated; more = more memory):" "$POL_PROD_MODULES")
    POL_PROD_DEBS=$(tui_menu "Installers to hand out" "The site's Download page serves the platform debs staged in .generated/debs." "$POL_PROD_DEBS" \
        build "Build them on this machine now (needs the suite checkout + dpkg-deb; ~minutes)" \
        copy  "Copy them from a release pool directory I will name" \
        skip  "Skip for now (the Download page will say none are staged)")
    if [ "$POL_PROD_DEBS" = copy ]; then POL_PROD_DEBS="copy:$(tui_input "Release pool" "Directory holding the release's debs/ (e.g. polari-jenkins/pool/<version>/debs):" "")"; fi
    if tui_yesno "Demonstration notice" "Show the 'demonstration instance — no personal information' notice and terms gate on the apps? (Answer No for a plain distribution server.)"; then POL_PROD_DEMO=on; else POL_PROD_DEMO=off; fi
    POL_PROD_IMAGE_REPO=$(tui_input "Image registry" "Registry prefix to PULL release images from (e.g. ghcr.io/dausume/), or empty to build them on this machine from the checkout:" "$POL_PROD_IMAGE_REPO")
    POL_PROD_IMAGE_TAG=$(tui_input "Image tag" "The image tag (a release tag from the registry, or the local tag present on the manager):" "$POL_PROD_IMAGE_TAG")
    save_answers
    do_plan
    if tui_yesno "Apply now?" "Render the configuration, stage the certificate and debs, and deploy stack polari-lean on this swarm?"; then do_apply --yes; else log_info "Not applied. Later: pol prod apply"; fi
}

# ---------------------------------------------------------------- plan / check
do_plan() {
    load_answers
    pol_box "pol prod — the plan"
    echo "  route        $POL_PROD_ROUTE   profile: $(profile) ($([ "$(profile)" = full ] && echo 'docker-compose.prod.yml → stack polari-prod' || echo 'docker-compose.lean.yml → stack polari-lean'))"
    echo "  domain       $POL_PROD_DOMAIN   names: $(names "$POL_PROD_DOMAIN")"
    echo "  certificate  $POL_PROD_CERT_MODE$([ "$POL_PROD_CERT_MODE" = letsencrypt ] && echo " ($POL_PROD_LE_CHALLENGE challenge, $POL_PROD_LE_EMAIL)")   now: $(edge_cert_issuer) (expires $(edge_cert_expiry))"
    echo "  logins       $POL_PROD_AUTH$([ "$POL_PROD_AUTH" = keycloak ] && echo "   odoo: $POL_PROD_ODOO")"
    echo "  modules      $POL_PROD_MODULES"
    echo "  installers   $POL_PROD_DEBS   staged now: $(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l)"
    echo "  demo notice  $POL_PROD_DEMO"
    echo "  images       ${POL_PROD_IMAGE_REPO:-<local build>}…:$POL_PROD_IMAGE_TAG"
    echo
    echo "  apply will: 1 preflight · 2 write env + runtime configs · 3 render the proxy config$([ "$(profile)" = full ] && echo ' · 3b security setup (CA, Keycloak, DB credentials)')"
    echo "              4 stage the edge certificate · 5 stage debs · 6 build or pull images · 7 render the stack"
    echo "              8 docker stack deploy $(stack_name) · 9 issue the Let's Encrypt cert (http mode needs the stack up) · 10 status"
}
do_check() {
    load_answers
    pol_box "pol prod — preflight"
    local fail=0
    command -v docker >/dev/null && log_success "docker present" || { log_error "docker missing"; fail=1; }
    local st; st=$(docker info --format '{{.Swarm.LocalNodeState}}/{{.Swarm.ControlAvailable}}' 2>/dev/null || echo "none")
    case "$st" in active/true) log_success "swarm manager on this node" ;; active/false) log_error "this node is a swarm WORKER — run pol prod on the manager"; fail=1 ;; *) log_warn "no swarm yet — apply will run: docker swarm init" ;; esac
    for p in 80 443; do if ss -ltn 2>/dev/null | grep -q ":$p "; then log_error "port $p is in use (a compose stack? pol suite down)"; fail=1; else log_success "port $p free"; fi; done
    local imgs="prf-backend prf-frontend"; [ "$(profile)" = full ] && imgs="prf-backend prf-frontend pol-mariadb pol-file-store psc-redis pol-keycloak psc-frontend psc-backend"
    for img in $imgs; do docker image inspect "${POL_PROD_IMAGE_REPO}$img:$POL_PROD_IMAGE_TAG" >/dev/null 2>&1 && log_success "image ${POL_PROD_IMAGE_REPO}$img:$POL_PROD_IMAGE_TAG present" || log_warn "image ${POL_PROD_IMAGE_REPO}$img:$POL_PROD_IMAGE_TAG absent — apply will $([ -n "$POL_PROD_IMAGE_REPO" ] && echo pull || echo build) it"; done
    if [ -n "$POL_PROD_DOMAIN" ]; then
        local ip; ip=$(public_ip); local bad=0
        for n in $(names "$POL_PROD_DOMAIN"); do r=$(resolve "$n" || true); if [ -n "$ip" ] && [ "$r" = "$ip" ]; then log_success "DNS $n → $r"; else log_warn "DNS $n → ${r:-unresolved} (this host: ${ip:-unknown})"; bad=1; fi; done
        [ "$bad" = 1 ] && [ "$POL_PROD_CERT_MODE" = letsencrypt ] && log_warn "a provider-issued certificate needs every name pointing here first"
    else log_warn "no domain answered yet (pol prod guide)"; fi
    if [ -s "$GEN/certs/edge/fullchain.pem" ]; then edge_cert_is_public && log_success "edge certificate: publicly trusted ($(edge_cert_issuer))" || log_warn "edge certificate: self-signed — browsers will warn (pol prod cert)"; else log_warn "no edge certificate staged yet (apply stages one)"; fi
    local n; n=$(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l); [ "$n" -gt 0 ] && log_success "$n platform deb(s) staged" || log_warn "no platform debs staged (pol prod debs build|copy)"
    [ -f "$SUITE/polari-jenkins/secrets/signing/apt_signing_keyid" ] && log_success "apt signing key present" || log_warn "apt repo signing key absent (polari-jenkins/secrets) — apt.$POL_PROD_DOMAIN will serve an unsigned/empty tree"
    [ "$POL_PROD_AUTH" = keycloak ] && log_info "full profile: Keycloak + MariaDB + MinIO + scorecard (credentials generated at apply; rotate later with pol security rotate prod)"
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
    bash "$SCRIPT_DIR/proxy.sh" template lean --domain "$D" --topology swarm >/dev/null || die "proxy template failed"
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
        local D=$POL_PROD_DOMAIN; local san=""; for n in $(names "$D"); do san="${san:+$san,}DNS:$n"; done
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
compose_file() { [ "$(profile)" = full ] && echo "$SUITE/docker-compose.prod.yml" || echo "$SUITE/docker-compose.lean.yml"; }
env_file() { [ "$(profile)" = full ] && echo "$GEN/.env.prod" || echo "$GEN/.env.lean"; }
role() { [ "$(profile)" = full ] && echo prod || echo lean; }
render_stack() {
    load_answers
    set -a; source "$(env_file)"; set +a
    local extra=(); [ "$(profile)" = full ] && [ "$POL_PROD_ODOO" = on ] && extra+=(--with-profile odoo)
    # multi-computer: with a registry every node can pull, so services may spread
    # (pol allocate / POL_STACK_CONSTRAINTS place them); with LOCAL builds only the
    # manager has the images — pin every service there or tasks fail elsewhere.
    if [ -z "$POL_PROD_IMAGE_REPO" ]; then
        for svc in $(docker compose -f "$(compose_file)" --env-file "$(env_file)" config --services 2>/dev/null); do extra+=(--constraint "$svc=node.role == manager"); done
    fi
    for c in ${POL_STACK_CONSTRAINTS:-}; do extra+=(--constraint "$c"); done
    local pargs=""; [ "$(profile)" = full ] && [ "$POL_PROD_ODOO" = on ] && pargs="--profile odoo"
    docker compose -f "$(compose_file)" --env-file "$(env_file)" $pargs config 2>"$GEN/compose-config.err" \
        | python3 "$SUITE/pol-build/tools/stackify.py" "${extra[@]}" > "$GEN/stack-$(role).yml" || { cat "$GEN/compose-config.err" >&2; die "stack render failed"; }
    [ -s "$GEN/stack-$(role).yml" ] || { cat "$GEN/compose-config.err" >&2; die "stack render produced nothing"; }
    log_success "stack rendered: $GEN/stack-$(role).yml"
}
build_or_pull_images() {
    load_answers
    set -a; source "$(env_file)"; set +a
    if [ -n "$POL_PROD_IMAGE_REPO" ]; then
        log_info "pulling release images from $POL_PROD_IMAGE_REPO (tag $POL_PROD_IMAGE_TAG)"
        docker compose -f "$(compose_file)" --env-file "$(env_file)" pull --ignore-buildable 2>&1 | tail -3 || die "pull failed"
    else
        log_info "building the profile's images locally (compose builds; the stack deploys them by name — minutes)"
        docker compose -f "$(compose_file)" --env-file "$(env_file)" build 2>&1 | grep -E "^#[0-9]+ (naming|ERROR)|error|Error" | tail -12 || true
    fi
    build_hub
}
deploy_stack() {
    load_answers
    docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active || { log_info "docker swarm init"; docker swarm init --advertise-addr "$(lan_ip)" >/dev/null; }
    set -a; source "$(env_file)"; set +a
    local wra=(); [ -n "$POL_PROD_IMAGE_REPO" ] && wra+=(--with-registry-auth)
    docker stack deploy "${wra[@]}" -c "$GEN/stack-$(role).yml" "$(stack_name)"
    record_build swarm "$(role)" production
    log_success "stack $(stack_name) deployed (pol prod status)"
}
security_setup() {
    # the full profile's CA + Keycloak + DB/MinIO credentials — generated once, never weak defaults
    load_answers
    if [ -s "$SUITE/pol-proxy/certs/ca/pol-ca.crt" ] && [ -s "$SUITE/pol-keycloak/keycloak-admin.env" ] && [ -s "$SUITE/pol-mariadb/mariadb.env" ]; then
        log_success "security material present (CA, Keycloak admin, DB/MinIO credentials) — pol security rotate prod to renew"; return 0
    fi
    log_info "security setup (CA, Keycloak certs + admin, DB/MinIO credentials) — non-interactive, random passwords"
    local pw; pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
    POLARI_CONFIRM_PROD=yes POLARI_SERVER_IP="${POLARI_SERVER_IP:-$(public_ip)}" POLARI_PROD_DOMAIN="$POL_PROD_DOMAIN" \
        POLARI_KC_ADMIN_USER="${POLARI_KC_ADMIN_USER:-admin}" POLARI_KC_ADMIN_PASS="${POLARI_KC_ADMIN_PASS:-$(pw)}" \
        POLARI_MYSQL_ROOT_PASS="${POLARI_MYSQL_ROOT_PASS:-$(pw)}" POLARI_KC_DB_PASS="${POLARI_KC_DB_PASS:-$(pw)}" POLARI_PSC_DB_PASS="${POLARI_PSC_DB_PASS:-$(pw)}" \
        POLARI_MINIO_ROOT_USER="${POLARI_MINIO_ROOT_USER:-polari-admin}" POLARI_MINIO_ROOT_PASS="${POLARI_MINIO_ROOT_PASS:-$(pw)}" \
        bash "$SUITE/setup-polari-security.sh" prod >"$GEN/security-setup.log" 2>&1 || { tail -20 "$GEN/security-setup.log" >&2; die "security setup failed (log: .generated/security-setup.log)"; }
    log_success "security material generated (log: .generated/security-setup.log)"
}
write_configs_full() {
    # the FULL profile's inputs — what prod-setup.sh used to write, minus the weak defaults
    load_answers; [ -n "$POL_PROD_DOMAIN" ] || die "no domain"
    local D=$POL_PROD_DOMAIN
    local kcdb pscdb root muser mpass
    kcdb=$(grep -s '^KC_DB_PASSWORD=' "$GEN/.env.prod" | cut -d= -f2-); pscdb=$(grep -s '^PSC_DB_PASSWORD=' "$GEN/.env.prod" | cut -d= -f2-)
    root=$(grep -s '^MARIADB_ROOT_PASSWORD=' "$GEN/.env.prod" | cut -d= -f2-); muser=$(grep -s '^MINIO_ROOT_USER=' "$GEN/.env.prod" | cut -d= -f2-); mpass=$(grep -s '^MINIO_ROOT_PASSWORD=' "$GEN/.env.prod" | cut -d= -f2-)
    # credentials come from the security setup's env files when present, else from the previous .env.prod, else fresh
    [ -s "$SUITE/pol-mariadb/mariadb.env" ] && { root=${root:-$(grep -s '^MARIADB_ROOT_PASSWORD=' "$SUITE/pol-mariadb/mariadb.env" | cut -d= -f2-)}; kcdb=${kcdb:-$(grep -s '^KC_DB_PASSWORD=' "$SUITE/pol-mariadb/mariadb.env" | cut -d= -f2-)}; pscdb=${pscdb:-$(grep -s '^PSC_DB_PASSWORD=' "$SUITE/pol-mariadb/mariadb.env" | cut -d= -f2-)}; }
    [ -s "$SUITE/pol-file-store/minio.env" ] && { muser=${muser:-$(grep -s '^MINIO_ROOT_USER=' "$SUITE/pol-file-store/minio.env" | cut -d= -f2-)}; mpass=${mpass:-$(grep -s '^MINIO_ROOT_PASSWORD=' "$SUITE/pol-file-store/minio.env" | cut -d= -f2-)}; }
    local pw; pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
    : "${kcdb:=$(pw)}"; : "${pscdb:=$(pw)}"; : "${root:=$(pw)}"; : "${muser:=polari-admin}"; : "${mpass:=$(pw)}"
    cat > "$GEN/.env.prod" <<EOF
# generated by pol prod (full profile) — $(date -Is)
PROD_DOMAIN=$D
BASE_DOMAIN=$D
POLARI_IMAGE_TAG=$POL_PROD_IMAGE_TAG
POLARI_IMAGE_REPO=$POL_PROD_IMAGE_REPO
POLARI_PROD_MODULES=$POL_PROD_MODULES,scoring
POL_SUITE_ROOT=$SUITE
AUTH_URL=https://auth.$D
PSC_URL=https://psc.$D
PSC_API_URL=https://api.psc.$D
PRF_URL=https://prf.$D
PRF_API_URL=https://api.prf.$D
MINIO_CONSOLE_URL=https://files.$D
MINIO_S3_URL=https://s3.$D
CORS_ORIGINS=https://$D,https://www.$D,https://prf.$D,https://psc.$D
APP_CORS_ALLOWED_ORIGINS=https://$D,https://www.$D,https://prf.$D,https://psc.$D
KC_HOSTNAME=auth.$D
POLARI_KEYCLOAK_ISSUER_URI=https://auth.$D/realms/Polari
POLARI_KEYCLOAK_JWKS_URI=http://pol-keycloak:8080/realms/Polari/protocol/openid-connect/certs
POLARI_KEYCLOAK_ADMIN_URL=http://pol-keycloak:8080
POLARI_KEYCLOAK_REALM=Polari
POLARI_KEYCLOAK_ADMIN_CLIENT_ID=admin-cli
KC_DB_PASSWORD=$kcdb
PSC_DB_PASSWORD=$pscdb
MARIADB_ROOT_PASSWORD=$root
MINIO_ROOT_USER=$muser
MINIO_ROOT_PASSWORD=$mpass
MINIO_ACCESS_KEY=$muser
MINIO_SECRET_KEY=$mpass
DEPLOY_ENV=production
EOF
    chmod 600 "$GEN/.env.prod"
    local demo_enabled=false; [ "$POL_PROD_DEMO" = on ] && demo_enabled=true
    local DEMO="\"demo\": { \"enabled\": $demo_enabled, \"title\": \"Demonstration instance\", \"message\": \"This is a public demonstration of Polari. It exists so you can try the software, not to hold anyone's data.\", \"termsUrl\": \"https://$D/docs/demo-terms.html\", \"version\": \"2026-09-09\" }"
    cat > "$GEN/prf-runtime-config.prod.json" <<EOF
{ "_comment": "PRODUCTION (full): generated by pol prod", "_generated": "$(date -Is)", "_domain": "$D",
  $DEMO,
  "backend":  { "http": { "protocol": "http", "url": "api.prf.$D", "port": "80" }, "https": { "protocol": "https", "url": "api.prf.$D", "port": "443" },
                "ws": { "protocol": "wss", "url": "api.prf.$D", "port": "443" }, "preferHttps": true },
  "frontend": { "http": { "protocol": "http", "url": "prf.$D", "port": "80" }, "https": { "protocol": "https", "url": "prf.$D", "port": "443" } },
  "connection": { "retryInterval": 3000, "maxRetryTime": 60000, "timeout": 30000 },
  "keycloak": { "authority": "https://auth.$D/realms/Polari", "clientId": "polari-frontend", "realm": "Polari", "redirectUri": "https://prf.$D",
                "postLogoutRedirectUri": "https://prf.$D", "responseType": "code", "scope": "openid profile email roles", "silentRedirectUri": "https://prf.$D/silent-refresh.html" },
  "features": { "enableHttps": true, "enableRuntimeConfig": false, "allowBackendChange": false } }
EOF
    cat > "$GEN/psc-runtime-config.prod.json" <<EOF
{ "_comment": "PRODUCTION (full): generated by pol prod", "_generated": "$(date -Is)", "_domain": "$D",
  $DEMO,
  "backendUri": "https://api.psc.$D/", "backendHttpsUri": "https://api.psc.$D/",
  "polariResearchFrameworkUrl": "https://prf.$D", "polariApiUrl": "https://api.prf.$D",
  "keycloak": { "authority": "https://auth.$D/realms/Political-Scorecard", "clientId": "political-scorecard-frontend", "realm": "Political-Scorecard",
                "redirectUri": "https://psc.$D", "postLogoutRedirectUri": "https://psc.$D", "responseType": "code", "scope": "openid profile email roles",
                "silentRedirectUri": "https://psc.$D/silent-refresh.html" } }
EOF
    cat > "$GEN/pol-hub-runtime-config.prod.json" <<EOF
{ "_comment": "PRODUCTION (full): generated by pol prod", "_generated": "$(date -Is)",
  "links": { "prf": "https://prf.$D", "dps": "https://psc.$D", "mesh": "${ISLE_MESH_URL:-https://$D/docs/networking-model.html}", "oseb": "https://$D/docs.html" } }
EOF
    bash "$SCRIPT_DIR/proxy.sh" template prod --domain "$D" --topology swarm >/dev/null || die "proxy template failed"
    [ -s "$SUITE/pol-odoo/odoo.conf" ] || { mkdir -p "$SUITE/pol-odoo"; : ; }
    mkdir -p "$GEN/debs" "$GEN/apt" "$GEN/certbot-www" "$GEN/certs/edge"
    log_success "configs written: .env.prod (credentials kept), prf/psc/pol-hub runtime configs, nginx.prod.conf"
}
issue_cert() {
    load_answers
    [ "$POL_PROD_CERT_MODE" = letsencrypt ] || { log_info "certificate mode is $POL_PROD_CERT_MODE — nothing to issue"; return 0; }
    [ -n "$POL_PROD_LE_EMAIL" ] || die "LE needs an e-mail (POL_PROD_LE_EMAIL)"
    log_info "issuing the Let's Encrypt certificate for $(names "$POL_PROD_DOMAIN") ($POL_PROD_LE_CHALLENGE challenge)"
    LE_CERT_NAME=$(cert_row) LE_DOMAIN="$POL_PROD_DOMAIN" LE_EMAIL="$POL_PROD_LE_EMAIL" LE_CHALLENGE="$POL_PROD_LE_CHALLENGE" \
        LE_WEBROOT="$GEN/certbot-www" DEPLOY_ENV=prod PROD_DOMAIN="$POL_PROD_DOMAIN" BASE_DOMAIN="$POL_PROD_DOMAIN" \
        bash "$CA_DIR/setup-letsencrypt.sh" --non-interactive || die "certificate issue failed — see the certbot output above"
    stage_cert
    # a swarm secret is immutable: rotate by re-deploying the stack with the new files
    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$(stack_name)"; then render_stack; deploy_stack; fi
    bash "$SCRIPT_DIR/cert.sh" auto-renew install >/dev/null 2>&1 || true
    log_success "public certificate in place; weekly auto-renew installed"
}
do_apply() {
    load_answers
    [ "$POL_PROD_ROUTE" = swarm ] || die "route is '$POL_PROD_ROUTE' — pol prod applies the swarm (server) route"
    if [ "${1:-}" != "--yes" ] && [ "$HAS_TUI" = 1 ]; then do_plan; tui_yesno "Apply?" "Proceed with the plan above?" || return 0; fi
    pol_box "pol prod — apply ($(profile) profile)"
    save_answers   # what applied is what later verbs (status/cert/down) act on
    do_check || log_warn "preflight reported problems — continuing (fix and re-run apply; every step is idempotent)"
    if [ "$(profile)" = full ]; then security_setup; write_configs_full; else write_configs; fi
    stage_cert; stage_debs; build_or_pull_images; render_stack; deploy_stack
    # the DAC + MAC controls for this profile (os-security): render always; apply only when asked (root, changes the host)
    local scn; scn=$([ "$(profile)" = full ] && echo swarm-full || echo swarm-lean)
    python3 "$SUITE/os-security/render.py" --scenario "$scn" --apps-from-manifests >/dev/null 2>&1 && log_info "os-security rendered for $scn (POL_PROD_HARDEN=on applies it; pol security os audit scores it)"
    if [ "${POL_PROD_HARDEN:-off}" = on ]; then bash "$SCRIPT_DIR/security.sh" os apply --scenario "$scn" || log_warn "os-security apply reported problems"; fi
    if [ "$POL_PROD_CERT_MODE" = letsencrypt ] && ! edge_cert_is_public; then
        log_info "waiting for the proxy before the HTTP challenge…"; sleep 8; issue_cert
    fi
    do_status
}
do_status() {
    load_answers
    pol_box "pol prod — status"
    echo "  domain       ${POL_PROD_DOMAIN:-?}"
    echo "  profile      $(profile)   stack $(docker stack ls --format '{{.Name}} ({{.Services}} services)' 2>/dev/null | grep "$(stack_name)" || echo "$(stack_name) not deployed")"
    docker stack services "$(stack_name)" --format '  service      {{.Name}}  {{.Replicas}}  {{.Image}}' 2>/dev/null | sed "s/$(stack_name)_//"
    echo "  certificate  $(edge_cert_issuer)  expires $(edge_cert_expiry)  $(edge_cert_is_public && echo 'PUBLICLY TRUSTED' || echo 'NOT public — browsers warn (pol prod cert)')"
    local ip r; ip=$(public_ip); for n in $(names "${POL_PROD_DOMAIN:-x}"); do r=$(resolve "$n" || true); printf "  dns          %-32s %s%s\n" "$n" "${r:-unresolved}" "$([ -n "$ip" ] && [ "$r" = "$ip" ] && echo '  ✓ this host')"; done
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
    render)  if [ "$(profile)" = full ]; then write_configs_full; else write_configs; fi; stage_cert; render_stack ;;
    deploy)  render_stack; deploy_stack ;;
    down)    # remove the answered profile's stack — and any other pol prod stack still up (never leave one behind)
             for st in polari-lean polari-prod; do docker stack ls --format '{{.Name}}' | grep -qx "$st" && { docker stack rm "$st"; log_success "stack $st removed (data volumes kept)"; }; done; true ;;
    bootstrap)
        # a fresh VM (D6): docker, swarm, then the guide
        command -v docker >/dev/null 2>&1 || { log_info "installing docker (get.docker.com)"; curl -fsSL https://get.docker.com | sh; sudo usermod -aG docker "$USER" || true; }
        docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active || docker swarm init --advertise-addr "$(lan_ip)" >/dev/null
        log_success "docker + swarm ready"; do_guide ;;
    help|-h|--help) show_help ;;
    *) die "unknown verb '$COMMAND' — pol prod help" ;;
esac
