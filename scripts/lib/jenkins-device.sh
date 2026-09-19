#!/bin/bash
# lib/jenkins-device.sh — the `pol jenkins` half that is about THE DEVICE:
# where the throwaway isle goes (device.env), and where the secrets live
# (ci-7 (B) and (C)). Sourced by scripts/jenkins.sh; it expects $J
# (polari-jenkins/) and lib/log.sh to be in scope.
#
# Nothing here reads or prints a secret VALUE — only names, owners and modes.

# The pipeline-device configuration itself lives in polari-jenkins/device.sh
# (the pipeline sources the same file), so there is one definition of the
# keys, the defaults and the validation.
jd_source() { source "$J/device.sh"; source "$J/secrets.sh"; }

# -------------------------------------------------------------- device.env
jd_config() { jd_source; device_print; }

jd_target() {   # jd_target local | ssh <alias>
    local mode="${1:-}" alias_="${2:-}"
    case "$mode" in
        local) ;;
        ssh)   [ -n "$alias_" ] || die "pol jenkins target ssh <alias> — the ssh ALIAS from ~/.ssh/config (never an address)" ;;
        *)     die "pol jenkins target local | pol jenkins target ssh <alias>" ;;
    esac
    [ -f "$J/device.env" ] || { install -m 0600 "$J/device.env.example" "$J/device.env"; log_info "wrote polari-jenkins/device.env from the example (gitignored)"; }
    jd_set CI_ISLE_TARGET "$mode"
    jd_set CI_ISLE_SSH_HOST "$alias_"
    log_success "pipeline device: $([ "$mode" = local ] && echo 'this machine' || echo "ssh alias '$alias_'") — the throwaway isle VM goes there"
    if [ "$mode" = ssh ]; then
        if ssh -o BatchMode=yes -o ConnectTimeout=8 "$alias_" 'echo ok' >/dev/null 2>&1; then log_success "$alias_ answers a BatchMode ssh"
        else log_warn "$alias_ does not answer a BatchMode ssh yet — add a Host entry and a key (ssh-copy-id $alias_); pol jenkins doctor says so too"; fi
    fi
    log_info "next: pol jenkins doctor   then: pol jenkins preflight --isle"
}

# ONE writer: polari-jenkins/device.sh owns "rewrite a key in device.env"
# (the setup walkthrough writes through the same function).
jd_set() { jd_source; device_env_set "$1" "${2:-}"; }

# Export the device configuration so docker-compose (and through it casc and
# the jobs) sees CI_ROUTES / CI_EXECUTORS / the isle target.
jd_export_for_compose() { jd_source; device_export; }

# --------------------------------------------------------------------- sync
# ci-8: the `cicd` Polari app owns these settings; device.env is the fallback.
# `pull` before reading (the top of every Jenkinsfile, and `pol jenkins doctor`),
# `push` after a change (`pol jenkins setup`). Neither is ever fatal.
jd_sync() {
    case "${1:-status}" in
        pull)   bash "$J/cicd-sync.sh" pull ;;
        push)   bash "$J/cicd-sync.sh" push; bash "$J/cicd-sync.sh" push-secrets ;;
        status) bash "$J/cicd-sync.sh" status ;;
        *)      die "pol jenkins sync pull|push|status" ;;
    esac
}

# ---------------------------------------------------------------- the cache
# ci-9: the offline-first cache — one directory the builders read first, and
# (opt-in) four caching proxies beside the controller. `status` and `proxies
# status` read; `prune` is the ONE deleter and it removes only entries nothing
# has used for longer than the knob.
jd_cache() {
    jd_source
    case "${1:-status}" in
        status)  bash "$J/cache.sh" status ;;
        prune)   shift; bash "$J/cache.sh" prune "$@" ;;
        proxies) shift; bash "$J/cache-proxies.sh" "${1:-status}" ;;
        dir)     shift; bash "$J/cache.sh" dir "${1:-wheels}" ;;
        report)  shift
                 local pool ver f
                 pool="${POLARI_POOL:-$J/pool}"
                 ver="${1:-$(ls -1 "$pool" 2>/dev/null | grep -E '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}' | sort -V | tail -1)}"
                 f="$pool/$ver/cache-report.json"
                 [ -n "$ver" ] && [ -f "$f" ] || die "no cache report yet (looked for $f) — a build writes one per version"
                 echo "cache report — pool version $ver"; bash "$J/cache.sh" report-show "$f" ;;
        *)       die "pol jenkins cache status | prune [--older-than DAYS] | proxies up|down|status | dir <area> | report [version]" ;;
    esac
}

# ------------------------------------------------------------------- setup
# `pol jenkins setup` — THE entry point (ci-7b). The walkthrough itself
# lives in polari-jenkins/setup.sh + setup/steps/*.sh, beside the doctor and
# the preflight it reuses; this is only the door. `guide` is kept as an
# alias because the README and the ledger name it.
jd_setup() { exec bash "$J/setup.sh" "$@"; }   # setup.sh loads device.env itself — exporting CI_* here would shadow what it writes

# One line for `pol jenkins status`, read from the file setup writes.
jd_setup_line() {
    local f="$J/SETUP_STATUS.md" n v
    if [ ! -f "$f" ]; then echo "setup: not run yet — pol jenkins setup"; return 0; fi
    n=$(grep -m1 '^steps: ' "$f" | sed 's/^steps: //')
    v=$(grep -m1 '^\*\*verdict: ' "$f" | sed 's/^\*\*verdict: \([^*]*\)\*\*.*/\1/')
    echo "setup: ${n:-unknown} (${v:-unknown}) — pol jenkins setup --report"
}

# ----------------------------------------------------------------- secrets
jd_secrets_status() {
    jd_source
    local dir mode; mode="$(secrets_mode)"; dir="$(secrets_dir)"
    echo "posture: $mode   directory: $dir   pipeline user: $CI_USER"
    case "$mode" in
        system) echo "  root (via sudo) and the $CI_USER process may read these. Nobody else." ;;
        repo)   log_warn "FALLBACK posture: every process of user $(id -un) can read these — sudo pol jenkins init-device" ;;
    esac
    local listed; listed="$(secrets_list)"
    if [ -z "$listed" ] && [ "$mode" = system ] && ! sudo -n true 2>/dev/null; then
        echo "  (needs sudo to list — run: sudo pol jenkins secrets status)"
    else
        echo "present (NAMES only — no value is ever printed):"
        [ -n "$listed" ] && echo "$listed" | sed 's#^#  present  #' || echo "  (none)"
    fi
    echo "routes:"
    local r need s miss inlist c
    for r in $SECRETS_ACTIVE_ROUTES; do
        need=$(secrets_route_requires "$r"); miss=""
        for s in $need; do secrets_have "$s" || miss="$miss $s"; done
        inlist=0; for c in ${CI_ROUTES//,/ }; do [ "$c" = "$r" ] && inlist=1; done
        if   [ "$inlist" = 0 ]; then printf '  %-16s DRY (not in CI_ROUTES)\n' "$r"
        elif [ -n "$miss" ];   then printf '  %-16s DRY (absent:%s)\n' "$r" "$miss"
        else                        printf '  %-16s ARMED — a release WILL publish to it\n' "$r"; fi
    done
    echo "  parked: $SECRETS_PARKED_ROUTES (routes/later/)"
}

jd_secrets_put() {   # jd_secrets_put <area>/<name>  — the VALUE comes from stdin
    jd_source
    local rel="${1:-}"; case "$rel" in */*) ;; *) die "pol jenkins secrets put <area>/<name>   (e.g. github/github_token) — the value is read from stdin" ;; esac
    case "$rel" in *..*) die "refusing a path with '..'" ;; esac
    [ -t 0 ] && log_info "reading the value from stdin — paste it and press Ctrl-D (it is never echoed, never logged)"
    local tmp; tmp=$(mktemp); chmod 0600 "$tmp"; trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' RETURN
    cat > "$tmp"
    [ -s "$tmp" ] || die "empty — nothing written"
    if [ "$(secrets_mode)" = system ]; then
        sudo install -D -o root -g "$CI_USER" -m 0640 "$tmp" "$(secrets_dir)/$rel" \
            || die "could not write $(secrets_dir)/$rel (that directory is root-owned on purpose — use sudo)"
        log_success "$rel stored in $(secrets_dir) as root:$CI_USER 0640 — readable by sudo and by the pipeline process, by nobody else"
    else
        install -D -m 0600 "$tmp" "$(secrets_dir)/$rel"
        log_warn "$rel stored in the CHECKOUT ($(secrets_dir)) as 0600 — readable by every process of $(id -un). sudo pol jenkins init-device moves it out."
    fi
    log_info "pol jenkins restart to hand it to the controller; pol jenkins doctor to see which routes are now ARMED"
}

jd_secrets_rm() {
    jd_source
    local rel="${1:-}"; case "$rel" in */*) ;; *) die "pol jenkins secrets rm <area>/<name>" ;; esac
    local f; f="$(secrets_dir)/$rel"
    if [ "$(secrets_mode)" = system ]; then sudo rm -f "$f" || die "could not remove $f"
    else shred -u "$f" 2>/dev/null || rm -f "$f"; fi
    log_success "removed $rel — the routes that needed it go DRY again (pol jenkins doctor)"
}
