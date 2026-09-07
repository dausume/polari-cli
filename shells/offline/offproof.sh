#!/bin/bash
# offproof.sh start|report|stop — THE PROOF that an offline install
# touched no internet (OFFLINE_INSTALL_PLAN.md §E). Counts (and DROPS)
# every packet leaving this host or its containers for a non-private
# address, plus every DNS query, so "no internet access occurred" is a
# number, not a claim. Optional pcap when tcpdump exists.
#   sudo bash offproof.sh start     (before install-offline.sh)
#   sudo bash offproof.sh report    (after; writes /var/log/polari-offline-proof.txt)
#   sudo bash offproof.sh stop      (removes the rules)
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
LOG=/var/log/polari-offline-proof.txt
PCAP=/var/log/polari-offline-proof.pcap
PRIV='{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255/32 }'
case "${1:-}" in
  start)
    command -v nft >/dev/null || { echo "nft not installed — cannot count; install nftables (from the medium's apt/ if present)" >&2; exit 1; }
    nft delete table inet offproof 2>/dev/null || true
    nft -f - <<NFT
table inet offproof {
  counter egress_public {}
  counter forward_public {}
  counter dns_any {}
  chain out { type filter hook output priority -10; policy accept;
    ip daddr != $PRIV counter name egress_public drop
    ip6 daddr != { ::1, fe80::/10, fc00::/7, ff00::/8 } counter name egress_public drop
    udp dport 53 counter name dns_any
    tcp dport 53 counter name dns_any }
  chain fwd { type filter hook forward priority -10; policy accept;
    ip daddr != $PRIV counter name forward_public drop
    ip6 daddr != { ::1, fe80::/10, fc00::/7, ff00::/8 } counter name forward_public drop }
}
NFT
    date -Is > /var/run/offproof.started
    if command -v tcpdump >/dev/null; then
        nohup tcpdump -ni any -w "$PCAP" 'not net 10.0.0.0/8 and not net 172.16.0.0/12 and not net 192.168.0.0/16 and not host 127.0.0.1 and not net 224.0.0.0/4 and not ip6' >/dev/null 2>&1 &
        echo $! > /var/run/offproof.tcpdump.pid
        echo "[ OK ] counters armed + pcap $PCAP"
    else
        echo "[ OK ] counters armed (no tcpdump here — counters are the evidence)"
    fi ;;
  report)
    { echo "polari offline-install proof — $(hostname) — started $(cat /var/run/offproof.started 2>/dev/null) reported $(date -Is)"
      echo "install-mode: $(cat /etc/polari/install-mode 2>/dev/null || echo '(none)')  source: $(cat /etc/polari/offline-source 2>/dev/null || echo '(none)')"
      nft list counters table inet offproof 2>/dev/null | grep -E 'counter|packets' | paste - - | sed 's/[{}]//g; s/  */ /g'
      if [ -f "$PCAP" ]; then echo "pcap packets: $(tcpdump -nr "$PCAP" 2>/dev/null | wc -l)"; fi
      echo "URLs in isle logs that are not .isle/loopback:"
      grep -rhoE 'https?://[^ "]+' /var/log/isle-mesh/ 2>/dev/null | grep -vE '\.isle|127\.0\.0\.1|localhost' | sort -u | head -20 || true
      echo "verdict: $(nft list counters table inet offproof 2>/dev/null | grep -oE 'packets [0-9]+' | awk '{s+=$2} END {print (s==0) ? "CLEAN — zero packets to public addresses or DNS" : "DIRTY — " s " packets counted (see above)"}')"
    } | tee "$LOG" ;;
  stop)
    [ -f /var/run/offproof.tcpdump.pid ] && kill "$(cat /var/run/offproof.tcpdump.pid)" 2>/dev/null || true
    nft delete table inet offproof 2>/dev/null || true
    echo "[ OK ] proof rules removed (log kept at $LOG)" ;;
  *) echo "usage: sudo bash offproof.sh start|report|stop" >&2; exit 1 ;;
esac
