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

jd_set() {   # jd_set KEY VALUE — rewrite one key in device.env, in place
    local k="$1" v="${2:-}"
    if grep -qE "^$k=" "$J/device.env"; then
        python3 - "$J/device.env" "$k" "$v" <<'PY'
import sys
path, key, val = sys.argv[1:4]
out = []
for line in open(path):
    out.append('%s=%s\n' % (key, val) if line.split('=', 1)[0] == key else line)
open(path, 'w').writelines(out)
PY
    else
        printf '%s=%s\n' "$k" "$v" >> "$J/device.env"
    fi
}

# Export the device configuration so docker-compose (and through it casc and
# the jobs) sees CI_ROUTES / CI_EXECUTORS / the isle target.
jd_export_for_compose() { jd_source; device_export; }

# ------------------------------------------------------------------- guide
# A SHORT walkthrough — whiptail when there is a terminal and whiptail is
# installed, plain prompts otherwise. (Deliberately not the Textual guide
# `pol prod guide` uses: those tui_* helpers live inside prod.sh, not in
# lib/, and copying a thousand-line guide framework for six questions would
# be worse than these twelve lines.)
JD_TUI=0; [ -t 0 ] && [ -t 1 ] && command -v whiptail >/dev/null 2>&1 && JD_TUI=1
jd_menu()  { local t=$1 x=$2 d=$3; shift 3
             if [ "$JD_TUI" = 1 ]; then whiptail --title "$t" --default-item "$d" --menu "$x" 18 76 6 "$@" 3>&1 1>&2 2>&3
             else echo >&2; echo "== $t" >&2; echo "$x" >&2; local i=1 it=("$@")
                  while [ $i -le $# ]; do printf '  %s — %s\n' "${it[$((i-1))]}" "${it[$i]}" >&2; i=$((i+2)); done
                  read -r -p "choice [$d]: " c; echo "${c:-$d}"; fi; }
jd_input() { if [ "$JD_TUI" = 1 ]; then whiptail --title "$1" --inputbox "$2" 12 76 "$3" 3>&1 1>&2 2>&3
             else echo >&2; echo "== $1" >&2; read -r -p "$2 [$3]: " c; echo "${c:-$3}"; fi; }

jd_guide() {
    jd_source
    pol_box "pol jenkins — the pipeline device"
    local where alias_="" ram disk routes
    where=$(jd_menu "Where does the throwaway isle go?" \
"The pipeline builds an isle in a VM and destroys it. That VM needs /dev/kvm, libvirt and room; the machine running Jenkins does not have to be the one that provides them." \
        "$CI_ISLE_TARGET" \
        local "this machine — it needs KVM + libvirt + RAM for controller, build AND the VM" \
        ssh   "another device over ssh — this machine then only needs docker")
    if [ "$where" = ssh ]; then
        alias_=$(jd_input "ssh alias" "The Host alias from ~/.ssh/config for the isle device. An ALIAS, never an address — device.env is gitignored but habits are not:" "$CI_ISLE_SSH_HOST")
        [ -n "$alias_" ] || die "an alias is required for the ssh target"
    fi
    ram=$(jd_input "VM memory (GB)" "How much memory the throwaway isle VM gets. The preflight refuses a run when the device cannot spare it:" "$CI_ISLE_VM_RAM_GB")
    disk=$(jd_input "VM disk (GB)" "The overlay disk for the throwaway isle (an isle install wants 30 GB or more):" "$CI_ISLE_VM_DISK_GB")
    routes=$(jd_input "Routes that may publish" "Comma list of ACTIVE routes allowed to publish FOR REAL when their secret is present. A route left out stays DRY even with its secret in place:" "$CI_ROUTES")
    jd_target "$where" "$alias_"
    jd_set CI_ISLE_VM_RAM_GB "$ram"; jd_set CI_ISLE_VM_DISK_GB "$disk"; jd_set CI_ROUTES "$routes"
    echo; log_info "written to polari-jenkins/device.env:"; jd_config | sed 's/^/  /'
    echo; log_info "now:  sudo pol jenkins init-device   (the secrets posture)"
    log_info "then: pol jenkins doctor  ·  pol jenkins preflight --isle"
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
