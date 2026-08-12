#!/bin/bash
# pol shared logging/colors — source this from every tier-2/leaf script.
# (Deliberate improvement over the isle-mesh CLI, which duplicated these
# constants in ~37 scripts.)
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"   # from scripts/*.sh
#
# Provides: RED GREEN YELLOW BLUE CYAN BOLD DIM NC
#           log_info log_success log_warn log_error die
#           pol_box "Title"        (boxed section header)
#           lan_ip                 (this host's LAN address)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }
die()         { log_error "$*"; exit 1; }

pol_box() {
    local title="$1"
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    printf  "${BOLD}║  %-56s║${NC}\n" "$title"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
}

# THE host's LAN address — the address other machines can reach.
#
# ⚠ NOT `hostname -I | awk '{print $1}'`: that lists every interface and
# DOCKER BRIDGES CAN COME FIRST. Caught live 2026-08-12 — creating one
# compose network reordered it, and the next `pol swarm deploy node`
# stamped 172.20.0.1 into every ${LOCAL_IP} knob (MSCI_ENGINES_URL and
# the meeting server's URLs), i.e. addresses no other machine can dial.
# The default-route source address is the honest answer, and it is what
# staging-setup.sh's detect_ip has always used; hostname -I stays only
# as the last-resort fallback.
lan_ip() {
    local ip=''
    command -v ip >/dev/null 2>&1 && \
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1)
    [ -z "$ip" ] && command -v hostname >/dev/null 2>&1 && \
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

# Suite root: exported by the pol dispatcher; fall back for direct runs.
POL_SUITE_ROOT="${POL_SUITE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
[ -f "$POL_SUITE_ROOT/setup-polari-security.sh" ] || \
    die "POL_SUITE_ROOT ($POL_SUITE_ROOT) doesn't look like polari-suite (set POLARI_SUITE_ROOT)"
POL_RF_NODE="$POL_SUITE_ROOT/polari-rf-node"
