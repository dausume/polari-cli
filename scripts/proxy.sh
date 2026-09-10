#!/bin/bash
# pol proxy — nginx proxy config generation (bld-4; replaces the sed
# .template path). Annotated sources: pol-services/proxy/ (suite + rf).
# Pipeline: render (jinja, LOCAL_IP baked at render time) -> check
# (nginx -t inside a throwaway container — isle-mesh merge-configs idiom)
# -> promote (into .generated/, where the proxy containers mount from).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol proxy — generated nginx configs"
    echo -e "
${BOLD}COMMANDS${NC}   (--project suite|node|all, default all)
  ${CYAN}render${NC}      render proxy configs into jinja-build/.generated/
              (staging always; rf prod additionally needs
              POLARI_PROD_DOMAIN exported — refuses without it)
  ${CYAN}check${NC}       validate rendered configs with nginx -t in a
              throwaway nginx:alpine container
  ${CYAN}mode${NC}        which nginx world THIS machine is in: isle (the isle
              agent's nginx, generated from its registry — untouched by
              the suite) or suite (pol-proxy, one template per env)
  ${CYAN}template${NC} <env> [--domain D] [--topology single|swarm]
              render pol-proxy/nginx.<env>.conf.template (staging|prod|lean)
              into .generated/nginx.<env>.conf — the file the compose AND
              the swarm stack use. Refuses static upstream{} blocks: the
              one config must boot before every service exists (swarm)
  ${CYAN}guard${NC} <env>  nginx -t the rendered .generated/nginx.<env>.conf with
              the edge cert + CA mounted and every service name stubbed
  ${CYAN}promote${NC}     copy rendered configs into .generated/ (live mount
              points of pol-proxy / prf-proxy; restart proxies to apply)
  ${CYAN}status${NC}      rendered vs promoted state

The old path (sed on *.template in the setup scripts) still works and
produces identical bytes — it is retired once this path owns prod too.
"
}

PROJECT="all"
ARGS=()
while [ $# -gt 0 ]; do case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
esac; done
set -- "${ARGS[@]}"
COMMAND=$1; shift || true

do_render() {
    if [ "$PROJECT" != "node" ]; then
        log_info "suite proxies:"
        python3 "$POL_SUITE_ROOT/pol-build/render.py" "$POL_SUITE_ROOT" \
            --manifest "$POL_SUITE_ROOT/pol-build/manifests/proxies.yml"
    fi
    if [ "$PROJECT" != "suite" ]; then
        log_info "rf-node proxies:"
        python3 "$POL_SUITE_ROOT/pol-build/render.py" "$POL_RF_NODE" \
            --manifest "$POL_SUITE_ROOT/pol-build/manifests/node-proxies.yml"
        if [ -n "${POLARI_PROD_DOMAIN:-}" ]; then
            python3 "$POL_SUITE_ROOT/pol-build/render.py" "$POL_RF_NODE" \
                --manifest "$POL_SUITE_ROOT/pol-build/manifests/node-proxies-prod.yml"
        else
            log_warn "rf prod proxy skipped — export POLARI_PROD_DOMAIN=<domain> to render it"
        fi
    fi
}

check_one() {
    # nginx -t in a throwaway container, with the SAME cert mounts the real
    # proxy container gets (the confs reference those paths). Missing cert
    # dirs => honest pointer at the security setup.
    local conf=$1 certs_dir=$2
    [ -f "$conf" ] || { log_warn "not rendered: $conf — run: pol proxy render"; return 1; }
    [ -d "$certs_dir" ] || { log_warn "certs missing ($certs_dir) — run: pol security setup (certs feed the TLS server blocks)"; return 1; }
    # nginx resolves proxy_pass hostnames at parse time — stub every
    # service name in the conf so validation works with the stack down.
    local hosts
    hosts=$(grep -oE '(proxy_pass https?://|server[[:space:]]+)[a-z0-9-]+' "$conf" \
        | sed -E 's#.*(//|[[:space:]])##' | sort -u | sed 's/^/--add-host /;s/$/:127.0.0.1/')
    local out
    # shellcheck disable=SC2086
    out=$(docker run --rm $hosts \
        -v "$(readlink -f "$conf"):/etc/nginx/nginx.conf:ro" \
        -v "$(readlink -f "$certs_dir"):/etc/nginx/certs:ro" \
        --entrypoint nginx nginx:alpine -t 2>&1) || true
    if echo "$out" | grep -q "syntax is ok"; then
        log_success "nginx -t OK: $conf"
    else
        log_error "nginx -t FAILED: $conf"
        echo "$out" | tail -4
        return 1
    fi
}

template_render() {
    # one source per env, two topologies: the CONFIG is the same for a single
    # host (compose) and a swarm — services are reached by name over the
    # docker network either way, resolved lazily (set $up_x; proxy_pass $up_x)
    # so nginx boots before every task runs. What differs per topology is
    # not nginx but the stack: ports mode + placement (pol prod / pol swarm).
    local env=$1 domain="" topology="${POL_PROXY_TOPOLOGY:-single}"; shift
    while [ $# -gt 0 ]; do case "$1" in --domain) domain="$2"; shift 2 ;; --topology) topology="$2"; shift 2 ;; *) shift ;; esac; done
    local tpl="$POL_SUITE_ROOT/pol-proxy/nginx.$env.conf.template" out="$POL_SUITE_ROOT/.generated/nginx.$env.conf"
    [ -f "$tpl" ] || die "no template for env '$env' (staging|prod|lean)"
    if grep -qE '^\s*upstream [a-z0-9-]+ \{' "$tpl"; then
        die "template $tpl still has static upstream{} blocks — they stop nginx from booting on a swarm (a service name only resolves once its task runs). Use: set \$up_x http://host:port; proxy_pass \$up_x;"
    fi
    mkdir -p "$POL_SUITE_ROOT/.generated"
    case "$env" in
        staging) local ip="${LOCAL_IP:-$(lan_ip)}"; sed "s/\${LOCAL_IP}/$ip/g" "$tpl" > "$out"; log_success "rendered $out (LOCAL_IP=$ip, topology $topology)" ;;
        prod|lean) [ -n "$domain" ] || domain="${PROD_DOMAIN:-${POL_PROD_DOMAIN:-}}"; [ -n "$domain" ] || die "--domain <public domain> (or PROD_DOMAIN) required for $env"
                   sed "s/\${PROD_DOMAIN}/$domain/g" "$tpl" > "$out"; log_success "rendered $out (domain $domain, topology $topology)" ;;
    esac
    [ "$topology" = swarm ] && log_info "swarm: the stack pins the proxy to the manager with host-mode 80/443 (pol prod); every other service is reached over the overlay by name"
}
template_guard() {
    local env=$1
    local conf="$POL_SUITE_ROOT/.generated/nginx.$env.conf"
    [ -f "$conf" ] || die "not rendered: $conf — pol proxy template $env"
    grep -qE '^\s*upstream [a-z0-9-]+ \{' "$conf" && die "static upstream{} block in $conf — see pol proxy template"
    local tmp; tmp=$(mktemp -d); mkdir -p "$tmp/certs/ca" "$tmp/certs/nip.io" "$tmp/apt" "$tmp/www"
    local edge="$POL_SUITE_ROOT/.generated/certs/edge"
    if [ -s "$edge/fullchain.pem" ]; then cp "$edge/fullchain.pem" "$tmp/certs/pol-proxy.crt"; cp "$edge/privkey.pem" "$tmp/certs/pol-proxy.key"
    elif [ -s "$POL_SUITE_ROOT/pol-proxy/certs/pol-proxy.crt" ]; then cp "$POL_SUITE_ROOT/pol-proxy/certs/pol-proxy.crt" "$tmp/certs/"; cp "$POL_SUITE_ROOT/pol-proxy/certs/pol-proxy.key" "$tmp/certs/"
    else openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/certs/pol-proxy.key" -out "$tmp/certs/pol-proxy.crt" -days 1 -subj "/CN=guard" >/dev/null 2>&1; fi
    cp "$tmp/certs/pol-proxy.crt" "$tmp/certs/nip.io/server.crt"; cp "$tmp/certs/pol-proxy.key" "$tmp/certs/nip.io/server.key"
    [ -s "$POL_SUITE_ROOT/pol-proxy/certs/ca/pol-ca.crt" ] && cp "$POL_SUITE_ROOT/pol-proxy/certs/ca/pol-ca.crt" "$tmp/certs/ca/" || cp "$tmp/certs/pol-proxy.crt" "$tmp/certs/ca/pol-ca.crt"
    local hosts; hosts=$(grep -oE '(https?://)[a-z0-9-]+:[0-9]+' "$conf" | sed -E 's#https?://##; s#:[0-9]+##' | sort -u | sed 's/^/--add-host /;s/$/:127.0.0.1/')
    local out
    # shellcheck disable=SC2086
    out=$(docker run --rm --network none $hosts -v "$conf:/etc/nginx/nginx.conf:ro" -v "$tmp/certs:/etc/nginx/certs:ro" -v "$tmp/apt:/srv/apt:ro" -v "$tmp/www:/var/www/certbot:ro" --entrypoint nginx nginx:1.27-alpine -t 2>&1) || true
    rm -rf "$tmp"
    if echo "$out" | grep -q "syntax is ok"; then log_success "nginx -t OK: $conf"; else log_error "nginx -t FAILED: $conf"; echo "$out" | grep -E "emerg|error" | tail -3; return 1; fi
}
proxy_mode() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^(isle-vlan-agent|isle-remote-agent)$'; then
        echo "isle — this device is an isle member: the isle agent's nginx (generated from its registry.json) fronts apps as <app>.isle; pol-proxy is not used here"
    elif docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
        echo "suite/swarm — pol-proxy from pol-proxy/nginx.<env>.conf.template (lean|prod|staging), deployed as a stack config, pinned to the manager, services reached over the overlay by name"
    else
        echo "suite/single — pol-proxy from pol-proxy/nginx.<env>.conf.template under compose on this host"
    fi
}

case "$COMMAND" in
    render)  do_render ;;
    mode)    proxy_mode ;;
    template) template_render "${1:?env (staging|prod|lean)}" "${@:2}" ;;
    guard)   template_guard "${1:?env (staging|prod|lean)}" ;;
    check)
        RC=0
        [ "$PROJECT" != "node" ] && { check_one "$POL_SUITE_ROOT/jinja-build/.generated/nginx.staging.conf" "$POL_SUITE_ROOT/pol-proxy/certs" || RC=1; }
        [ "$PROJECT" != "suite" ] && { check_one "$POL_RF_NODE/jinja-build/.generated/nginx.staging.conf" "$POL_RF_NODE/prf-proxy/certs" || RC=1; }
        exit $RC ;;
    promote)
        for pair in "$POL_SUITE_ROOT" "$POL_RF_NODE"; do
            [ "$PROJECT" = "node" ] && [ "$pair" = "$POL_SUITE_ROOT" ] && continue
            [ "$PROJECT" = "suite" ] && [ "$pair" = "$POL_RF_NODE" ] && continue
            for f in "$pair"/jinja-build/.generated/nginx.*.conf; do
                [ -f "$f" ] || continue
                dest="$pair/.generated/$(basename "$f")"
                if [ -f "$dest" ] && diff -q "$f" "$dest" >/dev/null; then
                    log_info "up to date: $dest"
                else
                    mkdir -p "$pair/.generated" && cp "$f" "$dest"
                    log_success "promoted: $dest (restart the proxy container to apply)"
                fi
            done
        done ;;
    status)
        for pair in "$POL_SUITE_ROOT" "$POL_RF_NODE"; do
            for f in "$pair"/jinja-build/.generated/nginx.*.conf; do
                [ -f "$f" ] || continue
                dest="$pair/.generated/$(basename "$f")"
                if [ ! -f "$dest" ]; then st="rendered, NOT promoted";
                elif diff -q "$f" "$dest" >/dev/null; then st="in sync";
                else st="DRIFT (promote to update)"; fi
                printf "  %-70s %s\n" "${dest#$POL_SUITE_ROOT/}" "$st"
            done
        done ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown proxy command: $COMMAND"; show_help; exit 1 ;;
esac
