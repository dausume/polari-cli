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
    # ci-12 (his ask): a listing must say WHERE the thing each secret unlocks
    # goes — which release pool, which registry — and the destination is rendered
    # from the same constants the routes push to (routes/destinations.sh), so it
    # cannot promise something a route does not do. In app mode it names the
    # DEVELOPER'S namespace, because that is where their releases actually go.
    echo "catalogue (name — destination — routes — present/absent):"
    local seen="" s2
    for r2 in $SECRETS_ACTIVE_ROUTES; do
        for s2 in $(secrets_route_requires "$r2"); do
            case " $seen " in *" $s2 "*) continue ;; esac
            seen="$seen $s2"
            printf '  %s\n' "$(secrets_catalog_line "$s2")"
        done
    done
    local legacy; legacy="$(secrets_legacy_names)"
    if [ -n "$legacy" ]; then
        echo "$legacy" | while read -r old new; do
            log_warn "$old is stored under the OLD name — it still works; rename it with: sudo pol jenkins secrets mv $old $new"
        done
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
    local rel="${1:-}"; case "$rel" in */*) ;; *) die "pol jenkins secrets put <area>/<name>   (e.g. github/release_token) — the value is read from stdin" ;; esac
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

# ci-12 — `pol jenkins secrets mv <old> <new>`: rename a stored secret in place,
# keeping its mode and owner. It exists because ci-12 renamed the two GitHub
# tokens so their names say what they are FOR, and a device that already holds
# one should not have to be handed a fresh token to catch up. The VALUE is never
# read, printed or copied through this shell — in the system posture the move is
# a single `sudo mv` of a root-owned file.
jd_secrets_mv() {
    jd_source
    local from="${1:-}" to="${2:-}"
    case "$from" in */*) ;; *) die "pol jenkins secrets mv <area>/<old> <area>/<new>" ;; esac
    case "$to"   in */*) ;; *) die "pol jenkins secrets mv <area>/<old> <area>/<new>" ;; esac
    case "$from$to" in *..*) die "refusing a path with '..'" ;; esac
    local d; d="$(secrets_dir)"
    if [ "$(secrets_mode)" = system ]; then
        sudo test -s "$d/$from" || die "$from is not there (nothing to rename)"
        sudo test -e "$d/$to" && die "$to already exists — remove it first, or you would lose one of the two"
        sudo install -d -o root -g "$CI_USER" -m 0750 "$d/$(dirname "$to")"
        sudo mv "$d/$from" "$d/$to" || die "could not rename $from"
        sudo chown "root:$CI_USER" "$d/$to"; sudo chmod 0640 "$d/$to"
        log_success "$from → $to (root:$CI_USER 0640; the value never passed through this shell)"
    else
        [ -s "$d/$from" ] || die "$from is not there (nothing to rename)"
        [ -e "$d/$to" ] && die "$to already exists — remove it first"
        install -d -m 0700 "$d/$(dirname "$to")"
        mv "$d/$from" "$d/$to"; chmod 0600 "$d/$to"
        log_success "$from → $to (0600, the checkout posture)"
    fi
    log_info "pol jenkins restart to hand it to the controller under the new name"
}

jd_secrets_rm() {
    jd_source
    local rel="${1:-}"; case "$rel" in */*) ;; *) die "pol jenkins secrets rm <area>/<name>" ;; esac
    local f; f="$(secrets_dir)/$rel"
    if [ "$(secrets_mode)" = system ]; then sudo rm -f "$f" || die "could not remove $f"
    else shred -u "$f" 2>/dev/null || rm -f "$f"; fi
    log_success "removed $rel — the routes that needed it go DRY again (pol jenkins doctor)"
}

# ci-12 — `pol jenkins test-status [<sha>]`: THE VERDICT, printed.
#
# It reads the file the pipeline wrote, and derives nothing. That is deliberate:
# the verdict is the ONE answer a test run reached, and a CLI that recomputed it
# from the parts would be a second implementation of the arithmetic — the two
# would drift, and the day they did, the one a person read would not be the one
# `promote main` obeyed.
jd_test_status() {
    jd_source
    local sha="${1:-}" pool="${POLARI_POOL:-$J/pool}"
    if [ -z "$sha" ]; then
        sha="$(git -C "$ROOT" ls-remote origin refs/heads/test 2>/dev/null | awk '{print $1}' | head -1)"
        [ -n "$sha" ] || { log_warn "there is no origin/test yet — pol jenkins promote test creates it"; return 1; }
        log_info "the tip of origin/test is ${sha:0:12}"
    fi
    # a short sha is enough: the pool directory is named by the full one
    if [ ! -d "$pool/test/$sha" ]; then
        local hit; hit="$(ls -1d "$pool/test/$sha"* 2>/dev/null | head -1 || true)"
        [ -z "$hit" ] && hit="$(docker exec "${CI_CONTROLLER_CONTAINER:-polari-jenkins}" \
            sh -c "ls -1d /var/polari-pool/test/$sha* 2>/dev/null | head -1" 2>/dev/null || true)"
        [ -n "$hit" ] && sha="$(basename "$hit")"
    fi
    # ci-12: read THROUGH the controller when the pool belongs to polari-ci —
    # "no verdict" must mean absent, never "I may not look".
    # shellcheck source=../../../polari-jenkins/pool.sh
    . "$J/pool.sh"
    local body; body="$(pool_read "test/$sha/verdict.json" 2>/dev/null || true)"
    local f="$pool/test/$sha/verdict.json"
    if [ -n "$body" ]; then
        local tmp; tmp="$(mktemp)"; printf '%s' "$body" > "$tmp"
        python3 "$J/verdict.py" show "$tmp"; rm -f "$tmp"
        echo "  file       $f  (read through the controller: the pool belongs to the pipeline user)"
        return 0
    fi
    if [ ! -f "$f" ]; then
        log_warn "no verdict for ${sha:0:12} on this device"
        echo "  polari-test polls the test branch every 5 minutes and records one verdict per sha."
        echo "  If this sha has never been on test:   pol jenkins promote test"
        echo "  If a run is pending or deferring:     pol jenkins queue"
        return 1
    fi
    python3 "$J/verdict.py" show "$f"
    echo "  file       $f"
    if [ -f "$pool/test/$sha/scan/SCAN_SUMMARY.md" ]; then
        echo "  scan report $pool/test/$sha/scan/SCAN_SUMMARY.md  (advisory)"
    fi
}

# ci-3 — `pol jenkins report [<sha>]`: THE ONE PAGE, printed.
#
# Same posture as test-status: the pool belongs to the pipeline user, so the
# file is read THROUGH the controller and "no report" means absent rather than
# "I may not look". It renders nothing itself — report.py did that in the run,
# and a CLI that re-rendered would be a second implementation of the page.
jd_report() {
    jd_source
    local sha="${1:-}" pool="${POLARI_POOL:-$J/pool}"
    if [ -z "$sha" ]; then
        sha="$(git -C "$ROOT" ls-remote origin refs/heads/test 2>/dev/null | awk '{print $1}' | head -1)"
        [ -n "$sha" ] || { log_warn "there is no origin/test yet — pol jenkins promote test creates it"; return 1; }
    fi
    if [ ! -d "$pool/test/$sha" ]; then
        local hit; hit="$(ls -1d "$pool/test/$sha"* 2>/dev/null | head -1 || true)"
        [ -z "$hit" ] && hit="$(docker exec "${CI_CONTROLLER_CONTAINER:-polari-jenkins}" \
            sh -c "ls -1d /var/polari-pool/test/$sha* 2>/dev/null | head -1" 2>/dev/null || true)"
        [ -n "$hit" ] && sha="$(basename "$hit")"
    fi
    # shellcheck source=../../../polari-jenkins/pool.sh
    . "$J/pool.sh"
    local body; body="$(pool_read "test/$sha/TEST_REPORT.md" 2>/dev/null || true)"
    if [ -n "$body" ]; then printf '%s\n' "$body"; return 0; fi
    local f="$pool/test/$sha/TEST_REPORT.md"
    [ -f "$f" ] && { cat "$f"; return 0; }
    log_warn "no test report for ${sha:0:12} on this device"
    echo "  polari-test renders one per sha, after the verdict (polari-jenkins/report.py)."
    echo "  If this sha has never been on test:   pol jenkins promote test"
    echo "  The verdict alone:                    pol jenkins test-status ${sha:0:12}"
    return 1
}

# ci-12 — run a polari-jenkins script THROUGH THE CONTROLLER when the state it
# reads belongs to the pipeline user. `pol jenkins queue` printed "idle / never"
# on the pipeline device for exactly the reason `promote main` printed "none":
# after init-device the pool is root:polari-ci and this shell may not read it.
# The controller runs AS polari-ci, so asking it is not a privilege escalation —
# it is the pipeline process reading its own bookkeeping.
jd_in_controller() {   # jd_in_controller <script-name> <args…>
    local sc="$1"; shift
    local c="${CI_CONTROLLER_CONTAINER:-polari-jenkins}"
    if [ -r "$J/pool" ] || ! command -v docker >/dev/null 2>&1 \
       || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
        bash "$J/$sc" "$@"
        return
    fi
    docker exec "$c" bash "/var/polari-jenkins/$sc" "$@"
}
