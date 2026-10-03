#!/bin/bash
# swarm-selftest.sh — checks for swarm.sh's `hw-engines` role (the
# role_compose_cmd table gains a case the same shape as cnt-engines) and
# `pol swarm join`'s pre-flight port check / `pol swarm ports` verb (the
# TCP 2377+7946 / UDP 7946+4789 node->manager probe, the printed ufw
# lines, and the post-join ingress-mesh check). No real docker/ssh/swarm
# touched anywhere: fake `ssh` and `docker` in a scratch bin dir, in the
# prod-forge-selftest.sh style (FAKE_*_LOG, canned per-subcommand output).
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
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; *) args+=("$1"); shift ;; esac; done
CMD="${args[1]:-}"
case "$CMD" in
  hostname) echo fake-isle-core ;;
  *"hostname -I"*) echo "${NODE_IP:-192.168.0.24}" ;;
  *"docker info"*) [ "${REMOTE_SWARM_ACTIVE:-0}" = 1 ] && exit 0 || exit 1 ;;
  *"docker swarm join"*) exit "${REMOTE_JOIN_RC:-0}" ;;
  *"nc "*)
      PORT="${CMD##* }"
      case "$CMD" in *"-zu "*) PROTO=udp ;; *) PROTO=tcp ;; esac
      case " ${OPEN_PORTS:-} " in *" ${PORT}/${PROTO} "*) exit 0 ;; *) exit 1 ;; esac ;;
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
              *)
                  printf 'ID        HOSTNAME        STATUS\nSELFID    pol-core        Ready\nNODEID1   fake-isle-core  Ready\n' ;;
            esac ;;
        update) exit 0 ;;
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

run() {  # run <swarm.sh args…>  — real swarm.sh, fake ssh/docker, scratch suite
    ( cd "$S" && env PATH="$BIN:$PATH" POL_SUITE_ROOT="$S" \
          FAKE_SSH_LOG="$FAKE_SSH_LOG" FAKE_DOCKER_LOG="$FAKE_DOCKER_LOG" \
          NODE_IP="${NODE_IP:-192.168.0.24}" OPEN_PORTS="${OPEN_PORTS-}" \
          MESH_HAS_PEER="${MESH_HAS_PEER:-0}" REMOTE_SWARM_ACTIVE="${REMOTE_SWARM_ACTIVE:-0}" \
          REMOTE_JOIN_RC="${REMOTE_JOIN_RC:-0}" FAKE_ALREADY_JOINED="${FAKE_ALREADY_JOINED:-0}" \
          FAKE_PROXY_RUNNING="${FAKE_PROXY_RUNNING:-0}" \
          SWARM_MESH_POLL_TRIES=1 SWARM_MESH_POLL_INTERVAL=0 \
          bash "$HERE/swarm.sh" "$@" 2>&1 | nocolor )
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

echo
echo "swarm-selftest: $PASS/$((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
