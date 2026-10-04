#!/bin/bash
# lan-ip-selftest.sh — fw-advertise: lib/log.sh's `lan_ip()` must prefer the
# swarm's own ADVERTISED address (`docker info {{.Swarm.NodeAddr}}`) over the
# default-route's source address when THIS host is a swarm MANAGER and that
# advertised address is actually configured on a local interface right now —
# found live 2026-10-04: a DHCP renewal moved the route's source address
# (.212) while the manager, the deployed proxy, and every joined worker still
# agreed on the advertised one (.210); `pol suite urls` printing the route's
# address sent a browser where the stack isn't listening.
#
# No real docker/ip touched: both are faked in a scratch bin dir.
#
#   lan-ip-selftest.sh [-v] [--help]   → prints N/N and exits non-zero on a miss
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,13p' "$0"; exit 0 ;; esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad() { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "$3"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'SH'
#!/bin/bash
# FAKE_DOCKER_MISSING is honored by just not being on PATH at all (a
# separate test case removes this binary instead of branching in it).
case "$*" in
    *"{{.Swarm.ControlAvailable}}"*) echo "${FAKE_CONTROL:-false}" ;;
    *"{{.Swarm.NodeAddr}}"*) echo "${FAKE_ADV:-<no value>}" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$BIN/docker"
cat > "$BIN/ip" <<'SH'
#!/bin/bash
case "$*" in
    "route get 1.1.1.1")
        echo "1.1.1.1 via 192.168.0.1 dev eth0 src ${FAKE_ROUTE_IP:-192.168.0.212} uid 1000" ;;
    "-4 -o addr show")
        # one line per FAKE_LOCAL_ADDRS entry (comma-separated), ip-addr-show shaped
        IFS=',' read -ra addrs <<< "${FAKE_LOCAL_ADDRS:-}"
        n=1
        for a in "${addrs[@]}"; do
            [ -n "$a" ] && echo "$n: eth$n    inet $a/24 brd 192.168.0.255 scope global eth$n"
            n=$((n+1))
        done ;;
    *) exit 1 ;;
esac
SH
chmod +x "$BIN/ip"

run() { env PATH="$BIN:$PATH" bash -c "source '$HERE/lib/log.sh'; lan_ip"; }

out=$(FAKE_CONTROL=false FAKE_ADV="<no value>" FAKE_ROUTE_IP=192.168.0.212 FAKE_LOCAL_ADDRS="192.168.0.212" run)
eq "not a swarm manager: falls through to the default-route address, unchanged behaviour" "192.168.0.212" "$out"

out=$(FAKE_CONTROL=true FAKE_ADV="192.168.0.210" FAKE_ROUTE_IP=192.168.0.212 FAKE_LOCAL_ADDRS="192.168.0.210,192.168.0.212" run)
eq "swarm MANAGER, advertised address IS configured locally: prefers the advertised address over the route's" "192.168.0.210" "$out"

out=$(FAKE_CONTROL=true FAKE_ADV="192.168.0.210" FAKE_ROUTE_IP=192.168.0.212 FAKE_LOCAL_ADDRS="192.168.0.212" run)
eq "swarm MANAGER, advertised address is STALE (not on any local interface): falls through to the route's address" "192.168.0.212" "$out"

out=$(FAKE_CONTROL=true FAKE_ADV="<no value>" FAKE_ROUTE_IP=192.168.0.212 FAKE_LOCAL_ADDRS="192.168.0.212" run)
eq "swarm MANAGER but no advertise address reported (e.g. swarm inactive): falls through to the route's address" "192.168.0.212" "$out"

out=$(FAKE_CONTROL=false FAKE_ADV="192.168.0.210" FAKE_ROUTE_IP=192.168.0.212 FAKE_LOCAL_ADDRS="192.168.0.210,192.168.0.212" run)
eq "swarm WORKER (ControlAvailable=false): never prefers the advertised address, even if it IS local" "192.168.0.212" "$out"

# docker not installed at all — must never crash lan_ip, just skip the swarm check
BIN2="$T/bin2"; mkdir -p "$BIN2"
cp "$BIN/ip" "$BIN2/ip"
out=$(env PATH="$BIN2:/usr/bin:/bin" FAKE_ROUTE_IP=192.168.0.212 FAKE_LOCAL_ADDRS="192.168.0.212" \
      bash -c "source '$HERE/lib/log.sh'; lan_ip")
eq "docker not on PATH at all: lan_ip still answers from the route (no crash)" "192.168.0.212" "$out"

echo "$PASS/$((PASS+FAIL)) lan-ip-selftest checks passed"
[ "$FAIL" -eq 0 ]
