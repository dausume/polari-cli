# remote-hint.sh — conditional post-build nudge toward remote-access setup.
# Sourced by the staging bring-up. Tells the user, based on current state,
# where to set up remote testing for the host computer and the phone.
# Never fails the build (best-effort, guarded).

remote_access_hint() {
    local lib_dir doc applied generated active
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    doc="$(cd "$lib_dir/../../docs" 2>/dev/null && pwd)/REMOTE-ACCESS.md"
    applied="/etc/wireguard/wg0.conf"
    generated="$(cd "$lib_dir/../../.." 2>/dev/null && pwd)/.remote-wg/wg0.conf"

    active=""
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet wg-quick@wg0 2>/dev/null && active=1
    fi

    echo
    if [ -n "$active" ]; then
        log_info "Remote access: WireGuard tunnel is ${GREEN}active${NC} — reach staging from your phone now (${CYAN}pol remote status${NC}; ${CYAN}sudo pol remote down${NC} to stop)."
    elif [ -f "$applied" ]; then
        log_info "Remote access: configured but not running. Start it with ${CYAN}sudo pol remote up${NC}, then test from your phone."
    elif [ -f "$generated" ]; then
        log_info "Remote access: configs generated, not yet applied. Finish with ${CYAN}sudo pol remote apply${NC} + set the router forward."
        log_info "  Setup docs (host computer + phone): ${BOLD}$doc${NC}"
    else
        log_info "Want to test this staging build from your phone? Set up secure remote access: ${CYAN}pol remote init${NC}"
        log_info "  Setup docs (host computer + phone): ${BOLD}$doc${NC}"
    fi
}
