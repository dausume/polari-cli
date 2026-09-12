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
#  (credentials: everything generated goes to the root-only encrypted vault — sudo pol security vault show; provider credentials stashed all/some/none by your answer)
#  pol prod tui-install          install the Textual guide (python); guide uses it when present, POL_PROD_TUI=whiptail forces the plain dialogs
#  pol prod log [n]               print the n-th last run log (every run is logged: .generated/prod-log/)
#  pol prod verify [--module m] [--api URL]  after apply: modules/apps set up by every route (console fetch-admit, apps/downloads, interfaces, topology assign)
#  pol prod providers             which providers are in use for what (hosting, DNS, certificate, registry, code) and the pages to visit for each
#  pol prod addresses [--use <ip>|--auto]  every address assigned to this machine (droplet metadata on DigitalOcean); the exposure IP the A records need (detected, or the one you answered)
#  pol prod bootstrap             a fresh VM: install docker, swarm init, then the guide
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
source "$SCRIPT_DIR/lib/providers.sh"
source "$SCRIPT_DIR/lib/vault.sh"
[ -f "${POL_RF_NODE:-$SUITE/polari-rf-node}/security-ledger.sh" ] && source "${POL_RF_NODE:-$SUITE/polari-rf-node}/security-ledger.sh"
source "$SCRIPT_DIR/lib/state.sh"
SUITE="$POL_SUITE_ROOT"
GEN="$SUITE/.generated"
ANSWERS="$GEN/prod-answers.env"
CA_DIR="$SUITE/polari-rf-node/ca"
mkdir -p "$GEN"

# ---------------------------------------------------------------- answers
# defaults → file → env (env wins: the AI/script route)
POL_PROD_ROUTE="${POL_PROD_ROUTE:-}"; POL_PROD_DOMAIN="${POL_PROD_DOMAIN:-}"; POL_PROD_CERT_MODE="${POL_PROD_CERT_MODE:-}"
POL_PROD_LE_CHALLENGE="${POL_PROD_LE_CHALLENGE:-}"; POL_PROD_LE_EMAIL="${POL_PROD_LE_EMAIL:-}"; POL_PROD_AUTH="${POL_PROD_AUTH:-}"; POL_PROD_EXPOSURE_IP="${POL_PROD_EXPOSURE_IP:-}"; POL_PROD_DNS_PROVIDER="${POL_PROD_DNS_PROVIDER:-}"; POL_PROD_STASH="${POL_PROD_STASH:-}"; POL_PROD_WWW="${POL_PROD_WWW:-off}"
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
    : "${POL_PROD_DEMO:=on}"; : "${POL_PROD_IMAGE_TAG:=prod}"; : "${POL_PROD_ODOO:=off}"
}
save_answers() {
    {
        echo "# pol prod answers — $(date -Is). Edit and re-run: pol prod apply. Env vars POL_PROD_* override."
        for k in ROUTE DOMAIN WWW EXPOSURE_IP DNS_PROVIDER STASH CERT_MODE LE_CHALLENGE LE_EMAIL AUTH MODULES DEBS DEMO IMAGE_TAG IMAGE_REPO ODOO; do
            v="POL_PROD_$k"; echo "$v=${!v}"
        done
    } > "$ANSWERS"
    log_success "answers saved: $ANSWERS"
    [ -n "${LOG_FILE:-}" ] && { echo "# answers:"; sed 's/^/#   /' "$ANSWERS"; } >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------- TUI
launch_guide() {  # the Textual guide when a python with textual exists and we have a terminal; else the plain dialogs
    local py
    # stdout is the run-log tee by now; the guide draws on the terminal itself (apply, started by the guide, logs its own run)
    if [ "${POL_PROD_TUI:-}" != whiptail ] && { [ "${HAD_TTY:-0}" = 1 ] || { [ -t 0 ] && [ -t 1 ]; }; } && [ -e /dev/tty ] && py=$(tui_python); then
        log_info "opening the guide (Textual) — POL_PROD_TUI=whiptail for the plain dialogs"
        cd "$SUITE" && PYTHONPATH="$SCRIPT_DIR/../tui${PYTHONPATH:+:$PYTHONPATH}" POL_SUITE_ROOT="$SUITE" exec "$py" -m prodguide </dev/tty >/dev/tty 2>&1
    fi
    [ "${POL_PROD_TUI:-}" = whiptail ] || log_warn "Textual guide not available (pol prod tui-install) — using the plain dialogs"
    do_guide
}
tui_python() {  # a python that can import textual: the venv beside the checkout, else the system python (pip --user)
    local p; for p in "$SUITE/.venv-tui/bin/python" python3; do command -v "$p" >/dev/null 2>&1 && "$p" -c "import textual" >/dev/null 2>&1 && { command -v "$p"; return 0; }; done; return 1
}
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
# ---- addresses: what the internet reaches this machine at ---------------------
# On a DigitalOcean droplet the metadata service (169.254.169.254, no token)
# names every address assigned to the VM: the public IPv4, the public IPv6 when
# enabled, the RESERVED (floating) IP when one is attached, and the private VPC
# address. The exposure address — what the DNS A records must point at — is the
# reserved IP when attached (it survives a droplet rebuild), else the public
# IPv4. Elsewhere: the address the internet sees (ipify) and the LAN address.
_do_meta() { curl -s --max-time 1 "http://169.254.169.254/metadata/v1/$1" 2>/dev/null; }
on_droplet() { [ -n "${_ON_DROPLET+x}" ] || { _ON_DROPLET=$(_do_meta id); export _ON_DROPLET; }; [ -n "$_ON_DROPLET" ]; }
# cached per process: every network probe here costs seconds and the verbs ask several times
server_addresses() { [ -n "${_ADDRS+x}" ] || { _ADDRS=$(_server_addresses_raw); export _ADDRS; }; [ -n "$_ADDRS" ] && printf '%s\n' "$_ADDRS"; }
_server_addresses_raw() {  # prints: role<TAB>address<TAB>note  (roles: reserved public4 public6 private lan)
    if on_droplet; then
        local r4 p4 p6 v; r4=""; p4=$(_do_meta interfaces/public/0/ipv4/address); p6=$(_do_meta interfaces/public/0/ipv6/address); v=$(_do_meta interfaces/private/0/ipv4/address)
        [ "$(_do_meta floating_ip/ipv4/active)" = true ] && r4=$(_do_meta floating_ip/ipv4/ip_address)
        [ -n "$r4" ] && printf 'reserved\t%s\tDigitalOcean reserved IP — attached; survives a rebuild of this droplet: POINT THE A RECORDS HERE\n' "$r4"
        [ -n "$p4" ] && printf 'public4\t%s\tdroplet public IPv4 (region %s, droplet %s)%s\n' "$p4" "$(_do_meta region)" "$(_do_meta id)" "$([ -z "$r4" ] && echo ' — no reserved IP attached: the A records point here, and a rebuilt droplet gets a NEW one')"
        [ -n "$p6" ] && printf 'public6\t%s\tdroplet public IPv6 — add AAAA records only if you want IPv6 visitors (the proxy listens on both)\n' "$p6"
        [ -n "$v" ] && printf 'private\t%s\tVPC address — swarm/peer traffic only, never in DNS\n' "$v"
    else
        local e4 e6; e4=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null || curl -s --max-time 4 https://ifconfig.me 2>/dev/null || true); e6=$(curl -s --max-time 4 https://api6.ipify.org 2>/dev/null || true)
        [ -n "$e4" ] && printf 'public4\t%s\tthe address the internet sees this machine at (behind NAT: forward 80/443 on the router to the LAN address below)\n' "$e4"
        [ -n "$e6" ] && [ "$e6" != "$e4" ] && printf 'public6\t%s\tpublic IPv6 — AAAA records optional\n' "$e6"
        printf 'lan\t%s\tLAN address (swarm advertise address)\n' "$(lan_ip)"
    fi
}
detected_ip() {  # what this machine believes its exposure address is
    server_addresses | awk -F'\t' '$1=="reserved"{print $2; exit} $1=="public4"{p=$2} END{if(p!="")print p}' | head -1
}
exposure_ip() {  # the ONE address the A records must carry: the operator's answer when given, else the detection
    if [ -n "$POL_PROD_EXPOSURE_IP" ]; then echo "$POL_PROD_EXPOSURE_IP"; else detected_ip; fi
}
exposure_source() { [ -n "$POL_PROD_EXPOSURE_IP" ] && echo "answered" || echo "detected"; }
public_ip() { exposure_ip; }
exposure_ip6() { server_addresses | awk -F'\t' '$1=="public6"{print $2; exit}'; }
resolve6() { getent ahostsv6 "$1" 2>/dev/null | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1; exit}'; }
stash_provider() {  # provider key value note — honours POL_PROD_STASH (all|some|none)
    local prov=$1 key=$2 val=$3 note=$4
    [ -n "$val" ] || return 0
    case "${POL_PROD_STASH:-some}" in
        all)  vault_put "provider $prov" "$key" "$val" "$note" && log_success "stashed $key for $(provider_title "$prov") in the vault (sudo pol security vault forget 'provider $prov' removes it)" ;;
        some) if [ "$HAS_TUI" = 1 ]; then tui_yesno "Stash $key?" "Keep the $(provider_title "$prov") $key in the encrypted vault so the next run does not ask? (Advice: your password manager first; forget it from the vault afterwards.)" && vault_put "provider $prov" "$key" "$val" "$note" && log_success "stashed $key"; else log_info "$key not stashed (no terminal to ask; POL_PROD_STASH=all stashes without asking)"; fi ;;
        none) log_info "$key used for this run only (stash policy: none)" ;;
    esac
}
recall_provider() {  # provider key → value from the vault, if stashed
    vault_get "provider $1" "$2" 2>/dev/null || true
}
providers_in_use() {  # role<TAB>provider<TAB>why
    load_answers
    on_droplet && printf 'hosting\tdigitalocean\tthis machine is a DigitalOcean droplet (metadata service answers)\n'
    case "${POL_PROD_DNS_PROVIDER:-}" in
        digitalocean) printf 'dns\tdigitalocean\tthe domain'"'"'s records are managed at DigitalOcean (answered)\n' ;;
        cloudflare)   printf 'dns\tcloudflare\tthe domain'"'"'s records are managed at Cloudflare (answered)\n' ;;
        "")           printf 'dns\tregistrar\tnot answered yet — the registrar'"'"'s DNS page by default (pol prod guide asks)\n' ;;
        *)            printf 'dns\tregistrar\tthe domain'"'"'s records are managed at the registrar (answered)\n' ;;
    esac
    if [ "${POL_PROD_CERT_MODE:-}" = letsencrypt ]; then printf 'certificate\tletsencrypt\tpublicly trusted, %s challenge, contact %s\n' "${POL_PROD_LE_CHALLENGE:-http}" "${POL_PROD_LE_EMAIL:-?}"; else printf 'certificate\tsuite-ca\tself-signed by the suite CA (browsers warn) — pol prod cert switches to Let'"'"'s Encrypt\n'; fi
    case "${POL_PROD_IMAGE_REPO:-}" in ghcr.io/*) printf 'registry\tgithub\timages pulled from %s\n' "$POL_PROD_IMAGE_REPO" ;; "") printf 'registry\tlocal-build\timages built here from the checkout\n' ;; *) printf 'registry\t%s\timages pulled from %s\n' "$POL_PROD_IMAGE_REPO" "$POL_PROD_IMAGE_REPO" ;; esac
    printf 'code\tgithub\tthe suite and every module repo (github.com/dausume)\n'
}
do_providers() {
    pol_box "pol prod — providers in use, and where to go"
    providers_in_use | while IFS=$'\t' read -r role prov why; do
        printf "  %-12s %-52s %s\n" "$role" "$(provider_title "$prov")" "$why"
        provider_links "$prov" | while IFS=$'\t' read -r label url; do printf "  %-12s   · %s\n  %-12s     %s\n" "" "$label" "" "$url"; done
        local c; c=$(provider_credential "$prov"); [ "$c" != none ] && printf "  %-12s   credential: %s\n" "" "$c"
        echo
    done
    echo "  Credentials for these providers are never typed into pol prod except the DNS-challenge token (DO_API_TOKEN, env only)."
    echo "  When the vault exists (prd-9) the guide asks, at the start, whether to stash provider credentials in it — all, some, or none — and advises keeping them elsewhere."
}
do_facts() {  # machine-readable facts for the Textual guide: pol prod facts [--domain D] [--check-image REPO TAG]
    load_answers
    local dom="$POL_PROD_DOMAIN" chk_repo="" chk_tag=""
    while [ $# -gt 0 ]; do case "$1" in --domain) dom=$2; shift 2 ;; --check-image) chk_repo=$2; chk_tag=$3; shift 3 ;; *) shift ;; esac; done
    if [ -n "$chk_repo" ]; then
        docker manifest inspect "${chk_repo}prf-backend:$chk_tag" >/dev/null 2>&1 && echo '{"ok": true}' || echo '{"ok": false}'; return 0
    fi
    local names; names=$(names "${dom:-example.org}")
    POL_PROD_DOMAIN="${dom:-$POL_PROD_DOMAIN}"   # the links and names follow the domain being asked about
    {
        echo "suite=$SUITE"; echo "git=$(git -C "$SUITE" rev-parse --short HEAD 2>/dev/null)"; echo "host=$(hostname)"; echo "user=$(id -un)"
        for k in ROUTE DOMAIN WWW EXPOSURE_IP DNS_PROVIDER STASH CERT_MODE LE_CHALLENGE LE_EMAIL AUTH MODULES DEBS DEMO IMAGE_TAG IMAGE_REPO ODOO; do v="POL_PROD_$k"; echo "answer.$k=${!v}"; done
        echo "on_droplet=$(on_droplet && echo 1 || echo 0)"; echo "detected_ip=$(detected_ip)"; echo "ipv6=$(exposure_ip6)"
        server_addresses | while IFS=$'\t' read -r r a n; do echo "address=$r|$a|$n"; done
        echo "names.lean=$(lean_names "${dom:-example.org}")"; echo "names.full=$(full_names "${dom:-example.org}")"
        for n in $names; do echo "dns=$n|$(resolve "$n" || true)"; done
        name_rows "${dom:-example.org}" | while IFS=$'\t' read -r n k r e; do echo "namerow=$n|$k|$r|$e"; done
        echo "wildcard=$(resolve "polari-probe-$RANDOM.${dom:-example.org}" || true)"
        echo "nameservers=$(domain_nameservers "${dom:-example.org}" | tr '\n' ' ')"
        echo "dns_host_detected=$(dns_host_of "${dom:-example.org}")"
        for prov in digitalocean cloudflare registrar; do echo "dns_page.$prov=$(provider_dns_page "$prov" "${dom:-example.org}")"; provider_dns_howto "$prov" | while IFS=$'\t' read -r u c; do echo "dns_howto.$prov=$u|$c"; done; done
        official_image_sources | while IFS=$'\t' read -r pfx ttl; do echo "source=$pfx|$ttl"; done
        echo "release_tags=$(git -C "$SUITE" tag -l 'polari-v*' 2>/dev/null | sort -r | head -8 | tr '\n' ' ')"
        echo "release_source=$(official_release_sources | head -1 | cut -f1)"
        echo "image_tags=$(official_image_tags | tr '\n' ' ')"
        echo "core_modules=$(python3 -c "import json; r=json.load(open('$SUITE/polari-rf-node/polari-framework/modules/polari-modules.json'))['modules']; print(' '.join(sorted(m for m,e in r.items() if e.get('tier')=='core')))" 2>/dev/null)"
        echo "optional_modules=$(python3 -c "import json; r=json.load(open('$SUITE/polari-rf-node/polari-framework/modules/polari-modules.json'))['modules']; print(' '.join(sorted(m for m,e in r.items() if e.get('tier')!='core')))" 2>/dev/null)"
        release_tags_with_debs "$(official_release_sources | head -1 | cut -f1)" | while IFS=$'\t' read -r t i; do echo "release=$t|$i"; done
        echo "staging_images=$(docker image inspect prf-backend:staging >/dev/null 2>&1 && echo 1 || echo 0)"
        echo "swarm=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo none)"
        for p in 80 443; do echo "port.$p=$(ss -ltn 2>/dev/null | grep -q ":$p " && echo busy || echo free)"; done
        echo "debs_staged=$(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l)"
        echo "piece.isle-mesh=$([ -d "$SUITE/Isle-Mesh/.git" ] || [ -f "$SUITE/Isle-Mesh/.git" ] && echo 1 || echo 0)"; echo "piece.app-shell=$([ -e "$SUITE/polari-app-shell/.git" ] && echo 1 || echo 0)"
        echo "piece.rf-node=$([ -d "$SUITE/polari-rf-node/polari-framework/moduleService" ] && echo 1 || echo 0)"
        echo "mem_total_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
        echo "vault=$(vault_status 2>/dev/null | head -1)"
        if [ -s "$GEN/certs/edge/fullchain.pem" ]; then echo "cert.issuer=$(edge_cert_issuer)"; echo "cert.public=$(edge_cert_is_public && echo 1 || echo 0)"; echo "cert.expiry=$(edge_cert_expiry)"; fi
        providers_in_use | while IFS=$'\t' read -r role prov why; do echo "provider=$role|$prov|$(provider_title "$prov")|$why|$(provider_credential "$prov")"; provider_links "$prov" | while IFS=$'\t' read -r l u; do echo "link=$prov|$l|$u"; done; done
        echo "answers_file=$ANSWERS"; echo "log_dir=$GEN/prod-log"
    } | python3 -c '
import sys, json
out = {"addresses": [], "dns": {}, "sources": [], "providers": [], "links": {}, "answers": {}}
for line in sys.stdin.read().split("\n"):
    if "=" not in line: continue
    k, v = line.split("=", 1)
    if k == "address": r, a, n = v.split("|", 2); out["addresses"].append({"role": r, "address": a, "note": n})
    elif k == "dns": n, a = v.split("|", 1); out["dns"][n] = a
    elif k == "namerow": n, kd, r, e = v.split("|", 3); out.setdefault("name_rows", []).append({"name": n, "kind": kd, "role": r, "enabled_by": e})
    elif k == "source": p, t = v.split("|", 1); out["sources"].append({"prefix": p, "title": t})
    elif k == "provider": role, prov, title, why, cred = v.split("|", 4); out["providers"].append({"role": role, "id": prov, "title": title, "why": why, "credential": cred})
    elif k == "link": prov, l, u = v.split("|", 2); out["links"].setdefault(prov, []).append({"label": l, "url": u})
    elif k.startswith("answer."): out["answers"][k[7:]] = v
    elif k.startswith("names."): out.setdefault("names", {})[k[6:]] = v.split()
    elif k == "release_tags": out[k] = v.split()
    elif k == "image_tags": out[k] = v.split()
    elif k in ("core_modules", "optional_modules"): out[k] = v.split()
    elif k == "nameservers": out[k] = v.split()
    elif k.startswith("dns_page."): out.setdefault("dns_page", {})[k[9:]] = v
    elif k.startswith("dns_howto."): u, c = v.split("|", 1); out.setdefault("dns_howto", {})[k[10:]] = {"url": u, "clicks": c}
    elif k == "release": t, i = v.split("|", 1); out.setdefault("releases", []).append({"tag": t, "info": i})
    else: out[k] = v
print(json.dumps(out, indent=1))'
}
do_verify() {  # pol prod verify [--module <optional module>] — after apply: prove modules and apps can be set up through
               # every route: the console (pol / the API), the apps (App Store + downloads), the interfaces and the topology
    load_answers; set +e   # every check reports; none may abort the run
    local mod="" base; while [ $# -gt 0 ]; do case "$1" in --module) mod=$2; shift 2 ;; --api) base=$2; shift 2 ;; *) shift ;; esac; done
    base="${base:-https://api.prf.$POL_PROD_DOMAIN}"; local front="https://prf.$POL_PROD_DOMAIN" k="-k" pass=0 fail=0
    edge_cert_is_public 2>/dev/null && k=""
    ok(){ pass=$((pass+1)); log_success "$1"; }; bad(){ fail=$((fail+1)); log_error "$1"; }
    j(){ curl -s $k --max-time "${3:-30}" ${2:+-X $2} -H 'Content-Type: application/json' ${4:+-d "$4"} "$base$1"; }
    pol_box "pol prod — verify (modules + apps by every route) @ $base"
    # 0. alive
    [ "$(curl -s $k -o /dev/null -w '%{http_code}' --max-time 15 "$base/api/health")" = 200 ] && ok "API alive: $base/api/health" || { bad "API not answering at $base/api/health"; echo; log_error "verify: $pass passed, $fail failed"; return 1; }
    # 1. the registrar — the unified truth every route reads
    local reg; reg=$(j /api/modules/health?brief=1); local online; online=$(echo "$reg" | python3 -c "import sys,json; d=json.load(sys.stdin); ms=d.get('modules',{}); print(' '.join(m for m,r in ms.items() if r.get('state')=='online'))" 2>/dev/null)
    [ -n "$online" ] && ok "registrar: online → $(echo $online | wc -w) module(s): $(echo $online | cut -c1-90)" || bad "registrar reports no online module"
    # pick an optional module that is NOT online (the fetch path is the point)
    if [ -z "$mod" ]; then for cand in $(python3 -c "import json; r=json.load(open('$SUITE/polari-rf-node/polari-framework/modules/polari-modules.json'))['modules']; print(' '.join(m for m,e in r.items() if e.get('tier')!='core' and not (e.get('requires') or [])))" 2>/dev/null); do case " $online " in *" $cand "*) ;; *) mod=$cand; break ;; esac; done; fi
    [ -n "$mod" ] || { bad "no optional module without dependencies is offline — pass --module <name>"; }
    # 2. CONSOLE route: what `pol project deploy --api` and `pol modules` do — fetch from the module's repository and admit
    if [ -n "$mod" ]; then
        local repo="https://github.com/dausume/polari-module-$mod.git"
        local r; r=$(j "/modules/$mod/fetch-admit" POST 300 "{\"sourceRef\": \"$repo\", \"sourceKind\": \"git\", \"ref\": \"main\", \"installDeps\": true}")
        echo "$r" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok') else 1)" 2>/dev/null && ok "console route: $mod fetched from $repo and admitted (POST /modules/$mod/fetch-admit)" || bad "console route: fetch-admit of $mod failed: $(echo "$r" | cut -c1-200)"
        local st; st=$(j "/api/modules/health?brief=1" | python3 -c "import sys,json; d=json.load(sys.stdin); r=(d.get('modules') or {}).get('$mod') or {}; print(r.get('state','?'), (r.get('error') or '')[:80])" 2>/dev/null)
        case "$st" in online*) ok "registrar after admit: $mod $st" ;; *) bad "registrar after admit: $mod $st" ;; esac
    fi
    # 3. APPS route: the App Store / downloads page — what the store and the isle install from (HTML; a click on an
    #    entry starts the on-demand deb build, so verify only reads the list and never starts one)
    local page; page=$(curl -s $k --max-time 30 "$base/downloads/apps?flavor=online"); local n; n=$(echo "$page" | grep -o "/downloads/apps/status/[a-z_]*" | sort -u | wc -l)
    [ "${n:-0}" -gt 0 ] && ok "apps route: /downloads/apps lists $n installable module(s) (online flavor; offline too)" || bad "apps route: /downloads/apps lists nothing"
    [ -n "$mod" ] && { echo "$page" | grep -q "/downloads/apps/status/$mod" && ok "apps route: $mod is offered on the Download page (its deb is built on demand from the fetched repository when clicked)" || bad "apps route: $mod is not offered on /downloads/apps"; }
    # 4. INTERFACES: the module-health display and the module's own pages exist as rows (the registrar's pages piece), the frontend serves the route
    case "$base" in http://127.0.0.1*|http://localhost*) log_info "interfaces: frontend check skipped (API-only target); on the server it is $front/display/module-health" ;;
        *) [ "$(curl -s $k -o /dev/null -w '%{http_code}' --max-time 15 "$front/display/module-health")" = 200 ] && ok "interfaces: $front/display/module-health served (the module-health display)" || bad "interfaces: $front/display/module-health not served" ;; esac
    local floor_missing=""; for m in $(echo "${POL_PROD_MODULES:-polariapps,appstore,islemesh,terms}" | tr ',' ' '); do case " $online " in *" $m "*) ;; *) floor_missing="$floor_missing $m" ;; esac; done
    [ -z "$floor_missing" ] && ok "interfaces: every answered module is online (${POL_PROD_MODULES:-floor set}) — their displays are seeded rows" || bad "interfaces: answered module(s) not online:$floor_missing"
    # 5. TOPOLOGY: assign the module to this instance as a row (the durable truth POLARI_MODULES derives from)
    local inst; inst=$(j /api/topology/graph | python3 -c "import sys,json; d=json.load(sys.stdin); g=d.get('graph') or d; i=(g.get('instances') or [])
print((i[0].get('name') if i and isinstance(i[0],dict) else (i[0] if i else '')) or '')" 2>/dev/null)
    if [ -n "$inst" ]; then
        local t; t=$(j /api/topology/assign POST 60 "{\"module\": \"${mod:-terms}\", \"to_instance\": \"$inst\"}")
        echo "$t" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('ok', d.get('success', True)) and not d.get('error') else 1)" 2>/dev/null && ok "topology route: POST /api/topology/assign ${mod:-terms} → instance '$inst' (a ModuleAssignment row — the durable truth POLARI_MODULES derives from)" || bad "topology route: assign failed: $(echo "$t" | cut -c1-160)"
    else bad "topology route: no InstanceDefinition row to assign to (GET /api/topology/graph lists none)"; fi
    POLARI_CORE_URL="$base" bash "$SCRIPT_DIR/topology.sh" status >/dev/null 2>&1 && ok "topology route: pol topology status reads the instance over the API (POLARI_CORE_URL=$base)" || bad "topology route: pol topology status could not read $base"
    echo; [ "$fail" = 0 ] && log_success "verify: all $pass checks passed — modules and apps can be set up by console, apps, interfaces and topology" || log_error "verify: $pass passed, $fail failed"
    set -e; [ "$fail" = 0 ]
}
do_addresses() {
    load_answers
    case "${1:-}" in
        --use)  POL_PROD_EXPOSURE_IP="${2:?address}"; save_answers; log_success "exposure address answered: $POL_PROD_EXPOSURE_IP (the DNS check and the certificate use it; --auto returns to detection)" ;;
        --auto) POL_PROD_EXPOSURE_IP=""; save_answers; log_success "exposure address: back to autodetection" ;;
    esac
    pol_box "pol prod — addresses ($(on_droplet && echo 'DigitalOcean droplet, from the metadata service' || echo 'this machine'))"
    server_addresses | while IFS=$'\t' read -r role addr note; do printf "  %-9s %-40s %s\n" "$role" "$addr" "$note"; done
    local x d; x=$(exposure_ip); d=$(detected_ip); echo
    echo "  exposure address: ${x:-unknown} ($(exposure_source)) — every name this server answers for needs an A record → ${x:-?}"
    [ -n "$POL_PROD_EXPOSURE_IP" ] && [ "$POL_PROD_EXPOSURE_IP" != "$d" ] && echo "  detected here:    ${d:-unknown} — differs from the answer; keep the answer if you know the address the world reaches (NAT, a reserved IP, a proxy in front), else: pol prod addresses --auto"
    echo "  change it:        pol prod addresses --use <ip>   (or answer it in pol prod guide)"
    [ -n "$(exposure_ip6)" ] && echo "  IPv6:             $(exposure_ip6) — optional AAAA records"
    if on_droplet; then
        [ -n "$(server_addresses | awk -F'\t' '$1=="reserved"')" ] || log_warn "no reserved IP attached — attach one in the DigitalOcean console (Networking → Reserved IPs) BEFORE pointing DNS, so wiping and rebuilding this droplet never changes the address"
        log_info "DigitalOcean cloud firewall (if one is attached to this droplet) must allow inbound 22, 80, 443 (and 2377/7946/4789 from peers only); ufw on the host is rendered by os-security"
    fi
}
resolve() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'; }
# The names this server answers for follow the ENABLED components (his rule 2026-09-11: a subdomain exists only
# once the service behind it is enabled). name_rows prints: name<TAB>kind<TAB>role<TAB>enabled-by
name_rows() {
    local D=$1; load_answers
    printf '%s\tprimary\tthe site (hub, documentation, downloads)\talways\n' "$D"
    [ "$POL_PROD_WWW" = on ] && printf 'www.%s\tsubdomain\tthe site under the www. convention\twww answer\n' "$D"
    [ "$POL_PROD_AUTH" = keycloak ] && printf 'auth.%s\tsubdomain\tKeycloak (logins)\tlogins = keycloak\n' "$D"
    [ "$POL_PROD_AUTH" = keycloak ] && { printf 'psc.%s\tsubdomain\tthe scorecard frontend\tfull profile\n' "$D"; printf 'api.psc.%s\tsubdomain\tthe scorecard API\tfull profile\n' "$D"; }
    printf 'prf.%s\tsubdomain\tthe Polari frontend\talways\n' "$D"
    printf 'api.prf.%s\tsubdomain\tthe Polari backend API\talways\n' "$D"
    [ "$POL_PROD_AUTH" = keycloak ] && { printf 'files.%s\tsubdomain\tthe file store (web)\tfull profile\n' "$D"; printf 's3.%s\tsubdomain\tthe file store (S3 API)\tfull profile\n' "$D"; }
    [ "$POL_PROD_ODOO" = on ] && printf 'odoo.%s\tsubdomain\tOdoo ERP\todoo = on\n' "$D"
    [ "${POL_PROD_DEBS:-skip}" != skip ] && printf 'apt.%s\tsubdomain\tthe apt repository of installers\tinstallers handed out\n' "$D"
    return 0
}
lean_names() { name_rows "$1" | cut -f1 | tr '\n' ' '; }
full_names() { name_rows "$1" | cut -f1 | tr '\n' ' '; }
profile() { load_answers; [ "$POL_PROD_AUTH" = keycloak ] && echo full || echo lean; }
stack_name() { [ "$(profile)" = full ] && echo polari-prod || echo polari-lean; }
names() { name_rows "$1" | cut -f1 | tr '\n' ' '; }
cert_row() { [ "$(profile)" = full ] && echo pol-proxy-public || echo pol-proxy-lean; }
edge_cert_issuer() { [ -s "$GEN/certs/edge/fullchain.pem" ] && openssl x509 -in "$GEN/certs/edge/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || echo "none"; }
edge_cert_expiry() { [ -s "$GEN/certs/edge/fullchain.pem" ] && openssl x509 -in "$GEN/certs/edge/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "-"; }
edge_cert_is_public() { edge_cert_issuer | grep -qiE "let's encrypt|letsencrypt|R1[0-9]|E[0-9]|ISRG|ZeroSSL|Buypass|DigiCert|Sectigo|GlobalSign|Google Trust"; }
LE_LIVE() { echo "${CERTBOT_CONFIG_DIR:-$CA_DIR/.generated/letsencrypt}/live/${LE_CERT_NAME:-$(cert_row)}"; }

# ---------------------------------------------------------------- guide
do_guide() {
    load_answers
    pol_box "pol prod — production deployment guide"
    tui_msg "Credentials and the vault" "Everything this guide generates (Keycloak admin, database and file-store passwords on the full profile) is written ONCE into an encrypted, root-only vault at /etc/polari/vault and nowhere else you have to protect. Read it later with:  sudo pol security vault show\n\nProvider credentials you give along the way (a DigitalOcean API token for the DNS challenge, a registry pull token) CAN be stashed in the same vault so the next run does not ask again. Advice: record them in your own password manager and remove them from the vault afterwards (sudo pol security vault forget 'provider <name>'). The next question sets the rule; you can still answer per item."
    POL_PROD_STASH=$(tui_menu "Stash provider credentials in the vault?" "Generated Polari credentials are always vaulted. For PROVIDER credentials choose:" "${POL_PROD_STASH:-some}" \
        all "Stash every provider credential I enter (convenient; move them out later)" \
        some "Ask me for each one" \
        none "Never — I keep them myself and re-enter when asked")
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
    POL_PROD_DOMAIN=${POL_PROD_DOMAIN#www.}
    if tui_yesno "www." "Also answer for www.$POL_PROD_DOMAIN? (www is a hostname convention, not a protocol — optional; most sites redirect it to the apex)"; then POL_PROD_WWW=on; else POL_PROD_WWW=off; fi
    local ip; ip=$(public_ip)
    local addrmsg="Addresses assigned to this machine$(on_droplet && echo ' (DigitalOcean droplet, from its metadata)'):\n"
    while IFS=$'\t' read -r role addr note; do addrmsg+="  $role: $addr — $note\n"; done < <(server_addresses)
    addrmsg+="\nThe A records for every name must point at: ${ip:-unknown}"
    on_droplet && [ -z "$(server_addresses | awk -F'\t' '$1=="reserved"')" ] && addrmsg+="\n\nNo reserved IP is attached. Attach one (Networking → Reserved IPs) before setting DNS, so a wiped and rebuilt droplet keeps the same address."
    tui_msg "Addresses" "$(printf "$addrmsg")"
    local ans; ans=$(tui_input "Exposure address" "The address the internet reaches this server at — the DNS A records for every name must carry it. Detected: ${ip:-unknown}. Keep it, or type the address you know is right (a reserved IP, the public side of a NAT, a proxy in front); an address can change, so what you answer here is what the checks and the certificate use:" "${POL_PROD_EXPOSURE_IP:-$ip}")
    if [ -n "$ans" ] && [ "$ans" != "$(detected_ip)" ]; then POL_PROD_EXPOSURE_IP="$ans"; else POL_PROD_EXPOSURE_IP=""; fi
    ip=$(exposure_ip)
    local dnsmsg="POLARI SIDE — the subdomains are defined here by what is enabled; the proxy and the certificate follow them.\nEXTERNAL SIDE — each must resolve through a DNS record at your DNS host: the primary domain's A record, plus ONE wildcard (*.$POL_PROD_DOMAIN → ${ip:-?}) or one A record per subdomain.\n\nNow (exposure address ${ip:-unknown}, $(exposure_source)):\n"
    while IFS=$'\t' read -r n k r e; do dnsmsg+="  $n → $(resolve "$n" || echo unresolved)   [$k: $r; enabled by: $e]\n"; done < <(name_rows "$POL_PROD_DOMAIN")
    local missing=""; while IFS=$'\t' read -r n k r e; do [ "$(resolve "$n" || true)" = "$ip" ] || missing="$missing ${n%%.*}"; done < <(name_rows "$POL_PROD_DOMAIN")
    if [ -n "$missing" ]; then
        dnsmsg+="\nMISSING — add at $(provider_dns_page "$POL_PROD_DNS_PROVIDER" "$POL_PROD_DOMAIN"):\n"
        for h in $missing; do dnsmsg+="  A record  host: $h   value: $ip\n"; done
        dnsmsg+="  (or one wildcard: host: *   value: $ip — covers every subdomain)\n"
        dnsmsg+="How: $(provider_dns_howto "$POL_PROD_DNS_PROVIDER" | cut -f2)\nDocs: $(provider_dns_howto "$POL_PROD_DNS_PROVIDER" | cut -f1)\n"
    fi
    dnsmsg+="\nA provider-issued certificate needs every listed name pointing here first."
    local detected_host; detected_host=$(dns_host_of "$POL_PROD_DOMAIN")
    POL_PROD_DNS_PROVIDER=$(tui_menu "Where are the domain's DNS records managed?" "Detected from the domain's nameservers ($(domain_nameservers "$POL_PROD_DOMAIN" | tr '\n' ' ')): $detected_host. Records must be created there:" "${POL_PROD_DNS_PROVIDER:-$detected_host}" \
        registrar "At the registrar where the domain was bought (most common)" \
        digitalocean "At DigitalOcean (the domain is delegated to DigitalOcean nameservers) — also enables the DNS challenge" \
        cloudflare "At Cloudflare")
    dnsmsg+="\nSet the records at:\n"; while IFS=$'\t' read -r label url; do dnsmsg+="  $label\n    $url\n"; done < <(provider_links "$POL_PROD_DNS_PROVIDER" | head -3)
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
        local lemsg="Let's Encrypt — useful pages:\n"; while IFS=$'\t' read -r label url; do lemsg+="  $label\n    $url\n"; done < <(provider_links letsencrypt); tui_msg "Let's Encrypt" "$(printf "$lemsg")"
        [ "$POL_PROD_LE_CHALLENGE" = dns ] && tui_msg "DigitalOcean API token" "The DNS challenge needs a DigitalOcean API token with DNS write scope. Create it here and export DO_API_TOKEN in the shell that runs pol prod apply — it is never written into the answers:\n  $(provider_links digitalocean | awk -F'\t' '/API tokens/{print $2}')"
    fi
    POL_PROD_AUTH=$(tui_menu "User logins" "Keycloak handles authentication and user login: accounts, passwords and sign-in, and access control per user (who may see and change what). It is the default; with it the server also runs the scorecard and the file store, and its admin password is generated and kept in the vault. Without logins there are no accounts: anyone can browse, nothing is protected per user — fine for a plain distribution or demonstration server, about 1 GB lighter." "$POL_PROD_AUTH" \
        keycloak "User logins with Keycloak — accounts, sign-in, per-user security and access control (default)" \
        off      "No user logins — open to everyone, no accounts (smaller: no Keycloak, scorecard or file store)")
    # Odoo is an add-on installed after the initial deployment (POL_PROD_ODOO=on pol prod apply), not a first-run question
    POL_PROD_MODULES=$(tui_input "Modules" "The floor set the server boots (comma-separated; more = more memory):" "$POL_PROD_MODULES")
    # Installers: skip | a PUBLISHED release (our official source, listed) | build here | manual pool (dir, release URL, github:owner/repo@tag)
    local ditems=(skip "Skip for now (the Download page lists nothing)") drel dtag dinfo
    while IFS=$'\t' read -r dtag dinfo; do [ -n "$dtag" ] && ditems+=("release:$dtag" "Official release $dtag — $dinfo (github.com/$(official_release_sources | head -1 | cut -f1))"); done < <(release_tags_with_debs "$(official_release_sources | head -1 | cut -f1)")
    [ ${#ditems[@]} -eq 2 ] && ditems+=(none "(no official release with installers is published yet)")
    ditems+=(build "Build them on this machine now (needs the Isle-Mesh + app-shell pieces and the toolchain; minutes)")
    ditems+=(manual "Another pool: a directory, a GitHub release page URL, or github:<owner/repo>@<tag>")
    POL_PROD_DEBS=$(tui_menu "Installers to hand out" "The site's Download page serves the platform debs staged in .generated/debs. Installers should be RELEASE ARTIFACTS: built once, published, fetched here." "${POL_PROD_DEBS:-skip}" "${ditems[@]}")
    case "$POL_PROD_DEBS" in
        none) POL_PROD_DEBS=skip ;;
        manual) drel=$(tui_input "Release pool" "A directory holding the debs, a release page URL (https://github.com/<owner>/<repo>/releases/tag/<tag>), or github:<owner/repo>@<tag>:" ""); case "$drel" in "") POL_PROD_DEBS=skip ;; http*|github:*) POL_PROD_DEBS="copy:$drel" ;; *) POL_PROD_DEBS="copy:$drel" ;; esac ;;
    esac
    if tui_yesno "Demonstration notice" "Show the 'demonstration instance — no personal information' notice and terms gate on the apps? (Answer No for a plain distribution server.)"; then POL_PROD_DEMO=on; else POL_PROD_DEMO=off; fi
    # Images: ONE choice that sets registry + tag together (they must match; no free-text tag)
    local items=() src cur="custom"
    [ -z "$POL_PROD_IMAGE_REPO" ] && [ "$POL_PROD_IMAGE_TAG" = staging ] && cur="staging"; [ -z "$POL_PROD_IMAGE_REPO" ] && [ "$POL_PROD_IMAGE_TAG" = prod ] && [ -n "$(grep -s '^POL_PROD_IMAGE_TAG=' "$ANSWERS")" ] && cur="build"
    local t; for t in $(git -C "$SUITE" tag -l 'polari-v*' 2>/dev/null | sort -r | head -5); do items+=("$t" "Pull the release $t from the official registry ghcr.io/dausume/"); done
    items+=(custom "Pull published images from a registry: one of our official sources or one you type — then a tag (default)")
    items+=(build "Build the images on this machine from this checkout → tag 'prod' (needs ~3 GB RAM, 5–15 min)")
    docker image inspect prf-backend:staging >/dev/null 2>&1 && items+=(staging "Use the 'staging' images already present on this machine (a dev/staging box)")
    src=$(tui_menu "Where do the images come from?" "Backend + frontend images for this deployment. Building here is the default; releases are pulled by tag." "$cur" "${items[@]}")
    case "$src" in
        build)   POL_PROD_IMAGE_REPO=""; POL_PROD_IMAGE_TAG="prod" ;;
        staging) POL_PROD_IMAGE_REPO=""; POL_PROD_IMAGE_TAG="staging" ;;
        custom)  # the source first: our official sources as a list, then a manual entry
                 local srcs=() line pfx ttl
                 while IFS=$'\t' read -r pfx ttl; do srcs+=("$pfx" "official: $ttl"); done < <(official_image_sources)
                 srcs+=(manual "Type a registry prefix myself — example: registry.example.org/polari/")
                 pfx=$(tui_menu "Pull images from which source?" "The images are pulled from ONE registry prefix; every image name is appended to it (prefix + prf-backend:tag)." "${POL_PROD_IMAGE_REPO:-$(official_image_sources | head -1 | cut -f1)}" "${srcs[@]}")
                 if [ "$pfx" = manual ]; then pfx=$(tui_input "Registry prefix" "Registry + namespace, ending in a slash — example: ghcr.io/dausume/  or  registry.example.org/polari/" "${POL_PROD_IMAGE_REPO:-}"); fi
                 POL_PROD_IMAGE_REPO="$pfx"
                 case "$POL_PROD_IMAGE_REPO" in */) ;; "") die "a registry prefix is required for a pull" ;; *) POL_PROD_IMAGE_REPO="$POL_PROD_IMAGE_REPO/" ;; esac
                 local tagitems=() tg; if [ "$pfx" != manual ]; then while read -r tg; do [ -n "$tg" ] && tagitems+=("$tg" "$(case "$tg" in polari-v*) echo 'release';; staging|prod|latest) echo 'moving tier tag';; *) echo '';; esac)"); done < <(registry_image_tags "$POL_PROD_IMAGE_REPO" prf-backend); fi
                 if [ ${#tagitems[@]} -gt 0 ]; then
                     tagitems+=(other "Another tag (type it)")
                     POL_PROD_IMAGE_TAG=$(tui_menu "Image tag" "Tags this registry actually has for prf-backend (valid by construction):" "${POL_PROD_IMAGE_TAG:-${tagitems[0]}}" "${tagitems[@]}")
                     [ "$POL_PROD_IMAGE_TAG" = other ] && POL_PROD_IMAGE_TAG=$(tui_input "Image tag" "The tag every image is pulled at:" "")
                 else
                     [ "$pfx" != manual ] && tui_msg "No images published" "$POL_PROD_IMAGE_REPO has no prf-backend image yet (nothing published, or not public). You can type a tag, but the pull will fail until images are published — building here is the alternative."
                     POL_PROD_IMAGE_TAG=$(tui_input "Image tag" "The tag every image is pulled at — example: polari-v2026.09.11 (a release) or staging (the moving tier tag)" "${POL_PROD_IMAGE_TAG:-}")
                 fi
                 [ -n "$POL_PROD_IMAGE_TAG" ] && [ "$POL_PROD_IMAGE_TAG" != prod ] || die "a tag is required (prod is reserved for images built here)" ;;
        polari-v*) POL_PROD_IMAGE_REPO="$(official_image_sources | head -1 | cut -f1)"; POL_PROD_IMAGE_TAG="$src" ;;
    esac
    if [ -n "$POL_PROD_IMAGE_REPO" ]; then
        docker manifest inspect "${POL_PROD_IMAGE_REPO}prf-backend:$POL_PROD_IMAGE_TAG" >/dev/null 2>&1 && log_success "registry has ${POL_PROD_IMAGE_REPO}prf-backend:$POL_PROD_IMAGE_TAG" \
            || { tui_msg "Not found" "${POL_PROD_IMAGE_REPO}prf-backend:$POL_PROD_IMAGE_TAG is not reachable from here (not published, private, or a typo). Choose again."; POL_PROD_IMAGE_REPO=""; POL_PROD_IMAGE_TAG="prod"; tui_msg "Images" "Falling back to: build on this machine (tag prod)."; }
    fi
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
    if [ -n "$POL_PROD_IMAGE_REPO" ]; then echo "  images       PULL from $POL_PROD_IMAGE_REPO ($(image_source_title "$POL_PROD_IMAGE_REPO")) at tag $POL_PROD_IMAGE_TAG"; else echo "  images       BUILD on this machine from this checkout, tagged $POL_PROD_IMAGE_TAG"; fi
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
        local ip ip6 ours; ip=$(public_ip); ip6=$(exposure_ip6); ours="$ip $(server_addresses | awk -F'\t' '$1=="reserved"||$1=="public4"{print $2}' | tr '\n' ' ')"; local bad=0
        log_info "exposure address ${ip:-unknown} ($(exposure_source)$(on_droplet && echo ', droplet'))$([ -n "$ip6" ] && echo ", IPv6 $ip6")"
        for n in $(names "$POL_PROD_DOMAIN"); do r=$(resolve "$n" || true); if [ -n "$r" ] && [[ " $ours " == *" $r "* ]]; then log_success "DNS $n → $r$([ "$r" != "$ip" ] && echo ' (droplet public IPv4; a reserved IP is attached — prefer it)')"; else log_warn "DNS $n → ${r:-unresolved} (this host: ${ip:-unknown})"; bad=1; fi
            if [ -n "$ip6" ]; then r6=$(resolve6 "$n" || true); [ -n "$r6" ] && [ "$r6" != "$ip6" ] && log_warn "AAAA $n → $r6 but this host's IPv6 is $ip6 (a wrong AAAA record breaks IPv6 visitors and the HTTP challenge)"; fi; done
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
POLARI_IMAGE_REPO=$POL_PROD_IMAGE_REPO
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
        release:*|github:*|copy:github:*|copy:https://github.com/*)
            # a published GitHub release is the release pool: release:<tag> (the official source), github:<owner/repo>@<tag>,
            # or a release page URL https://github.com/<owner>/<repo>/releases/tag/<tag>
            local ref=${POL_PROD_DEBS#copy:} repo tag
            case "$ref" in
                release:*) repo=$(official_release_sources | head -1 | cut -f1); tag=${ref#release:} ;;
                github:*)  ref=${ref#github:}; repo=${ref%@*}; tag=${ref##*@} ;;
                https://github.com/*) repo=$(echo "$ref" | sed -E 's|https://github.com/([^/]+/[^/]+)/releases/tag/(.+)|\1|'); tag=$(echo "$ref" | sed -E 's|.*/releases/tag/||') ;;
            esac
            log_info "fetching the installers of release $tag from github.com/$repo (a published release is the pool)"
            local urls; urls=$(release_deb_urls "$repo" "$tag"); [ -n "$urls" ] || die "release $tag of $repo carries no .deb assets (or does not exist)"
            rm -f "$GEN"/debs/*.deb; for u in $urls; do curl -fsSL --max-time 600 -o "$GEN/debs/$(basename "$u")" "$u" && log_success "fetched $(basename "$u")" || log_warn "failed: $u"; done ;;
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
        log_info "pulling images from $POL_PROD_IMAGE_REPO ($(image_source_title "$POL_PROD_IMAGE_REPO")), tag $POL_PROD_IMAGE_TAG: ${POL_PROD_IMAGE_REPO}prf-backend:$POL_PROD_IMAGE_TAG, ${POL_PROD_IMAGE_REPO}prf-frontend:$POL_PROD_IMAGE_TAG"
        docker compose -f "$(compose_file)" --env-file "$(env_file)" pull --ignore-buildable 2>&1 | tail -3 || die "pull failed"
        local imgs="prf-backend prf-frontend pol-hub"; [ "$(profile)" = full ] && imgs="$imgs pol-mariadb pol-file-store psc-redis pol-keycloak psc-frontend psc-backend"; [ "$(profile)" = full ] && [ "$POL_PROD_ODOO" = on ] && imgs="$imgs pol-odoo pol-odoo-postgres"
        for img in $imgs; do docker image inspect "${POL_PROD_IMAGE_REPO}$img:$POL_PROD_IMAGE_TAG" >/dev/null 2>&1 && log_success "pulled ${POL_PROD_IMAGE_REPO}$img:$POL_PROD_IMAGE_TAG" || die "${POL_PROD_IMAGE_REPO}$img:$POL_PROD_IMAGE_TAG did not pull — is it published and public?"; done
        return 0   # the hub comes from the registry too — nothing to build
    else
        # the lean/prod compose files carry no build: (swarm-first rule) — the prf images are built from the
        # node's own staging definitions (context, dockerfile, args), then tagged for this profile
        build_prf_images
    fi
    build_hub
}
prf_build_spec() {  # service → "context<TAB>dockerfile<TAB>arg=val …" from polari-rf-node/docker-compose.staging-nip.yml
    python3 - "$SUITE/polari-rf-node/docker-compose.staging-nip.yml" "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])); svc = doc['services'][sys.argv[2]]; b = svc.get('build') or {}
ctx = b if isinstance(b, str) else b.get('context', '.'); df = '' if isinstance(b, str) else b.get('dockerfile', '')
args = {} if isinstance(b, str) else (b.get('args') or {})
print(ctx, df, ' '.join('%s=%s' % kv for kv in args.items()), sep='\t')
PY
}
build_prf_images() {
    local RF="$SUITE/polari-rf-node" tag="$POL_PROD_IMAGE_TAG" svc img spec ctx df args a
    [ -d "$RF/polari-framework" ] && [ -d "$RF/polari-platform-angular" ] || die "polari-rf-node pieces are missing (get-polari.sh pulls them) — or answer an image registry to pull instead of building"
    log_warn "building the two Polari images on THIS machine — the frontend build needs ~3 GB of memory and 5–15 minutes; a registry answer (pol prod guide → Images) pulls them instead"
    for svc in backend frontend; do
        img="prf-$svc:$tag"
        spec=$(prf_build_spec "$svc") || die "no build definition for $svc in docker-compose.staging-nip.yml"
        ctx=$(echo "$spec" | cut -f1); df=$(echo "$spec" | cut -f2); args=$(echo "$spec" | cut -f3)
        local extra=(); [ -n "$df" ] && extra+=(-f "$RF/$ctx/$df"); for a in $args; do extra+=(--build-arg "$a"); done
        log_info "docker build -t $img ${extra[*]} $RF/$ctx"
        docker build -t "$img" "${extra[@]}" "$RF/$ctx" 2>&1 | grep -E "^#[0-9]+ (naming|ERROR)|^ERROR|error:" | tail -8
        docker image inspect "$img" >/dev/null 2>&1 && log_success "image $img built" || die "image $img did not build — see the lines above (memory? run: free -h)"
    done
}
deploy_stack() {
    load_answers
    [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = active ] || { log_info "docker swarm init (advertise $(lan_ip))"; docker swarm init --advertise-addr "$(lan_ip)" >/dev/null || die "docker swarm init failed — run it by hand: docker swarm init --advertise-addr <this machine's address>"; }
    set -a; source "$(env_file)"; set +a
    local wra=(); [ -n "$POL_PROD_IMAGE_REPO" ] && wra+=(--with-registry-auth)
    docker stack deploy "${wra[@]}" -c "$GEN/stack-$(role).yml" "$(stack_name)"
    record_build swarm "$(role)" production
    log_success "stack $(stack_name) deployed (pol prod status)"
}
security_setup() {
    # the full profile's CA + Keycloak + DB/MinIO credentials — generated once, never weak defaults
    load_answers
    # placeholder-bearing credential files count as MISSING (today's finding: the old skip-if-exists kept public
    # placeholders alive); they are moved aside, never silently reused. A fresh DB volume is then required.
    local f stale=""
    for f in "$SUITE/pol-keycloak/keycloak-admin.env" "$SUITE/pol-mariadb/mariadb.env" "$SUITE/pol-file-store/minio.env" "$SUITE/pol-file-store/client.env"; do
        [ -s "$f" ] && [ "$(sec_placeholders "$f" 2>/dev/null || echo 0)" -gt 0 ] && stale="$stale $f"   # the ledger's rule (security-ledger.sh)
    done
    if [ -n "$stale" ]; then
        local dir="$GEN/stale-creds/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$dir"
        for f in $stale; do mv "$f" "$dir/"; done
        log_warn "credential file(s) with PLACEHOLDER values moved to $dir — fresh credentials will be generated; a database volume created with the old values must be recreated (pol prod down; docker volume rm …)"
    fi
    if [ -s "$SUITE/pol-proxy/certs/ca/pol-ca.crt" ] && [ -s "$SUITE/pol-keycloak/keycloak-admin.env" ] && [ -s "$SUITE/pol-mariadb/mariadb.env" ]; then
        log_success "security material present (CA, Keycloak admin, DB/MinIO credentials) — pol security rotate prod to renew"; vault_generated; return 0
    fi
    log_info "security setup (CA, Keycloak certs + admin, DB/MinIO credentials) — non-interactive, random passwords"
    local pw; pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
    POLARI_CONFIRM_PROD=yes POLARI_SERVER_IP="${POLARI_SERVER_IP:-$(public_ip)}" POLARI_PROD_DOMAIN="$POL_PROD_DOMAIN" \
        POLARI_KC_ADMIN_USER="${POLARI_KC_ADMIN_USER:-admin}" POLARI_KC_ADMIN_PASS="${POLARI_KC_ADMIN_PASS:-$(pw)}" \
        POLARI_MYSQL_ROOT_PASS="${POLARI_MYSQL_ROOT_PASS:-$(pw)}" POLARI_KC_DB_PASS="${POLARI_KC_DB_PASS:-$(pw)}" POLARI_PSC_DB_PASS="${POLARI_PSC_DB_PASS:-$(pw)}" \
        POLARI_MINIO_ROOT_USER="${POLARI_MINIO_ROOT_USER:-polari-admin}" POLARI_MINIO_ROOT_PASS="${POLARI_MINIO_ROOT_PASS:-$(pw)}" \
        bash "$SUITE/setup-polari-security.sh" prod >"$GEN/security-setup.log" 2>&1 || { tail -20 "$GEN/security-setup.log" >&2; die "security setup failed (log: .generated/security-setup.log)"; }
    log_success "security material generated (log: .generated/security-setup.log)"
    vault_generated
}
vault_generated() {  # every generated credential → the vault, section [polari <domain>] (idempotent: same key = replaced)
    load_answers; local sec="polari ${POL_PROD_DOMAIN:-local}" f k v n=0
    while IFS='|' read -r f k note; do
        [ -s "$SUITE/$f" ] || continue
        v=$(grep -s "^$k=" "$SUITE/$f" | head -1 | cut -d= -f2- | sed -e "s/^[\"']//" -e "s/[\"']\$//"); [ -n "$v" ] || continue
        vault_put "$sec" "$k" "$v" "$note (from $f)" && n=$((n+1))
    done <<'LIST'
pol-keycloak/keycloak-admin.env|KEYCLOAK_ADMIN|Keycloak admin user (auth.<domain>)
pol-keycloak/keycloak-admin.env|KEYCLOAK_ADMIN_PASSWORD|Keycloak admin password
pol-keycloak/keycloak-admin.env|KEYCLOAK_POLARI_BACKEND_CLIENT_SECRET|Keycloak client secret for the Polari backend
pol-mariadb/mariadb.env|MARIADB_ROOT_PASSWORD|MariaDB root
pol-mariadb/mariadb.env|KC_DB_PASSWORD|Keycloak database user
pol-mariadb/mariadb.env|PSC_DB_PASSWORD|Scorecard database user
pol-file-store/minio.env|MINIO_ROOT_USER|MinIO (file store) root user
pol-file-store/minio.env|MINIO_ROOT_PASSWORD|MinIO root password
pol-file-store/client.env|MINIO_ACCESS_KEY|MinIO client access key
pol-file-store/client.env|MINIO_SECRET_KEY|MinIO client secret key
LIST
    [ "$n" -gt 0 ] && log_success "$n generated credential(s) recorded in the vault ($VAULT_FILE) — sudo pol security vault show" || true
}
vault_prompt() {  # the end-of-apply choice (TUI only; unattended keeps)
    vault_exists || return 0
    [ "$HAS_TUI" = 1 ] || { log_info "$(vault_status | head -1)"; return 0; }
    local c; c=$(tui_menu "The credential vault" "Generated credentials are in the encrypted, root-only vault:\n  $VAULT_FILE\nWhat do you want to do with it?" keep \
        keep   "Keep it here — read later with: sudo pol security vault show" \
        show   "Show everything NOW, once, so I can write it down / put it in a password manager — then SHRED the vault" \
        export "Export the vault (+ its key, kept apart) to a path I choose, then shred the local copy")
    case "$c" in
        show)   echo; vault_show; echo; tui_yesno "Shred now?" "Have you recorded every value above? The vault will be shredded and nothing recoverable stays on this machine." && vault_shred || log_info "kept" ;;
        export) local dst; dst=$(tui_input "Export to" "Path for the exported vault (a USB stick, a mounted share):" "$HOME/polari-vault-$(date -u +%F).enc"); vault_export "$dst" && tui_yesno "Shred the local copy?" "Exported to $dst (and $dst.identity). Shred the local vault now?" && vault_shred || true ;;
        *)      log_info "vault kept: sudo pol security vault show" ;;
    esac
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
    if [ "$POL_PROD_LE_CHALLENGE" = dns ]; then
        if [ -n "${DO_API_TOKEN:-}" ]; then stash_provider digitalocean DO_API_TOKEN "$DO_API_TOKEN" "DNS-challenge token (DNS write scope)"
        else DO_API_TOKEN=$(recall_provider digitalocean DO_API_TOKEN); [ -n "$DO_API_TOKEN" ] && { export DO_API_TOKEN; log_info "DigitalOcean API token taken from the vault (stashed earlier)"; } || die "the DNS challenge needs DO_API_TOKEN in the environment (create one: $(provider_links digitalocean | awk -F'\t' '/API tokens/{print $2}'))"; fi
    fi
    log_info "issuing the Let's Encrypt certificate for $(names "$POL_PROD_DOMAIN") ($POL_PROD_LE_CHALLENGE challenge)"
    LE_SANS="$(names "$POL_PROD_DOMAIN" | tr ' ' ',' | sed 's/,$//')" \
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
    [ "${1:-}" = "--yes" ] || vault_prompt
}
do_status() {
    load_answers
    pol_box "pol prod — status"
    echo "  domain       ${POL_PROD_DOMAIN:-?}"
    echo "  profile      $(profile)   stack $(docker stack ls --format '{{.Name}} ({{.Services}} services)' 2>/dev/null | grep "$(stack_name)" || echo "$(stack_name) not deployed")"
    docker stack services "$(stack_name)" --format '  service      {{.Name}}  {{.Replicas}}  {{.Image}}' 2>/dev/null | sed "s/$(stack_name)_//"
    echo "  certificate  $(edge_cert_issuer)  expires $(edge_cert_expiry)  $(edge_cert_is_public && echo 'PUBLICLY TRUSTED' || echo 'NOT public — browsers warn (pol prod cert)')"
    local ip r; ip=$(public_ip); for n in $(names "${POL_PROD_DOMAIN:-x}"); do r=$(resolve "$n" || true); printf "  dns          %-32s %s%s\n" "$n" "${r:-unresolved}" "$([ -n "$ip" ] && [ "$r" = "$ip" ] && echo "  ✓ exposure address ($(exposure_source))")"; done
    echo "  installers   $(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l) staged (https://${POL_PROD_DOMAIN:-…}/downloads)   apt tree: $([ -d "$GEN/apt/dists" ] && echo present || echo 'not published')"
    local h; h=$(curl -sk --max-time 5 -H "Host: api.prf.${POL_PROD_DOMAIN:-x}" https://127.0.0.1/api/health 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('phase'), '—', d.get('onlineCount'), '/', d.get('moduleCount'), 'modules online')" 2>/dev/null || echo "not answering yet")
    echo "  backend      $h"
    local t; t=$(curl -sk --max-time 5 -H "Host: api.prf.${POL_PROD_DOMAIN:-x}" "https://127.0.0.1/api/terms/active" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('terms gate on' if d.get('pending') else 'no terms gate', '· demo bar', 'on' if d.get('show_bar') else 'off')" 2>/dev/null || echo "-")
    echo "  terms        $t"
    echo "  vault        $(vault_status | head -1 | sed 's/^vault: //')$([ -n "$POL_PROD_STASH" ] && echo " · provider stash policy: $POL_PROD_STASH")"
    local nxt=""; edge_cert_is_public || nxt="pol prod cert (public certificate) · "; [ "$(ls "$GEN"/debs/*.deb 2>/dev/null | wc -l)" -gt 0 ] || nxt="${nxt}pol prod debs build · "
    echo "  next         ${nxt}pol prod status"
}

# ---------------------------------------------------------------- dispatch
show_help() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }
COMMAND=${1:-guide}; shift || true
# every run is logged in full (stdout+stderr, the TUI's answers, every step) so it can be reviewed afterwards:
#   pol prod log            the last run      pol prod log 3      the third-last      ls .generated/prod-log/
LOG_DIR="$GEN/prod-log"; mkdir -p "$LOG_DIR" 2>/dev/null || true
case "$COMMAND" in
    log) n=${1:-1}; f=$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | sed -n "${n}p"); [ -n "$f" ] || { echo "no runs logged yet ($LOG_DIR)"; exit 0; }; echo "== $f"; sed 's/\x1b\[[0-9;]*m//g' "$f"; exit 0 ;;
    help|-h|--help|facts) ;;
    *) HAD_TTY=0; [ -t 0 ] && [ -t 1 ] && HAD_TTY=1   # remembered before stdout becomes the tee pipe
       if [ -d "$LOG_DIR" ]; then LOG_FILE="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$COMMAND.log"; { echo "# pol prod $COMMAND $* — $(date -u +%FT%TZ) on $(hostname) as $(id -un) — $(git -C "$SUITE" rev-parse --short HEAD 2>/dev/null)"; } > "$LOG_FILE"; exec > >(tee -a "$LOG_FILE") 2>&1; fi ;;
esac
case "$COMMAND" in
    guide)   launch_guide ;;
    tui|tui-install)  # the Python TUI (Textual): user-level pip install, else a venv beside the checkout
             if py=$(tui_python); then log_success "Textual guide available ($py)"; exit 0; fi
             log_info "installing Textual (pip --user, else a venv at $SUITE/.venv-tui)"
             python3 -m pip install --user -q textual 2>/dev/null || python3 -m pip install --user -q --break-system-packages textual 2>/dev/null \
               || { apt-get install -y -qq python3-venv >/dev/null 2>&1 || sudo apt-get install -y -qq python3-venv >/dev/null 2>&1; python3 -m venv "$SUITE/.venv-tui" && "$SUITE/.venv-tui/bin/pip" install -q textual; }
             py=$(tui_python) && log_success "Textual guide available ($py)" || die "could not install Textual — the guide falls back to the plain dialogs (whiptail)" ;;
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
    addresses) do_addresses "$@" ;;
    verify)    do_verify "$@" ;;
    facts)     do_facts "$@" ;;
    providers) do_providers ;;
    bootstrap)
        # a fresh VM (D6): docker, swarm, then the guide
        command -v docker >/dev/null 2>&1 || { log_info "installing docker (get.docker.com, else Ubuntu's docker.io)"; ( curl -fsSL https://get.docker.com | sh ) || { apt-get install -y -qq docker.io docker-compose-v2 docker-buildx && systemctl enable --now docker; }; [ "$(id -u)" = 0 ] || sudo usermod -aG docker "$USER" || true; }
        [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = active ] || { docker swarm init --advertise-addr "$(lan_ip)" >/dev/null || die "docker swarm init failed — run it by hand: docker swarm init --advertise-addr <this machine's address>"; }
        log_success "docker + swarm ready ($(docker info --format '{{.Swarm.LocalNodeState}}'))"; launch_guide ;;
    help|-h|--help) show_help ;;
    *) die "unknown verb '$COMMAND' — pol prod help" ;;
esac
