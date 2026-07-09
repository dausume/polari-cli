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

case "$COMMAND" in
    render)  do_render ;;
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
