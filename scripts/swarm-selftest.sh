#!/bin/bash
# swarm-selftest.sh — checks for swarm.sh's `hw-engines` role (the
# role_compose_cmd table gains a case the same shape as cnt-engines),
# `pol swarm join`'s pre-flight port check / `pol swarm ports` verb (the
# TCP 2377+7946 / UDP 7946+4789 node->manager probe, the printed ufw
# lines, and the post-join ingress-mesh check), and the firewall
# HANDSHAKE (dev-swarm-fw-handshake): `pol net needs`, `--apply` turning
# CLOSED ports into consented source-scoped ufw rules with a hand-back
# journal, and `pol net handback --apply` replaying the undo in reverse.
# No real docker/ssh/swarm/sudo/ufw touched anywhere: fake `ssh`,
# `docker`, `sudo`, `ufw`, `systemctl`, `nft` in a scratch bin dir, in
# the prod-forge-selftest.sh style (FAKE_*_LOG, canned per-subcommand
# output); a POL_FORCE_TTY override stands in for a real pty (nothing in
# this sandbox can allocate one).
#
#   swarm-selftest.sh [-v] [--help]      → prints N/N and exits non-zero on a miss
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="${POL_SUITE_ROOT:-$(cd "$HERE/../.." && pwd)}"   # the real suite (pol-build/stackify.py)
VERBOSE=0
case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,9p' "$0"; exit 0 ;; esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad()  { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "NOT …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
nocolor() { sed 's/\x1b\[[0-9;]*m//g'; }

# ---------------------------------------------------------------- the scratch suite
S="$T/suite"; mkdir -p "$S/polari-rf-node" "$S/pol-build/manifests" "$S/.generated"
touch "$S/setup-polari-security.sh"       # log.sh's "is this the suite" probe
cat > "$S/polari-rf-node/docker-compose.hw-engines.yml" <<'YML'
services:
  board-engines: {image: "prf-board-engines:trixie"}
  formal-engines: {image: "prf-formal-engines:trixie"}
  esp-engines: {image: "prf-esp-engines:noble"}
YML
[ -e "$R/pol-build" ] && ln -s "$R/pol-build" "$S/pol-build-real" || true
# stackify.py is a pure transform (no suite-shape assumptions) — use the real one
mkdir -p "$S/pol-build/tools"
ln -sf "$R/pol-build/tools/stackify.py" "$S/pol-build/tools/stackify.py"
cat > "$S/pol-build/manifests/nodes.yml" <<'YML'
nodes:
  pol-core:
    ssh: ""
    repo_dir: ~/Desktop/polari-suite
    roles: [node, research-core]
    notes: "manager (this box)"
  isle-core:
    ssh: fake-isle-core
    repo_dir: ~/polari-suite
    roles: [engines, remote-worker, node, infra-core, hardware-integration]
    notes: "fake node for the selftest"
repo_url: https://example.invalid/polari-suite.git
YML

# ---------------------------------------------------------------- fake ssh / docker
BIN="$T/bin"; mkdir -p "$BIN"
FAKE_SSH_LOG="$T/ssh.log"; : > "$FAKE_SSH_LOG"
FAKE_DOCKER_LOG="$T/docker.log"; : > "$FAKE_DOCKER_LOG"

cat > "$BIN/ssh" <<'SH'
#!/bin/bash
echo "ssh $*" >> "$FAKE_SSH_LOG"
args=()
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -t) shift ;; *) args+=("$1"); shift ;; esac; done
CMD="${args[1]:-}"
case "$CMD" in
  hostname) echo fake-isle-core ;;
  *"hostname -I"*) echo "${NODE_IP:-192.168.0.24}" ;;
  *"docker info"*) [ "${REMOTE_SWARM_ACTIVE:-0}" = 1 ] && exit 0 || exit 1 ;;
  *"docker swarm join"*) exit "${REMOTE_JOIN_RC:-0}" ;;
  *"nc "*)
      PORT="${CMD##* }"
      case "$CMD" in *"-zu "*) PROTO=udp ;; *) PROTO=tcp ;; esac
      case " ${OPEN_PORTS:-} " in
        *" ${PORT}/${PROTO} "*) exit 0 ;;
      esac
      # a rule `pol swarm ports --apply` just added also counts as open —
      # this is what lets the post-apply recheck show closed->open.
      if [ "${FAKE_NC_IGNORE_UFW:-0}" != 1 ] && [ -n "${FAKE_UFW_STATUS_FILE:-}" ] && grep -q "^${PORT}/${PROTO}[[:space:]]" "$FAKE_UFW_STATUS_FILE" 2>/dev/null; then
          exit 0
      fi
      exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/ssh"

cat > "$BIN/docker" <<'SH'
#!/bin/bash
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  info) echo "Swarm: active"; exit 0 ;;
  node)
      case "$2" in
        ls)
            case "$*" in
              *'{{.Hostname}} {{json .}}'*)
                  [ "${FAKE_ALREADY_JOINED:-0}" = 1 ] && printf 'fake-isle-core {"polari.machine":"isle-core"}\n' || true ;;
              *'{{.ID}} {{.Hostname}}'*)
                  printf 'NODEID1 fake-isle-core\n' ;;
              *-q*)
                  printf 'SELFID\nNODEID1\n' ;;
              *)
                  printf 'ID        HOSTNAME        STATUS\nSELFID    pol-core        Ready\nNODEID1   fake-isle-core  Ready\n' ;;
            esac ;;
        update) exit 0 ;;
        # pol swarm leave → pol deploy uninstall --route swarm-worker: the
        # NID lookup (`for id in $(docker node ls -q); do docker node
        # inspect --format '{{.ID}} {{.Spec.Labels}}' $id; done`) and the
        # final `docker node rm --force $NID`.
        inspect)
            id="${@: -1}"
            if [ "$id" = NODEID1 ]; then echo "NODEID1 map[polari.machine:isle-core]"
            else echo "$id map[polari.machine:pol-core]"; fi ;;
        rm) exit 0 ;;
      esac ;;
  network)
      [ "$2" = inspect ] && {
          if [ "${MESH_HAS_PEER:-0}" = 1 ]; then
              printf '[{"Name":"n1","IP":"%s"}]\n' "${NODE_IP:-192.168.0.24}"
          else
              printf '[]\n'
          fi
      } ;;
  swarm)
      [ "$2" = join-token ] && echo "SWMTKN-fake" ;;
  ps)
      case "$*" in
        *'{{.Names}}'*) [ "${FAKE_PROXY_RUNNING:-0}" = 1 ] && echo pol-proxy || true ;;
      esac ;;
  compose)
      case "$*" in
        *" config")
            cat <<'YAML'
services:
  board-engines:
    image: prf-board-engines:trixie
    container_name: prf-board-engines
    restart: unless-stopped
  formal-engines:
    image: prf-formal-engines:trixie
    container_name: prf-formal-engines
    restart: unless-stopped
  esp-engines:
    image: prf-esp-engines:noble
    container_name: prf-esp-engines
    restart: unless-stopped
networks:
  polari-link:
    external: true
YAML
            ;;
      esac ;;
  stack) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/docker"

# ---------------------------------------------------------------- fake sudo / ufw (the handshake)
FAKE_SUDO_LOG="$T/sudo.log"; : > "$FAKE_SUDO_LOG"
FAKE_UFW_LOG="$T/ufw.log"; : > "$FAKE_UFW_LOG"
FAKE_UFW_STATUS_FILE="$T/ufw-status-rules"; : > "$FAKE_UFW_STATUS_FILE"

cat > "$BIN/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >> "$FAKE_SUDO_LOG"
if [ "$1" = "-n" ]; then
    shift
    [ "${1:-}" = "true" ] && exit "${FAKE_SUDO_N_RC:-1}"
fi
exec "$@"
SH
chmod +x "$BIN/sudo"

# a tiny `ufw` that keeps its "rules" in FAKE_UFW_STATUS_FILE — enough to
# exercise fw_detect / fw_rule_present / the allow+delete round trip.
cat > "$BIN/ufw" <<'SH'
#!/bin/bash
echo "ufw $*" >> "$FAKE_UFW_LOG"
case "$1" in
  status)
      if [ "${FAKE_UFW_ACTIVE:-1}" = 1 ]; then echo "Status: active"; else echo "Status: inactive"; fi
      echo; echo "To                         Action      From"; echo "--                         ------      ----"
      [ -f "$FAKE_UFW_STATUS_FILE" ] && cat "$FAKE_UFW_STATUS_FILE"
      ;;
  allow)
      shift; ip=""; port=""; proto=""
      while [ $# -gt 0 ]; do case "$1" in
          from) ip=$2; shift 2 ;;
          port) port=$2; shift 2 ;;
          proto) proto=$2; shift 2 ;;
          comment) shift 2 ;;
          *) shift ;;
      esac; done
      printf '%-28s%-14s%s\n' "$port/$proto" ALLOW "$ip" >> "$FAKE_UFW_STATUS_FILE"
      echo "Rule added"
      exit "${FAKE_UFW_ALLOW_RC:-0}" ;;
  delete)
      shift; [ "${1:-}" = allow ] && shift
      port=""; proto=""
      while [ $# -gt 0 ]; do case "$1" in
          port) port=$2; shift 2 ;;
          proto) proto=$2; shift 2 ;;
          *) shift ;;
      esac; done
      if [ -f "$FAKE_UFW_STATUS_FILE" ]; then
          grep -v "^$port/$proto" "$FAKE_UFW_STATUS_FILE" > "$FAKE_UFW_STATUS_FILE.tmp" 2>/dev/null || : > "$FAKE_UFW_STATUS_FILE.tmp"
          mv "$FAKE_UFW_STATUS_FILE.tmp" "$FAKE_UFW_STATUS_FILE"
      fi
      echo "Rule deleted" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$BIN/ufw"

# a SECOND bin dir with no ufw at all — the firewalld/nftables/none
# detection tests run with it and with the sbin dirs stripped from PATH
# (the real host's ufw/nft live there; stripping them makes "absent"
# actually absent instead of silently hitting the real tool).
BIN2="$T/bin2"; mkdir -p "$BIN2"
ln -s "$BIN/ssh" "$BIN2/ssh"; ln -s "$BIN/docker" "$BIN2/docker"; ln -s "$BIN/sudo" "$BIN2/sudo"
cat > "$BIN2/systemctl" <<'SH'
#!/bin/bash
case "$*" in
  "is-active --quiet firewalld") [ "${FAKE_FIREWALLD:-0}" = 1 ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BIN2/systemctl"
cat > "$BIN2/firewall-cmd" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$BIN2/firewall-cmd"
cat > "$BIN2/nft" <<'SH'
#!/bin/bash
if [ "$1" = list ] && [ "${FAKE_NFTABLES:-0}" = 1 ]; then echo "table inet filter { chain input { } }"; fi
exit 0
SH
chmod +x "$BIN2/nft"
SBIN_STRIPPED_PATH="/usr/bin:/bin:/usr/local/bin"

run() {  # run <swarm.sh args…>  — real swarm.sh, fake ssh/docker/sudo/ufw, scratch suite; stdin /dev/null (non-interactive by default)
    ( cd "$S" && env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" \
          FAKE_SSH_LOG="$FAKE_SSH_LOG" FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
          FAKE_SUDO_LOG="$FAKE_SUDO_LOG" FAKE_UFW_LOG="$FAKE_UFW_LOG" FAKE_UFW_STATUS_FILE="$FAKE_UFW_STATUS_FILE" \
          FAKE_UFW_ACTIVE="${FAKE_UFW_ACTIVE:-1}" FAKE_SUDO_N_RC="${FAKE_SUDO_N_RC:-1}" FAKE_UFW_ALLOW_RC="${FAKE_UFW_ALLOW_RC:-0}" \
          FAKE_NC_IGNORE_UFW="${FAKE_NC_IGNORE_UFW:-0}" \
          NODE_IP="${NODE_IP:-192.168.0.24}" OPEN_PORTS="${OPEN_PORTS-}" \
          MESH_HAS_PEER="${MESH_HAS_PEER:-0}" REMOTE_SWARM_ACTIVE="${REMOTE_SWARM_ACTIVE:-0}" \
          REMOTE_JOIN_RC="${REMOTE_JOIN_RC:-0}" FAKE_ALREADY_JOINED="${FAKE_ALREADY_JOINED:-0}" \
          FAKE_PROXY_RUNNING="${FAKE_PROXY_RUNNING:-0}" \
          POL_HANDBACK_DIR="${POL_HANDBACK_DIR:-$T/handback}" \
          POL_FORCE_TTY="${POL_FORCE_TTY-}" POL_ASSUME_NO="${POL_ASSUME_NO-}" CI="${SELFTEST_CI-}" \
          SWARM_MESH_POLL_TRIES=1 SWARM_MESH_POLL_INTERVAL=0 \
          bash "$HERE/swarm.sh" "$@" 2>&1 | nocolor ) </dev/null
}

run_in() {  # run_in <stdin-line> <swarm.sh args…>  — like run(), but feeds one line to a y/N prompt
    local ans=$1; shift
    ( cd "$S" && printf '%s\n' "$ans" | env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" \
          FAKE_SSH_LOG="$FAKE_SSH_LOG" FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
          FAKE_SUDO_LOG="$FAKE_SUDO_LOG" FAKE_UFW_LOG="$FAKE_UFW_LOG" FAKE_UFW_STATUS_FILE="$FAKE_UFW_STATUS_FILE" \
          FAKE_UFW_ACTIVE="${FAKE_UFW_ACTIVE:-1}" FAKE_SUDO_N_RC="${FAKE_SUDO_N_RC:-1}" FAKE_UFW_ALLOW_RC="${FAKE_UFW_ALLOW_RC:-0}" \
          FAKE_NC_IGNORE_UFW="${FAKE_NC_IGNORE_UFW:-0}" \
          NODE_IP="${NODE_IP:-192.168.0.24}" OPEN_PORTS="${OPEN_PORTS-}" \
          MESH_HAS_PEER="${MESH_HAS_PEER:-0}" REMOTE_SWARM_ACTIVE="${REMOTE_SWARM_ACTIVE:-0}" \
          REMOTE_JOIN_RC="${REMOTE_JOIN_RC:-0}" FAKE_ALREADY_JOINED="${FAKE_ALREADY_JOINED:-0}" \
          FAKE_PROXY_RUNNING="${FAKE_PROXY_RUNNING:-0}" \
          POL_HANDBACK_DIR="${POL_HANDBACK_DIR:-$T/handback}" \
          POL_FORCE_TTY="${POL_FORCE_TTY-1}" POL_ASSUME_NO="${POL_ASSUME_NO-}" CI="${SELFTEST_CI-}" \
          SWARM_MESH_POLL_TRIES=1 SWARM_MESH_POLL_INTERVAL=0 \
          bash "$HERE/swarm.sh" "$@" 2>&1 | nocolor )
}

run2() {  # run2 <swarm.sh args…>  — BIN2 (no ufw), sbin stripped: firewalld/nftables/none detection
    ( cd "$S" && env PATH="$BIN2:$SBIN_STRIPPED_PATH" POL_SUITE_ROOT="$S" \
          FAKE_SSH_LOG="$FAKE_SSH_LOG" FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" FAKE_SUDO_LOG="$FAKE_SUDO_LOG" \
          FAKE_FIREWALLD="${FAKE_FIREWALLD:-0}" FAKE_NFTABLES="${FAKE_NFTABLES:-0}" \
          NODE_IP="${NODE_IP:-192.168.0.24}" OPEN_PORTS="${OPEN_PORTS-}" \
          MESH_HAS_PEER="${MESH_HAS_PEER:-0}" REMOTE_SWARM_ACTIVE="${REMOTE_SWARM_ACTIVE:-0}" \
          REMOTE_JOIN_RC="${REMOTE_JOIN_RC:-0}" FAKE_ALREADY_JOINED="${FAKE_ALREADY_JOINED:-0}" \
          FAKE_PROXY_RUNNING="${FAKE_PROXY_RUNNING:-0}" \
          POL_HANDBACK_DIR="${POL_HANDBACK_DIR:-$T/handback}" \
          POL_FORCE_TTY="${POL_FORCE_TTY-1}" POL_ASSUME_NO="${POL_ASSUME_NO-}" CI="${SELFTEST_CI-}" \
          SWARM_MESH_POLL_TRIES=1 SWARM_MESH_POLL_INTERVAL=0 \
          bash "$HERE/swarm.sh" "$@" 2>&1 | nocolor ) </dev/null
}

runnet() {  # runnet <net.sh args…>  — pol net, same scratch suite + fakes, stdin /dev/null
    ( cd "$S" && env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" \
          FAKE_SSH_LOG="$FAKE_SSH_LOG" FAKE_SUDO_LOG="$FAKE_SUDO_LOG" FAKE_UFW_LOG="$FAKE_UFW_LOG" \
          POL_HANDBACK_DIR="${POL_HANDBACK_DIR:-$T/handback}" \
          POL_FORCE_TTY="${POL_FORCE_TTY-}" POL_ASSUME_NO="${POL_ASSUME_NO-}" CI="${SELFTEST_CI-}" \
          bash "$HERE/net.sh" "$@" 2>&1 | nocolor ) </dev/null
}

runnet_in() {  # runnet_in <stdin-line> <net.sh args…>
    local ans=$1; shift
    ( cd "$S" && printf '%s\n' "$ans" | env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" \
          FAKE_SSH_LOG="$FAKE_SSH_LOG" FAKE_SUDO_LOG="$FAKE_SUDO_LOG" FAKE_UFW_LOG="$FAKE_UFW_LOG" \
          POL_HANDBACK_DIR="${POL_HANDBACK_DIR:-$T/handback}" \
          POL_FORCE_TTY="${POL_FORCE_TTY-1}" POL_ASSUME_NO="${POL_ASSUME_NO-}" CI="${SELFTEST_CI-}" \
          bash "$HERE/net.sh" "$@" 2>&1 | nocolor )
}

# =================================================================== Fix 1: hw-engines role
has "help: hw-engines role documented" "hw-engines" "$(run help)"
has "help: ports verb documented" "ports [<node>]" "$(run help)"

: > "$FAKE_DOCKER_LOG"
out="$(run deploy hw-engines)"
has   "deploy hw-engines: not refused as an unknown role" "stack rendered" "$out"
has   "deploy hw-engines: stack deployed as polari-hw-engines (generic naming)" "stack deploy -c" "$(cat "$FAKE_DOCKER_LOG")"
has   "  …the generic name carries the role through" "polari-hw-engines" "$(cat "$FAKE_DOCKER_LOG")"
stk="$S/.generated/stack-hw-engines.yml"
[ -s "$stk" ] && ok "deploy hw-engines: .generated/stack-hw-engines.yml rendered" || bad "stack-hw-engines.yml rendered" "a file" "missing/empty"
has   "  …board/formal/esp all present in the rendered stack" "formal-engines" "$(cat "$stk" 2>/dev/null)"

# the proxy-conflict guard must NOT fire for hw-engines (own ports, same as cnt-engines)
: > "$FAKE_DOCKER_LOG"
FAKE_PROXY_RUNNING=1 out="$(FAKE_PROXY_RUNNING=1 run deploy hw-engines)"
hasnt "deploy hw-engines: a running compose proxy does NOT block it (own ports, like cnt-engines)" "published ports conflict" "$out"
has   "  …it still deploys" "stack rendered" "$out"

out="$(run render bogus-role 2>&1)" || true
has "render: an unknown role still refuses, hw-engines named as valid" "hw-engines" "$out"

# =================================================================== Fix 2: swarm ports / join
# ---- all four ports CLOSED
OPEN_PORTS="" out="$(OPEN_PORTS="" run ports isle-core)"
has   "ports (all closed): TCP 2377 reported CLOSED" "TCP 2377 (node -> mgr)       CLOSED" "$out"
has   "  …TCP 7946 reported CLOSED" "TCP 7946 (node -> mgr)       CLOSED" "$out"
has   "  …UDP 7946 reported CLOSED" "UDP 7946 (node -> mgr)       CLOSED" "$out"
has   "  …UDP 4789 reported CLOSED" "UDP 4789 (node -> mgr)       CLOSED" "$out"
has   "  …the exact ufw tcp/2377 line, run on the manager" "sudo ufw allow from 192.168.0.24 to any port 2377 proto tcp" "$out"
has   "  …the exact ufw udp/7946 line" "sudo ufw allow from 192.168.0.24 to any port 7946 proto udp" "$out"
has   "  …the exact ufw udp/4789 line" "sudo ufw allow from 192.168.0.24 to any port 4789 proto udp" "$out"
hasnt "  …no false 'ports: all open'" "ports: all open" "$out"

# ---- all four ports OPEN
out="$(OPEN_PORTS="2377/tcp 7946/tcp 7946/udp 4789/udp" run ports isle-core)"
has   "ports (all open): every row reports open" "TCP 2377 (node -> mgr)       open" "$out"
hasnt "  …no ufw line printed when nothing is closed" "sudo ufw allow" "$out"
has   "  …'ports: all open' summary" "ports: all open — isle-core can form the mesh" "$out"

# ---- ports [<node>] omitted — sweeps every nodes.yml machine with an ssh alias
out="$(OPEN_PORTS="2377/tcp 7946/tcp 7946/udp 4789/udp" run ports)"
has "ports (no node arg): sweeps nodes.yml — isle-core checked" "swarm ports: isle-core" "$out"
hasnt "  …the local manager (ssh: \"\") is not probed over ssh" "swarm ports: pol-core" "$out"

# ---- join: ports closed → join still proceeds, prints the warning + ufw lines, mesh NOT formed after
out="$(OPEN_PORTS="" MESH_HAS_PEER=0 run join isle-core)"
has   "join (ports closed): the ports table is shown before joining" "swarm ports: isle-core" "$out"
has   "  …warns the join proceeds anyway" "joining anyway" "$out"
has   "  …the ufw line for the manager is printed" "sudo ufw allow from 192.168.0.24 to any port 2377 proto tcp" "$out"
has   "  …the join itself still reports success" "joined the swarm" "$out"
has   "  …mesh reported NOT formed, pointing back at the ports" "mesh: NOT formed (ports above)" "$out"
hasnt "  …never falsely claims the mesh formed" "mesh: ok" "$out"

# ---- join: ports open + ingress lists the node → mesh: ok
out="$(OPEN_PORTS="2377/tcp 7946/tcp 7946/udp 4789/udp" MESH_HAS_PEER=1 run join isle-core)"
hasnt "join (ports open): no ufw lines" "sudo ufw allow" "$out"
has   "  …mesh: ok after the join" "mesh: ok — isle-core is a gossip peer" "$out"
hasnt "  …never reports NOT formed when it did form" "mesh: NOT formed" "$out"

# ---- unknown node name refuses cleanly (no ssh attempted)
: > "$FAKE_SSH_LOG"
out="$(run ports no-such-node 2>&1)" || true
has   "ports: an unknown node refuses" "not in nodes.yml" "$out"
eq    "  …no ssh attempted" "" "$(cat "$FAKE_SSH_LOG")"

# =================================================================== Fix 3: the firewall HANDSHAKE (dev-swarm-fw-handshake)
# ---- pol net needs: data, not prose
out="$(runnet needs swarm-manager)"
has "net needs swarm-manager: the 4 manager-side rows" "2377   tcp   cluster management (join)" "$out"
has "  …7946/tcp gossip row" "7946   tcp   gossip (control plane)" "$out"
has "  …7946/udp gossip row" "7946   udp   gossip (control plane)" "$out"
has "  …4789/udp VXLAN row" "4789   udp   VXLAN overlay data" "$out"
out="$(runnet needs swarm-worker)"
hasnt "net needs swarm-worker: no 2377 (manager-only)" "2377" "$out"
has   "  …worker-side 7946/udp row" "worker   7946   udp" "$out"
out="$(runnet needs engine-worker 9830)"
has "net needs engine-worker 9830: the hw/engine row" "worker   9830   tcp   hw/engine worker API (direct call, not mesh)" "$out"
out="$(runnet needs bogus-binding 2>&1)" || true
has "net needs: an unknown binding refuses" "unknown binding" "$out"

# ---- closed ports + interactive yes → the exact rules, through fake sudo, journaled, re-checked
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"; rm -rf "$T/handback"
out="$(OPEN_PORTS="" POL_FORCE_TTY=1 run_in "y" ports isle-core --apply)"
has "--apply + yes: asks a single consent prompt listing every rule" "firewall consent: isle-core (192.168.0.24) -> this host" "$out"
has "  …the exact source-scoped rule (never a blanket allow <port>)" "sudo ufw allow from 192.168.0.24 to any port 2377 proto tcp comment 'polari swarm-manager isle-core'" "$out"
has "  …sudo -n true probed first (says whether a password is coming)" "sudo will prompt for a password" "$out"
has "  …4/4 applied" "4/4 rule(s) applied on this host" "$out"
has "  …re-checks the ports afterwards (before/after in one transcript)" "re-checking isle-core after apply" "$out"
has "  …after: all 4 rows now report open" "TCP 2377 (node -> mgr)       open" "$out"
has "  …'ports: all open' after apply" "ports: all open — isle-core can form the mesh (after apply)" "$out"
eq  "  …all 4 rules actually ran through fake sudo" "4" "$(grep -c 'sudo ufw allow' "$FAKE_SUDO_LOG")"
eq  "  …4 lines landed in the hand-back journal" "4" "$(grep -c . "$T/handback/firewall.jsonl" 2>/dev/null || echo 0)"
has "  …a journal line carries ts/host/binding/peer/rule/undo/comment" '"binding": "swarm-manager", "peer": "isle-core"' "$(cat "$T/handback/firewall.jsonl")"
has "  …the undo is the exact inverse ufw command" '"undo": "ufw delete allow from 192.168.0.24 to any port 2377 proto tcp"' "$(cat "$T/handback/firewall.jsonl")"

# ---- interactive no → nothing applied
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"; rm -rf "$T/handback"
out="$(OPEN_PORTS="" POL_FORCE_TTY=1 run_in "n" ports isle-core --apply)" || true
has   "--apply + no: declines" "declined — nothing applied" "$out"
eq    "  …fake sudo never ran an allow" "0" "$(grep -c 'sudo ufw allow' "$FAKE_SUDO_LOG")"
eq    "  …nothing journaled" "" "$(cat "$T/handback/firewall.jsonl" 2>/dev/null || true)"

# ---- non-interactive (no TTY, no --yes) → nothing applied, lines printed
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"; rm -rf "$T/handback"
out="$(OPEN_PORTS="" run ports isle-core --apply)" || true
has   "--apply, non-interactive: refuses to apply" "non-interactive — not applying" "$out"
has   "  …still prints the exact ufw line (so it can be run by hand)" "sudo ufw allow from 192.168.0.24 to any port 2377 proto tcp" "$out"
eq    "  …fake sudo never ran an allow" "0" "$(grep -c 'sudo ufw allow' "$FAKE_SUDO_LOG")"

# ---- CI env refuses even with a (forced) tty — the pipeline must never open ports
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"
out="$(OPEN_PORTS="" SELFTEST_CI=1 POL_FORCE_TTY=1 run_in "y" ports isle-core --apply)" || true
has "--apply, CI env set: refuses even though 'interactive'" "non-interactive — not applying" "$out"
eq  "  …fake sudo never ran an allow" "0" "$(grep -c 'sudo ufw allow' "$FAKE_SUDO_LOG")"

# ---- POL_ASSUME_NO=1 refuses the same way
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"
out="$(OPEN_PORTS="" POL_ASSUME_NO=1 POL_FORCE_TTY=1 run_in "y" ports isle-core --apply)" || true
has "--apply, POL_ASSUME_NO=1: refuses even though 'interactive'" "non-interactive — not applying" "$out"

# ---- --yes skips the y/N (sudo is still the real gate)
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"; rm -rf "$T/handback"
out="$(OPEN_PORTS="" POL_FORCE_TTY=1 run_in "" ports isle-core --apply --yes)"
hasnt "--apply --yes: no y/N text printed" "apply these 4 rule(s)" "$out"
has   "  …still applies (sudo is the real gate, not the y/N)" "4/4 rule(s) applied on this host" "$out"

# ---- rules already present (in ufw) are skipped, even though the probe itself still reports closed
: > "$FAKE_SUDO_LOG"
printf '%-28s%-14s%s\n' "2377/tcp" ALLOW "192.168.0.24" >  "$FAKE_UFW_STATUS_FILE"
printf '%-28s%-14s%s\n' "7946/tcp" ALLOW "192.168.0.24" >> "$FAKE_UFW_STATUS_FILE"
printf '%-28s%-14s%s\n' "7946/udp" ALLOW "192.168.0.24" >> "$FAKE_UFW_STATUS_FILE"
printf '%-28s%-14s%s\n' "4789/udp" ALLOW "192.168.0.24" >> "$FAKE_UFW_STATUS_FILE"
out="$(OPEN_PORTS="" FAKE_NC_IGNORE_UFW=1 POL_FORCE_TTY=1 run_in "y" ports isle-core --apply)" || true
has "--apply: a rule already in ufw is skipped (idempotent)" "already present: allow from 192.168.0.24 port 2377/tcp — skipping" "$out"
has "  …all four already present" "all needed rules already present on this host" "$out"
eq  "  …nothing re-applied through sudo" "0" "$(grep -c 'sudo ufw allow' "$FAKE_SUDO_LOG")"

# ---- firewalld detected: equivalent rules PRINTED, never applied
: > "$FAKE_UFW_STATUS_FILE"
out="$(OPEN_PORTS="" FAKE_FIREWALLD=1 POL_FORCE_TTY=1 run2 ports isle-core --apply)" || true
has   "--apply, firewalld host: says so and does not apply" "firewalld detected on this host — pol only automates ufw" "$out"
has   "  …prints the firewall-cmd equivalent" "sudo firewall-cmd --permanent --add-rich-rule='rule family=\"ipv4\" source address=\"192.168.0.24\" port port=\"2377\" protocol=\"tcp\" accept'" "$out"
hasnt "  …never claims anything was applied" "rule(s) applied" "$out"

# ---- `pol swarm join` applies by default (ports --apply is opt-in; join is opt-out)
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"; rm -rf "$T/handback"
out="$(OPEN_PORTS="" MESH_HAS_PEER=1 POL_FORCE_TTY=1 run_in "y" join isle-core)"
has "join (default): applies the handshake without --apply" "firewall consent: isle-core (192.168.0.24) -> this host" "$out"
has "  …re-checks before joining, ports now open" "re-checking ports before joining" "$out"
has "  …joins cleanly afterwards" "joined the swarm" "$out"
hasnt "  …no longer warns 'joining anyway' once ports opened" "joining anyway" "$out"
eq  "  …4 lines landed in the hand-back journal" "4" "$(grep -c . "$T/handback/firewall.jsonl" 2>/dev/null || echo 0)"

# ---- `pol swarm join --no-apply` is the old print-only behaviour
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"
out="$(OPEN_PORTS="" run join isle-core --no-apply)"
hasnt "join --no-apply: never shows the consent box" "firewall consent:" "$out"
has   "  …still warns + prints the plain ufw lines (old behaviour)" "joining anyway" "$out"
eq    "  …fake sudo never ran an allow" "0" "$(grep -c 'sudo ufw allow' "$FAKE_SUDO_LOG")"

# ---- handback --apply replays the undo in reverse and shrinks the journal
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"; rm -rf "$T/handback"
OPEN_PORTS="" POL_FORCE_TTY=1 run_in "y" ports isle-core --apply --yes >/dev/null
listed="$(runnet handback --peer isle-core)"
has "net handback (list): shows the 4 journaled rules" "peer=isle-core" "$listed"
out="$(POL_FORCE_TTY=1 runnet_in "y" handback --peer isle-core --apply)"
has   "net handback --apply: lists the undo lines, last-applied first" "sudo ufw delete allow from 192.168.0.24 to any port 4789 proto udp" "$out"
has   "  …replays through fake sudo" "Rule deleted" "$out"
has   "  …reports 4/4 handed back" "4/4 rule(s) handed back on this host" "$out"
eq    "  …the journal is empty afterwards" "" "$(cat "$T/handback/firewall.jsonl" 2>/dev/null || true)"
out2="$(runnet handback --peer isle-core)"
has   "  …a second listing shows nothing left" "handback journal empty" "$out2"

# ---- non-interactive handback --apply also refuses (never silently closes ports either)
: > "$FAKE_UFW_STATUS_FILE"; : > "$FAKE_SUDO_LOG"; rm -rf "$T/handback"
OPEN_PORTS="" POL_FORCE_TTY=1 run_in "y" ports isle-core --apply --yes >/dev/null
out="$(runnet handback --peer isle-core --apply)" || true
has "net handback --apply, non-interactive: refuses" "non-interactive — not applying" "$out"
eq  "  …journal untouched (4 lines kept)" "4" "$(grep -c . "$T/handback/firewall.jsonl" 2>/dev/null || echo 0)"

# ---- pol swarm leave: hands back both hosts (--yes, no sudo in this test
# scenario since FAKE_UFW_STATUS_FILE is empty / nothing to hand back),
# then delegates the actual leave to the EXISTING uninstall route — proof
# it is not re-implemented: the fake docker/ssh logs show the drain +
# `docker swarm leave` (over ssh) + `docker node rm`, never from swarm.sh
# running a bare 'docker swarm leave' itself.
: > "$FAKE_DOCKER_LOG"; : > "$FAKE_SSH_LOG"; rm -rf "$T/handback"
out="$(run leave isle-core --yes 2>&1)"
has "leave: hands back the firewall rules first" "handing back whatever the join handshake opened" "$out"
has "  …then leaves" "uninstall (swarm-worker) done on isle-core" "$out"
has "  …the node's own 'docker swarm leave' ran OVER SSH (deploy.sh's route, not a new one)" "docker swarm leave" "$(cat "$FAKE_SSH_LOG")"
has "  …the manager drains + removes the node (deploy.sh's route)" "node update --availability drain" "$(cat "$FAKE_DOCKER_LOG")"
has "  …  …and node rm" "node rm --force NODEID1" "$(cat "$FAKE_DOCKER_LOG")"

echo
echo "swarm-selftest: $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
