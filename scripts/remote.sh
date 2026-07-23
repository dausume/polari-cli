#!/bin/bash
# pol remote — remote staging access over WireGuard (port-forwarded).
#
# Sets up a single-peer WireGuard tunnel so ONE device (your phone) can reach
# THIS host's staging services from the internet, and nothing else on your LAN.
# Confinement is structural: the tunnel terminates on this host and IP-forwarding
# stays OFF, so the peer can reach only this host's own (published) ports.
#
#   init   generate keys + configs + phone QR + router instructions (safe; writes
#          no system files) into an output dir
#   apply  install the server config on THIS host + enable the service (root; the
#          one exposing step — asks to confirm)
#   up/down  toggle the tunnel (ephemeral: bring it up only while testing)
#   status   wg + service status
#   qr       (re)show the phone import (QR if qrencode present, else the .conf)
#
# The router port-forward (one UDP port -> this host) is the only manual step;
# it is printed, never automated. Runs at host level, so it survives `pol`
# rebuilds. See docs / ROUTER-SETUP.md written by `init`.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

OUT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)/.remote-wg"

show_help() {
    pol_box "pol remote — remote staging access over WireGuard"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}init${NC}   [--out DIR] [--subnet 10.9.0.0/24] [--port 51820]
         [--endpoint HOST:PORT] [--host-name STAGING_HOSTNAME]
         Generate keypairs, server + phone configs, phone QR, and the router
         port-forward instructions. Writes ONLY into DIR (default ${DIM}${OUT_DEFAULT}${NC});
         touches no system files. Private keys are chmod 600 and git-ignored.
  ${CYAN}apply${NC}  [--out DIR] [--yes]
         Install DIR/wg0.conf to /etc/wireguard and enable wg-quick@wg0 on THIS
         host (needs root). This is the exposing step — it asks to confirm.
  ${CYAN}up${NC} / ${CYAN}down${NC}   Start / stop the tunnel (ephemeral toggle; root).
  ${CYAN}status${NC}       wg + service status.
  ${CYAN}qr${NC}     [--out DIR]   (Re)show the phone import.

${BOLD}NOTES${NC}
  • Run ${CYAN}init${NC} + ${CYAN}apply${NC} on the staging host itself.
  • The router forward (UDP :PORT -> this host) is manual — printed by init.
  • Keys/configs live on the host, so access persists through \`pol\` rebuilds.
  • Reach staging by its ${BOLD}hostname${NC} (not raw IP) or OIDC/Keycloak redirects
    break — see the hostname note in ROUTER-SETUP.md."
}

# ---- key generation: wg if present, else python cryptography (X25519) --------
wg_keypair() {
    if command -v wg >/dev/null 2>&1; then
        local priv; priv=$(wg genkey)
        printf '%s %s\n' "$priv" "$(printf '%s' "$priv" | wg pubkey)"
        return 0
    fi
    python3 - <<'PY' 2>/dev/null || die "need 'wireguard-tools' (wg) or python3 'cryptography' to generate keys"
import base64, sys
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization as s
except Exception:
    sys.exit(1)
k = X25519PrivateKey.generate()
priv = k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())
pub = k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
print(base64.b64encode(priv).decode(), base64.b64encode(pub).decode())
PY
}

# ---- arg parsing -------------------------------------------------------------
OUT="$OUT_DEFAULT"; SUBNET="10.9.0.0/24"; PORT="51820"; ENDPOINT=""; HOSTNAME_ARG=""; LAN_IP=""; ASSUME_YES=""
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --out) OUT="$2"; shift 2 ;;
            --subnet) SUBNET="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --endpoint) ENDPOINT="$2"; shift 2 ;;
            --host-name) HOSTNAME_ARG="$2"; shift 2 ;;
            --lan-ip) LAN_IP="$2"; shift 2 ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) shift ;;
        esac
    done
}

subnet_ip() {  # subnet_ip <last-octet>  ->  first-three-octets + .<octet>
    local base="${SUBNET%/*}"; local pfx="${base%.*}"
    printf '%s.%s' "$pfx" "$1"
}

do_init() {
    parse_args "$@"
    local SRV_IP PHN_IP; SRV_IP="$(subnet_ip 1)"; PHN_IP="$(subnet_ip 2)"
    # Route the staging host's LAN IP through the tunnel too, so the default
    # *.nip.io staging URLs (which resolve to the LAN IP) keep working remotely
    # with the existing OIDC/hostname config — no staging reconfiguration.
    # Forwarding stays OFF, so the host only serves its OWN LAN IP: still confined.
    [ -z "$LAN_IP" ] && LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    local ALLOWED="${SRV_IP}/32"
    [ -n "$LAN_IP" ] && [ "$LAN_IP" != "$SRV_IP" ] && ALLOWED="${SRV_IP}/32, ${LAN_IP}/32"
    mkdir -p "$OUT"; chmod 700 "$OUT"
    log_info "generating WireGuard artifacts in ${BOLD}$OUT${NC}"

    read -r SRV_PRIV SRV_PUB <<<"$(wg_keypair)"
    read -r PHN_PRIV PHN_PUB <<<"$(wg_keypair)"
    [ -n "$SRV_PRIV" ] && [ -n "$PHN_PRIV" ] || die "key generation failed"

    printf '%s' "$SRV_PRIV" > "$OUT/server.key"; printf '%s' "$SRV_PUB" > "$OUT/server.pub"
    printf '%s' "$PHN_PRIV" > "$OUT/phone.key";  printf '%s' "$PHN_PUB" > "$OUT/phone.pub"
    chmod 600 "$OUT"/*.key

    # Server config — forwarding stays OFF (no PostUp NAT): tunnel confined here.
    cat > "$OUT/wg0.conf" <<EOF
# Polari staging remote-access — server (this host). Confined: no IP-forwarding,
# so the peer reaches only THIS host's own published ports (staging), not the LAN.
[Interface]
Address = ${SRV_IP}/24
ListenPort = ${PORT}
PrivateKey = ${SRV_PRIV}

[Peer]
# The one phone peer.
PublicKey = ${PHN_PUB}
AllowedIPs = ${PHN_IP}/32
EOF
    chmod 600 "$OUT/wg0.conf"

    local EP="${ENDPOINT:-<your-home-ddns-or-ip>:${PORT}}"
    local DNS_LINE="# DNS = ${SRV_IP}   # uncomment + run a resolver mapping your staging hostname -> ${SRV_IP} (see hostname note)"
    [ -n "$HOSTNAME_ARG" ] && DNS_LINE="DNS = ${SRV_IP}   # resolves ${HOSTNAME_ARG} -> ${SRV_IP} over the tunnel (host must serve it)"

    # Phone config — AllowedIPs is ONLY the server WG IP: only staging traffic
    # enters the tunnel; the phone's normal internet is untouched.
    cat > "$OUT/phone.conf" <<EOF
[Interface]
PrivateKey = ${PHN_PRIV}
Address = ${PHN_IP}/32
${DNS_LINE}

[Peer]
PublicKey = ${SRV_PUB}
Endpoint = ${EP}
AllowedIPs = ${ALLOWED}
PersistentKeepalive = 25
EOF
    chmod 600 "$OUT/phone.conf"

    # Host-side scope check (run after apply): confirms forwarding is OFF.
    cat > "$OUT/scope-check.sh" <<EOF
#!/bin/bash
# Confirm the tunnel is confined to this host (no LAN forwarding).
fwd=\$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')
echo "ip_forward = \$fwd  (want 0 — 1 would let the peer route onward to the LAN)"
echo "peer can reach services bound to 0.0.0.0 on this host at ${SRV_IP}:<port>."
echo "From the PHONE (tunnel up): https://${HOSTNAME_ARG:-<staging-host>}:2096 works;"
echo "a connection to any other LAN IP must FAIL — that failure is the proof."
EOF
    chmod +x "$OUT/scope-check.sh"

    cat > "$OUT/ROUTER-SETUP.md" <<EOF
# Remote staging access — WireGuard (port-forwarded)

Generated by \`pol remote init\`. Server = this host (${SRV_IP}), phone = ${PHN_IP}.

## 1. Install on THIS host
    sudo pol remote apply        # copies wg0.conf to /etc/wireguard, enables the service
    # (or manually: sudo cp $OUT/wg0.conf /etc/wireguard/wg0.conf && sudo systemctl enable --now wg-quick@wg0)

## 2. Router + dynamic DNS (the one manual step — cannot be automated)
Forward **UDP :${PORT} → this host's LAN IP (${LAN_IP})**. UDP only, nothing else.
Home IPs are usually dynamic, so register a free hostname that tracks your home IP
(e.g. **no-ip.com**) and use it as the tunnel Endpoint: re-run init with
\`--endpoint <your-no-ip-hostname>:${PORT}\`. Step-by-step no-ip instructions are in
polari-cli/docs/REMOTE-ACCESS.md.

## 3. Phone (official WireGuard app)
Import **phone.conf** (AirDrop/Files) or scan the QR from \`pol remote qr\`.
Toggle the tunnel on to test, off when done.

## 4. Verify scope
    bash $OUT/scope-check.sh
Phone reaches staging:2096; any other LAN IP fails.

## Accessing staging remotely — the nip.io point
- The default staging URLs are https://prf.${LAN_IP}.nip.io (etc.). nip.io resolves
  those to the LAN IP **${LAN_IP}**, which is dead outside your network. This config
  routes ${LAN_IP} through the tunnel (see phone.conf \`AllowedIPs\`), so the SAME
  nip.io URLs work from your phone with the tunnel up — no staging reconfiguration,
  and Keycloak/OIDC/issuer/CORS all still match because the hostname is unchanged.
  Accept the self-signed cert once.
- Forwarding stays OFF: the host serves only its OWN LAN IP (${LAN_IP}); it can't
  route on to other machines — still confined to staging.
- Services must listen on 0.0.0.0 (Polari's published ports do).
- If your phone's DNS blocks public names that resolve to private IPs ("DNS rebind
  protection"), set a resolver in phone.conf's \`DNS\` or use a hostname you control.
- Persists through rebuilds: this runs at host level; \`pol\` rebuilding staging
  re-publishes the same ports, so the phone config keeps working with no re-keying.

Endpoint set to: ${EP}
EOF

    log_success "wrote: wg0.conf, phone.conf, keys (600), scope-check.sh, ROUTER-SETUP.md"
    log_warn "PRIVATE KEYS are in $OUT (git-ignored). Next: sudo pol remote apply, then set the router forward."
    echo -e "\n${BOLD}Phone import:${NC} run ${CYAN}pol remote qr${NC}  (or import ${OUT}/phone.conf into the WireGuard app)"
}

require_root() { [ "$(id -u)" = "0" ] || die "run as root (sudo pol remote $1)"; }

do_apply() {
    parse_args "$@"; require_root apply
    [ -f "$OUT/wg0.conf" ] || die "no $OUT/wg0.conf — run 'pol remote init' first"
    command -v wg >/dev/null 2>&1 || die "install wireguard-tools first (apt install wireguard)"
    if [ -z "$ASSUME_YES" ]; then
        log_warn "This EXPOSES this host's staging ports to your one WireGuard peer once the"
        log_warn "router forward is set. It enables wg-quick@wg0 on this host."
        read -r -p "Proceed? [y/N] " ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "aborted"
    fi
    install -m 600 "$OUT/wg0.conf" /etc/wireguard/wg0.conf
    systemctl enable --now wg-quick@wg0
    log_success "wg-quick@wg0 enabled. Set the router UDP forward next (see ROUTER-SETUP.md)."
}

do_toggle() { require_root "$1"; systemctl "$1" wg-quick@wg0 && log_success "wg-quick@wg0 $1"; }

do_status() {
    if command -v wg >/dev/null 2>&1; then wg show 2>/dev/null || log_warn "tunnel not up"; fi
    systemctl status wg-quick@wg0 --no-pager 2>/dev/null | head -5 || log_warn "service not installed"
}

do_qr() {
    parse_args "$@"
    [ -f "$OUT/phone.conf" ] || die "no $OUT/phone.conf — run 'pol remote init' first"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ansiutf8 < "$OUT/phone.conf"
    else
        log_warn "qrencode not installed — import the file directly instead:"
        echo "  AirDrop / share $OUT/phone.conf to the phone and open it in the WireGuard app,"
        echo "  or install qrencode (apt install qrencode) and re-run 'pol remote qr'."
    fi
}

COMMAND="${1:-help}"; shift || true
case "$COMMAND" in
    init)          do_init "$@" ;;
    apply)         do_apply "$@" ;;
    up)            do_toggle up ;;
    down|stop)     do_toggle down ;;
    status)        do_status ;;
    qr)            do_qr "$@" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown remote command: $COMMAND"; show_help; exit 1 ;;
esac
