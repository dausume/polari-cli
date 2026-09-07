#!/bin/bash
# reticulum-peer.sh <ip-of-other-isle> [port] — dial another isle's
# sidecar over the LAN/wifi (TCPClientInterface into the live config in
# the volume), restart, and show who we hear. Run on the isle that
# DIALS; the other side only needs 4242 published. Idempotent per ip.
set -eu
IP="${1:-}"; PORT="${2:-4242}"
[ -n "$IP" ] || { echo "usage: bash reticulum-peer.sh <other-isle-ip> [port]" >&2; exit 1; }
NAME="Isle $IP"
docker exec pol-reticulum sh -c "grep -q 'target_host = $IP' /var/reticulum/config" 2>/dev/null && { echo "[ OK ] $IP already configured"; } || \
docker exec -i pol-reticulum sh -c "cat >> /var/reticulum/config" <<CFG

  [[$NAME]]
    type = TCPClientInterface
    enabled = True
    target_host = $IP
    target_port = $PORT
CFG
docker restart pol-reticulum >/dev/null && echo "[ OK ] pol-reticulum restarted with TCP client → $IP:$PORT (it announces on start; restart the OTHER side once too so we hear it)"
sleep 6
bash "$(dirname "${BASH_SOURCE[0]}")/reticulum-status.sh"
