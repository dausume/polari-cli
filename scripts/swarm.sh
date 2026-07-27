#!/bin/bash
# pol swarm — docker-swarm orchestration mode (bld-5).
#
# ROLE: swarm is the STAND-IN for isle-mesh — multi-node placement,
# overlay networking and a mesh-ish story TODAY, while the real isle-mesh
# capabilities are built (`pol isle` is the future surface).
#
# STACK RENDERING (v1 mechanism): the rendered compose bundles are
# expanded with `docker compose config`, which INLINES env_file values
# into environment maps (stack deploy ignores env_file) and resolves
# ${VAR} interpolation. The expanded stack file lands in
# .generated/stack-<role>.yml — machine-local, gitignored, contains the
# generated credentials (same trust level as the env files themselves).
# The docker-secrets refinement replaces that inlining later; refusals
# below say so honestly.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/state.sh"

show_help() {
    pol_box "pol swarm — swarm orchestration (isle-mesh stand-in)"
    echo -e "
${BOLD}CLUSTER${NC}
  ${CYAN}init${NC}              docker swarm init on this node (idempotent);
                    labels the node polari.machine=<name>
  ${CYAN}join <node>${NC}       drive a nodes.yml machine into the swarm over ssh
                    (worker join + polari.machine label; top-4)
  ${CYAN}status${NC}            swarm state, nodes, stacks, secrets overview
  ${CYAN}join-token${NC}        print worker/manager join commands

${BOLD}STACKS${NC}   (roles: engines | suite | node — see notes)
  ${CYAN}render <role>${NC}     expand the rendered compose bundle into a swarm
                    stack file (.generated/stack-<role>.yml)
  ${CYAN}deploy <role>${NC}     render + docker stack deploy polari-<role>
  ${CYAN}rm <role>${NC}         remove the stack
  ${CYAN}ps [role]${NC}         stack tasks across nodes
  ${CYAN}services${NC}          all swarm services

${BOLD}NOTES${NC}
  engines  safe alongside the compose stacks (own port) — the proving role
  suite    CONFLICTS with a running compose suite (ports 80/443) — stop
           the compose stack first (pol suite down)
  secrets  v1 inlines generated env values via 'docker compose config';
           docker-secrets mounting is the planned refinement
"
}

require_swarm() {
    docker info 2>/dev/null | grep -q "Swarm: active" || \
        die "swarm not active on this node — run: pol swarm init"
}

role_compose_cmd() {
    case "$1" in
        engines) echo "docker compose -f $POL_RF_NODE/docker-compose.msci-engines.yml" ;;
        node)    echo "docker compose -f $POL_RF_NODE/docker-compose.staging-nip.yml" ;;
        suite)   echo "docker compose -f $POL_SUITE_ROOT/docker-compose.staging-nip.yml --env-file $POL_SUITE_ROOT/.generated/.env.staging" ;;
        *) return 1 ;;
    esac
}

render_stack() {
    local role=$1
    local cmd; cmd=$(role_compose_cmd "$role") || die "unknown role '$role' (engines|suite|node)"
    # The compose bundles must exist — they do (they're the repo's root
    # files, themselves generated from pol-services/; see pol build help).
    export LOCAL_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
    mkdir -p "$POL_SUITE_ROOT/.generated"
    local out="$POL_SUITE_ROOT/.generated/stack-$role.yml"
    # compose config resolves env_files/interpolation; stackify.py then
    # applies the swarm-schema transforms (see its header for the list).
    # POL_STACK_CONSTRAINTS ("svc=expr svc2=expr2") come from the
    # topology's stacks.yml via pol topology apply / pol allocate.
    local cargs=()
    for c in ${POL_STACK_CONSTRAINTS:-}; do cargs+=(--constraint "$c"); done
    $cmd config 2>/dev/null | python3 "$POL_SUITE_ROOT/pol-build/tools/stackify.py" "${cargs[@]}" > "$out"
    [ -s "$out" ] || die "stack render produced nothing — is the $role compose bundle present? (pol build list / pol build render)"
    log_success "stack rendered: $out"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    init)
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            log_success "swarm already active on this node"
        else
            docker swarm init ${LOCAL_IP:+--advertise-addr "$LOCAL_IP"} >/dev/null || \
                die "swarm init failed — multiple IPs? export LOCAL_IP=<addr> and retry"
            log_success "swarm initialized (single node; 'pol swarm join <node>' to add more)"
        fi
        # placement constraints address machines by this stable label,
        # not by hostname (POLARI_LOCAL_NODE matches the topology's
        # machine row for this host).
        SELF_ID=$(docker info -f '{{.Swarm.NodeID}}' 2>/dev/null)
        [ -n "$SELF_ID" ] && docker node update --label-add "polari.machine=${POLARI_LOCAL_NODE:-staging-a}" "$SELF_ID" >/dev/null 2>&1 || true ;;
    join)
        NODE=${1:?usage: pol swarm join <node>   (see pol deploy nodes)}
        require_swarm
        NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"
        ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$NODE")
        [ -n "$ALIAS" ] || die "node '$NODE' not in nodes.yml (pol deploy nodes)"
        if docker node ls --format '{{.Hostname}} {{json .}}' 2>/dev/null | grep -q "polari.machine=$NODE"; then
            log_success "$NODE appears joined already (docker node ls)"
        fi
        MANAGER_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"
        TOKEN=$(docker swarm join-token -q worker)
        REMOTE_HOSTNAME=$(ssh -o ConnectTimeout=8 "$ALIAS" hostname) || die "ssh to $ALIAS failed — pol deploy preflight $NODE"
        if ssh "$ALIAS" "docker info 2>/dev/null | grep -q 'Swarm: active'"; then
            log_info "$NODE already in a swarm — skipping join"
        else
            ssh "$ALIAS" "docker swarm join --token $TOKEN $MANAGER_IP:2377" || die "join failed on $NODE"
        fi
        # stable placement label on the new node (constraints say
        # node.labels.polari.machine == $NODE)
        NODE_ID=$(docker node ls --format '{{.ID}} {{.Hostname}}' | awk -v h="$REMOTE_HOSTNAME" '$2==h{print $1}')
        [ -n "$NODE_ID" ] || die "joined but node '$REMOTE_HOSTNAME' not visible in docker node ls"
        docker node update --label-add "polari.machine=$NODE" "$NODE_ID" >/dev/null
        # reflect reality on the topology rows (row-write only)
        if docker ps --format '{{.Names}}' | grep -qx prf-backend; then
            printf '{"name": "%s", "swarm_role": "worker"}' "$NODE" | \
                docker exec -i prf-backend python3 -c "
import sys, urllib.request
req = urllib.request.Request('http://localhost:3000/api/topology/machine',
                             data=sys.stdin.buffer.read(),
                             headers={'Content-Type': 'application/json'})
print(urllib.request.urlopen(req, timeout=15).read().decode())" \
                && log_info "topology row updated: $NODE swarm_role=worker" \
                || log_warn "could not update the topology row — pol topology push later"
        fi
        docker node ls
        log_success "$NODE joined the swarm (label polari.machine=$NODE) — pol allocate <instance> $NODE to place work" ;;
    status)
        pol_box "swarm status"
        docker info 2>/dev/null | grep -A2 "Swarm:" | head -3 || true
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            echo; docker node ls; echo; docker stack ls 2>/dev/null || true
        else
            log_warn "swarm not active — pol swarm init"
        fi ;;
    join-token)
        require_swarm
        docker swarm join-token worker; docker swarm join-token manager ;;
    render)
        render_stack "${1:?role required (engines|suite|node)}" ;;
    deploy)
        ROLE=${1:?role required (engines|suite|node)}
        require_swarm
        if [ "$ROLE" != "engines" ] && docker ps --format '{{.Names}}' | grep -qE '^(pol-proxy|prf-proxy)$'; then
            die "a compose $ROLE stack is running — its published ports conflict. Stop it first (pol suite down / pol node down), then re-deploy."
        fi
        render_stack "$ROLE"
        docker stack deploy -c "$POL_SUITE_ROOT/.generated/stack-$ROLE.yml" "polari-$ROLE"
        record_build swarm "$ROLE" staging
        log_success "stack polari-$ROLE deployed — pol swarm ps $ROLE (pol start/rebuild/stop now shorthand this)" ;;
    relocate)
        # gm-5 (GRACEFUL_MOBILITY_PLAN): move the swarm BACKEND — an
        # owned-sqlite Polari instance — to another machine. QUIESCED,
        # stop-first (a stateful instance must never double-write),
        # honest measured downtime, every step a MoveOperation receipt.
        # The MoveOperation row itself is the data-loss marker: it is
        # created before the flush, so it MUST be visible on the
        # relocated instance or the copy lost data.
        # usage: pol swarm relocate <machine>   (backend only, v1)
        require_swarm
        TO=${1:?usage: pol swarm relocate <machine>}
        [ -n "${POLARI_CORE_URL:-}" ] || die "POLARI_CORE_URL required (the mover posts receipts + quiesce through the API)"
        SVC="polari-node_backend"
        VOL="polari-rf-node_backend-data"
        DBF="/app/data/managerObject_DB.db"
        api() { # method path [json-stdin]
            if [ "$1" = "POST" ]; then curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- "$POLARI_CORE_URL$2"; else curl -sk "$POLARI_CORE_URL$2"; fi
        }
        FROM=$(docker service inspect "$SVC" --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin) or []:
    if 'polari.machine' in c:
        print(c.split('==')[-1].strip()); break" || true)
        [ -n "$FROM" ] || die "cannot read $SVC's machine constraint — is the node stack deployed?"
        [ "$FROM" != "$TO" ] || die "backend already on $TO"
        NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"
        ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$TO" 2>/dev/null || true)
        SALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$FROM" 2>/dev/null || true)
        # '' alias = this machine (staging-a convention in nodes.yml)
        run_on_target() { if [ -n "$ALIAS" ]; then ssh "$ALIAS" "$@"; else bash -c "$*"; fi; }
        run_on_source() { if [ -n "$SALIAS" ]; then ssh "$SALIAS" "$@"; else bash -c "$*"; fi; }
        MOVE=$(printf '{"kind":"instance-move","subject":"backend","fromMachine":"%s","toMachine":"%s","triggeredBy":"pol swarm relocate"}' "$FROM" "$TO" | api POST /api/topology/move-operations | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['move']['name'] if d.get('ok') else '')")
        [ -n "$MOVE" ] || die "MoveOperation row not created — backend unreachable at $POLARI_CORE_URL"
        mv_step() { printf '{"name":"%s","step":"%s","status":"%s","receipt":"%s"}' "$MOVE" "$1" "$2" "${3:-}" | api POST /api/topology/move-operations/step >/dev/null || true; }
        mv_fail() { # error [release-quiesce]
            printf '{"name":"%s","status":"failed","error":"%s"}' "$MOVE" "$1" | api POST /api/topology/move-operations/finish >/dev/null || true
            [ "${2:-}" = "release" ] && echo '{}' | api POST /api/quiesce/release >/dev/null || true
            die "$1"
        }
        TASK=$(run_on_source "docker ps -q -f name=$SVC" | head -1)
        [ -n "$TASK" ] || mv_fail "no running $SVC task found on $FROM"
        # Same tag never means same code across nodes — swarm ships
        # CONFIG, not images. Compare image IDs; ship on mismatch.
        mv_step sync-image running
        IMG="prf-backend:staging"
        LOCAL_ID=$(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null || true)
        TARGET_ID=$(run_on_target "docker image inspect $IMG --format '{{.Id}}'" 2>/dev/null || true)
        if [ -n "$LOCAL_ID" ] && [ "$LOCAL_ID" != "$TARGET_ID" ]; then
            log_info "image content differs on $TO — shipping $IMG"
            docker save "$IMG" | run_on_target "docker load" || mv_fail "image sync to $TO failed"
            mv_step sync-image done "shipped $IMG (content differed)"
        else
            mv_step sync-image done "image IDs match on $TO"
        fi
        mv_step quiesce running
        # Engage with a SHORT call, then POLL status — the flush can
        # take minutes-to-an-hour (measured: 2758s on a slow disk;
        # persistTree is row-by-row until mlb-5b batches it) and a
        # single long POST outlives every proxy timeout.
        printf '{"reason":"instance relocation","moveName":"%s"}' "$MOVE" | timeout 30 curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- --max-time 25 "$POLARI_CORE_URL/api/quiesce" >/dev/null 2>&1 || true
        QOK=""
        for i in $(seq 1 720); do  # up to 2h — flush time is honest, not bounded
            ST=$(api GET /api/quiesce/status | python3 -c "
import json,sys
d = json.load(sys.stdin)
r = d.get('receipt') or {}
if d.get('quiesced') and r.get('persisted'):
    print('done', r.get('flushSeconds'))
elif d.get('quiesced') and r.get('error'):
    print('error', r.get('error'))
elif d.get('quiesced'):
    print('flushing')
else:
    print('idle')" 2>/dev/null || echo poll-failed)
            case "$ST" in
                done*) QOK="${ST#done }"; break ;;
                error*) mv_fail "quiesce flush failed: ${ST#error }" release ;;
            esac
            sleep 10
        done
        [ -n "$QOK" ] || mv_fail "quiesce flush never completed — gate left UP for inspection (release manually: POST /api/quiesce/release)"
        mv_step quiesce done "gate up + flushed in ${QOK}s (in-flight 0)"
        mv_step snapshot running
        COUNT_PY="import sqlite3;c=sqlite3.connect('$DBF');ts=[r[0] for r in c.execute('select name from sqlite_master where type=' + chr(39) + 'table' + chr(39))];total=sum(c.execute('select count(*) from ' + chr(34) + t + chr(34)).fetchone()[0] for t in ts);dd=c.execute('select count(*) from DigitizedDataset').fetchone()[0] if 'DigitizedDataset' in ts else -1;print(len(ts), total, dd)"
        SNAP=$(run_on_source "docker exec $TASK python3 -c \"$COUNT_PY\"") || mv_fail "snapshot failed" release
        read -r NTAB NROW NDD <<< "$SNAP"
        mv_step snapshot done "$NTAB tables / $NROW rows (DigitizedDataset $NDD)"
        mv_step copy-data running
        run_on_target "docker volume create $VOL" >/dev/null 2>&1 || true
        run_on_source "docker exec $TASK tar -C /app/data -cf - ." | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'rm -rf /data/* && tar -C /data -xf -'" || mv_fail "data copy to $TO failed" release
        mv_step copy-data done "sqlite volume copied to $TO ($VOL)"
        # Second pass captures the receipt row just written (quiesced,
        # so nothing else changed) — the copy stays exactly consistent.
        run_on_source "docker exec $TASK tar -C /app/data -cf - ." | run_on_target "docker run --rm -i -v $VOL:/data alpine tar -C /data -xf -" || mv_fail "consistency re-copy failed" release
        # Pre-boot file verify: the COPIED FILE must match the source
        # exactly (post-boot totals legitimately SHRINK — restore
        # dedupes historical duplicate rows, then persistTree rewrites
        # clean; stable tables + the marker are the post-boot checks).
        FROW=$(run_on_target "docker run --rm -v $VOL:/app/data prf-backend:staging python3 -c \"$COUNT_PY\"" 2>/dev/null | awk '{print $2}' || true)
        [ "$FROW" = "$NROW" ] || mv_fail "copied file has $FROW rows != source $NROW — copy inconsistent" release
        mv_step service-update running
        T0=$(date +%s)
        docker service update --update-order stop-first \
            --constraint-rm "node.labels.polari.machine==$FROM" \
            --constraint-add "node.labels.polari.machine==$TO" \
            --detach "$SVC" >/dev/null || mv_fail "service update failed" release
        mv_step service-update done "stop-first constraint swap issued"
        mv_step boot-ready running
        # Placement FIRST (health can answer from the old task while
        # the stop-first swap is still converging), then core-ready.
        PLACED=""
        for i in $(seq 1 60); do
            NODE=$(docker service ps "$SVC" --filter desired-state=running --format '{{.Node}}' | head -1)
            ON=$(docker node inspect "$NODE" --format '{{index .Spec.Labels "polari.machine"}}' 2>/dev/null || true)
            [ "$ON" = "$TO" ] && PLACED=1 && break
            sleep 3
        done
        [ -n "$PLACED" ] || mv_fail "task never placed on $TO"
        READY=""
        for i in $(seq 1 90); do
            if curl -skf --max-time 4 "$POLARI_CORE_URL/api/health" >/dev/null 2>&1; then READY=1; break; fi
            sleep 5
        done
        [ -n "$READY" ] || mv_fail "relocated backend never reached core-ready"
        DOWN=$(( $(date +%s) - T0 ))
        mv_step boot-ready done "core-ready on $TO; measured downtime ~${DOWN}s (update -> /api/health 200)"
        mv_step verify-data running
        TTASK=$(run_on_target "docker ps -q -f name=$SVC" | head -1)
        [ -n "$TTASK" ] || mv_fail "no $SVC task running on $TO"
        VER=$(run_on_target "docker exec $TTASK python3 -c \"$COUNT_PY\"") || mv_fail "target row count failed"
        read -r TTAB TROW TDD <<< "$VER"
        # Post-boot: totals legitimately SHRINK (restore dedupes then
        # persistTree rewrites clean) — the invariants are the table
        # count, stable definition tables, and the marker row that
        # traveled inside the copied DB.
        [ "$TTAB" = "$NTAB" ] || mv_fail "DATA LOSS: target has $TTAB tables != snapshot $NTAB"
        [ "$TDD" = "$NDD" ] || mv_fail "DATA LOSS: DigitizedDataset $TDD != snapshot $NDD"
        MARKER=$(api GET "/api/topology/move-operations" | python3 -c "import json,sys; d=json.load(sys.stdin); print('1' if any(m['name']=='$MOVE' for m in d.get('moves',[])) else '')")
        [ -n "$MARKER" ] || mv_fail "marker MoveOperation row missing on relocated instance"
        mv_step verify-data done "tables $TTAB==$NTAB; DigitizedDataset $TDD==$NDD; marker present; rows $TROW post-dedup (copied file matched $NROW exactly pre-boot)"
        mv_step retire done "old volume $VOL kept on $FROM as the rollback copy"
        printf '{"name":"%s","status":"verified"}' "$MOVE" | api POST /api/topology/move-operations/finish >/dev/null || true
        log_success "backend relocated $FROM -> $TO (downtime ~${DOWN}s; MoveOperation $MOVE)"
        log_info "row updated? also run: pol allocate prf-a $TO  (topology row) — and the old volume on $FROM is the rollback" ;;
    rm)
        require_swarm
        docker stack rm "polari-${1:?role required}" ;;
    ps)
        require_swarm
        if [ -n "$1" ]; then docker stack ps "polari-$1" --no-trunc | head -20
        else docker stack ls; fi ;;
    services)
        require_swarm
        docker service ls ;;
    secrets)
        die "docker-secrets mounting is the planned refinement — v1 inlines generated env values into the stack file via 'docker compose config' (see pol swarm help, STACKS notes)." ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown swarm command: $COMMAND"; show_help; exit 1 ;;
esac
