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
source "$SCRIPT_DIR/lib/core-api.sh"

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
    # mod-env-3: module enablement is topology ROWS, not a
    # hand-maintained env string. For the node/suite roles the
    # POLARI_MODULES baked into the stack is DERIVED from the core's
    # ModuleAssignment rows; a pre-set env var still wins but is
    # loudly named an override.
    case "$role" in
        node|suite) resolve_polari_modules "${POLARI_MODULES_INSTANCE:-prf-a}" ;;
    esac
    # The compose bundles must exist — they do (they're the repo's root
    # files, themselves generated from pol-services/; see pol build help).
    export LOCAL_IP="${LOCAL_IP:-$(lan_ip)}"
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
        [ -n "$SELF_ID" ] && docker node update --label-add "polari.machine=${POLARI_LOCAL_NODE:-pol-core}" "$SELF_ID" >/dev/null 2>&1 || true ;;
    join)
        NODE=${1:?usage: pol swarm join <node>   (see pol deploy nodes)}
        require_swarm
        NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"
        ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$NODE")
        [ -n "$ALIAS" ] || die "node '$NODE' not in nodes.yml (pol deploy nodes)"
        if docker node ls --format '{{.Hostname}} {{json .}}' 2>/dev/null | grep -q "polari.machine=$NODE"; then
            log_success "$NODE appears joined already (docker node ls)"
        fi
        MANAGER_IP="${LOCAL_IP:-$(lan_ip)}"
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
        # gm-5 + gm-3 (GRACEFUL_MOBILITY_PLAN): move a STATEFUL swarm
        # service — the backend (owned sqlite) or a sidecar (MinIO;
        # KeyDB when a stack deploys one) — to another machine.
        # QUIESCED, stop-first, staged-copy discipline (no deletion
        # before confirmation; live target data untouched until the
        # verified swap; journals in both volumes; source volume
        # never deleted). Every step a MoveOperation receipt.
        # usage: pol swarm relocate [backend|file-store|keydb|keycloak|mariadb] <machine>
        require_swarm
        if [ -n "${2:-}" ]; then WHATSVC=$1; TO=$2; else WHATSVC=backend; TO=${1:?usage: pol swarm relocate [backend|file-store|keydb|keycloak|mariadb] <machine>}; fi
        [ -n "${POLARI_CORE_URL:-}" ] || die "POLARI_CORE_URL required (the mover posts receipts + quiesce through the API)"
        case "$WHATSVC" in
            backend)
                SVC="polari-node_backend"; VOL="polari-rf-node_backend-data"
                IMG="prf-backend:staging"; KIND="instance-move"
                SUBJECT="backend"; VERIFY="sqlite" ;;
            file-store)
                SVC="polari-node_prf-file-store"; VOL="polari-rf-node_file-store-data"
                IMG="prf-file-store:staging"; KIND="minio-move"
                SUBJECT="prf-file-store"; VERIFY="files" ;;
            keydb)
                die "no KeyDB service in the node stack (PSC/suite side) — the generic staged mover supports it once deployed (kind keydb-move); the zero-cold-cache replica-promote route is the gm-3 refinement, not built" ;;
            mariadb)
                # gm-5: THE careful one. v1 correct-before-clever:
                # drain the writers (Keycloak — measured auth window,
                # never a torn write), mysqldump = backup + semantic
                # receipt, staged volume copy with the DB STOPPED
                # (perfectly consistent), swap, verify counts against
                # the receipt, restore writers. Source volume + dump
                # both kept. v2 replica-promote = refinement.
                SVC="polari-node_prf-mariadb"
                VOL="polari-rf-node_prf-mariadb-data"
                IMG="prf-mariadb:staging"
                KCSVC="polari-node_prf-keycloak"
                TO_DB=$TO
                api() { if [ "$1" = "POST" ]; then curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- "$POLARI_CORE_URL$2"; else curl -sk "$POLARI_CORE_URL$2"; fi; }
                db_stable() {
                    local st
                    st=$(docker service inspect "$1" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)
                    case "$st" in updating|paused|rollback_started|rollback_paused) die "service $1 has an update in progress ($st) — wait, then retry" ;; esac
                }
                db_stable "$SVC"; db_stable "$KCSVC"; db_stable "polari-node_backend"
                FROM=$(docker service inspect "$SVC" --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin) or []:
    if 'polari.machine' in c:
        print(c.split('==')[-1].strip()); break" || true)
                [ -n "$FROM" ] || die "cannot read $SVC's machine constraint"
                [ "$FROM" != "$TO_DB" ] || die "mariadb already on $TO_DB"
                NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"
                ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$TO_DB" 2>/dev/null || true)
                SALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$FROM" 2>/dev/null || true)
                run_on_target() { if [ -n "$ALIAS" ]; then ssh "$ALIAS" "$@"; else bash -c "$*"; fi; }
                run_on_source() { if [ -n "$SALIAS" ]; then ssh "$SALIAS" "$@"; else bash -c "$*"; fi; }
                MOVE=$(printf '{"kind":"database-move","subject":"prf-mariadb","fromMachine":"%s","toMachine":"%s","triggeredBy":"pol swarm relocate"}' "$FROM" "$TO_DB" | api POST /api/topology/move-operations | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['move']['name'] if d.get('ok') else '')")
                [ -n "$MOVE" ] || die "MoveOperation row not created — backend unreachable at $POLARI_CORE_URL"
                mv_step() { printf '{"name":"%s","step":"%s","status":"%s","receipt":"%s"}' "$MOVE" "$1" "$2" "${3:-}" | api POST /api/topology/move-operations/step >/dev/null || true; }
                mv_fail() {
                    # Best-effort restoration FIRST: a failed DB move
                    # must never strand auth down.
                    docker service scale "$SVC"=1 --detach >/dev/null 2>&1 || true
                    docker service scale "$KCSVC"=1 --detach >/dev/null 2>&1 || true
                    printf '{"name":"%s","status":"failed","error":"%s (writers + DB scale-1 re-issued best-effort)"}' "$MOVE" "$1" | api POST /api/topology/move-operations/finish >/dev/null || true
                    die "$1"
                }
                db_counts() { # host-runner task-id -> "realms clients users tables"
                    $1 "docker exec $2 sh -c 'mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -N -e \"SELECT (SELECT COUNT(*) FROM keycloak.REALM), (SELECT COUNT(*) FROM keycloak.CLIENT), (SELECT COUNT(*) FROM keycloak.USER_ENTITY), (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=CHAR(107,101,121,99,108,111,97,107))\"'" 2>/dev/null | tr '\t' ' '
                }
                mv_step preflight running
                run_on_target "true" >/dev/null 2>&1 || mv_fail "target $TO_DB unreachable"
                SRC_KB=$(run_on_source "docker run --rm -v $VOL:/data alpine du -sk /data" | awk '{print $1}')
                TGT_FREE_KB=$(run_on_target "df -k /var/lib/docker 2>/dev/null || df -k /" | tail -1 | awk '{print $4}')
                [ -n "$SRC_KB" ] && [ "$TGT_FREE_KB" -ge $((SRC_KB * 3)) ] || mv_fail "target $TO_DB too full or unsized (free ${TGT_FREE_KB:-?}KB vs 3x ${SRC_KB:-?}KB)"
                mv_step preflight done "source ${SRC_KB}KB; target free ${TGT_FREE_KB}KB; no updates converging"
                mv_step sync-image running
                LOCAL_ID=$(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null || true)
                TARGET_ID=$(run_on_target "docker image inspect $IMG --format '{{.Id}}'" 2>/dev/null || true)
                if [ -n "$LOCAL_ID" ] && [ "$LOCAL_ID" != "$TARGET_ID" ]; then
                    docker save "$IMG" | run_on_target "docker load" || mv_fail "image sync to $TO_DB failed"
                    mv_step sync-image done "shipped $IMG (content differed)"
                else
                    mv_step sync-image done "image IDs match on $TO_DB"
                fi
                mv_step writers-drain running
                T_AUTH0=$(date +%s)
                docker service scale "$KCSVC"=0 --detach=false >/dev/null 2>&1 || mv_fail "could not drain keycloak"
                mv_step writers-drain done "keycloak scaled to 0 (the only MariaDB writer) — auth window open, measured"
                mv_step backup-dump running
                STASK=$(run_on_source "docker ps -q -f name=$SVC" | head -1)
                [ -n "$STASK" ] || mv_fail "no running $SVC task on $FROM"
                PRECOUNTS=$(db_counts run_on_source "$STASK")
                BAKDIR="$POL_SUITE_ROOT/.generated/backups"; mkdir -p "$BAKDIR"
                BAK="$BAKDIR/keycloak-$MOVE.sql"
                run_on_source "docker exec $STASK sh -c 'mariadb-dump -uroot -p\"\$MARIADB_ROOT_PASSWORD\" --single-transaction keycloak'" > "$BAK" || mv_fail "mysqldump failed"
                BAKSZ=$(du -k "$BAK" | awk '{print $1}')
                [ "$BAKSZ" -gt 0 ] || mv_fail "dump file is empty"
                mv_step backup-dump done "dump ${BAKSZ}KB -> .generated/backups/ (the backup AND the baseline: counts=$PRECOUNTS)"
                mv_step quiesce-db running
                T_DB0=$(date +%s)
                docker service scale "$SVC"=0 --detach=false >/dev/null 2>&1 || mv_fail "could not stop mariadb"
                mv_step quiesce-db done "DB scaled to 0 — volume perfectly still"
                mv_step copy-data running
                STAGE=".incoming-${MOVE}"; PREV=".previous-${MOVE}"
                JLINE="{\"move\":\"$MOVE\",\"from\":\"$FROM\",\"to\":\"$TO_DB\",\"phase\":\"copying\",\"at\":$(date +%s)}"
                printf '%s' "$JLINE" | run_on_source "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
                run_on_target "docker volume create $VOL" >/dev/null 2>&1 || true
                printf '%s' "$JLINE" | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
                run_on_source "docker run --rm -v $VOL:/data alpine tar -C /data -cf - ." | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'rm -rf /data/$STAGE && mkdir -p /data/$STAGE && tar -C /data/$STAGE -xf -'" || mv_fail "staged copy failed — live target data untouched; re-run to resume"
                SRCN=$(run_on_source "docker run --rm -v $VOL:/data alpine sh -c 'find /data -type f -not -name .move-journal.json | wc -l'" | tr -d ' ')
                TGTN=$(run_on_target "docker run --rm -v $VOL:/data alpine sh -c 'find /data/$STAGE -type f -not -name .move-journal.json | wc -l'" | tr -d ' ')
                [ -n "$SRCN" ] && [ "$SRCN" = "$TGTN" ] || mv_fail "staged copy has ${TGTN:-?} files != source ${SRCN:-?} — inconsistent; live target data untouched"
                run_on_target "docker run --rm -v $VOL:/data alpine sh -c 'mkdir -p /data/$PREV && for f in /data/*; do [ -e \"\$f\" ] || continue; mv \"\$f\" /data/$PREV/; done; mv /data/$STAGE/* /data/ 2>/dev/null; for d in /data/$STAGE/.[!.]*; do [ -e \"\$d\" ] && [ \"\$(basename \$d)\" != .move-journal.json ] && mv \"\$d\" /data/ || true; done; rm -rf /data/$STAGE'" || mv_fail "swap failed — staged + $PREV both on $TO_DB, journal marks the state"
                printf '%s' "${JLINE/copying/swapped}" | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
                mv_step copy-data done "staged copy verified ($SRCN files) then swapped; journals in both volumes"
                mv_step service-update running
                docker service update --constraint-rm "node.labels.polari.machine==$FROM" --constraint-add "node.labels.polari.machine==$TO_DB" --detach "$SVC" >/dev/null || mv_fail "constraint swap failed"
                docker service scale "$SVC"=1 --detach >/dev/null 2>&1 || true
                mv_step service-update done "constraint swapped + scaled back up on $TO_DB"
                mv_step boot-ready running
                READY=""
                for i in $(seq 1 60); do
                    STATE=$(run_on_target "docker ps --filter name=$SVC --format '{{.Status}}'" | head -1)
                    case "$STATE" in *healthy*) READY=1; break ;; esac
                    sleep 5
                done
                [ -n "$READY" ] || mv_fail "relocated mariadb never became healthy on $TO_DB"
                DB_WIN=$(( $(date +%s) - T_DB0 ))
                mv_step boot-ready done "healthy on $TO_DB; DB window ~${DB_WIN}s (stop -> healthy)"
                mv_step verify-data running
                TTASK=$(run_on_target "docker ps -q -f name=$SVC" | head -1)
                POSTCOUNTS=$(db_counts run_on_target "$TTASK")
                [ -n "$POSTCOUNTS" ] && [ "$POSTCOUNTS" = "$PRECOUNTS" ] || mv_fail "DATA LOSS: counts '$POSTCOUNTS' != receipt '$PRECOUNTS' (realms clients users tables)"
                docker service scale "$KCSVC"=1 --detach >/dev/null 2>&1 || true
                KCOK=""
                for i in $(seq 1 90); do
                    if curl -skf --max-time 4 "https://auth.prf.${LOCAL_IP:-192.168.0.210}.nip.io/realms/Polari/protocol/openid-connect/certs" >/dev/null 2>&1; then KCOK=1; break; fi
                    sleep 5
                done
                [ -n "$KCOK" ] || mv_fail "keycloak did not recover against the relocated DB"
                AUTH_WIN=$(( $(date +%s) - T_AUTH0 ))
                mv_step verify-data done "counts match receipt ($PRECOUNTS = realms clients users tables); keycloak recovered, JWKS answers; auth window ~${AUTH_WIN}s"
                mv_step retire running
                run_on_target "docker run --rm -v $VOL:/data alpine sh -c 'rm -rf /data/$PREV /data/.incoming-* && rm -f /data/.move-journal.json'" >/dev/null 2>&1 || true
                printf '{"move":"%s","from":"%s","to":"%s","phase":"retired-moved-to-%s","at":%s}' "$MOVE" "$FROM" "$TO_DB" "$TO_DB" "$(date +%s)" | run_on_source "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
                mv_step retire done "source volume kept on $FROM (rollback) + dump kept in .generated/backups/; journals settled"
                printf '{"name":"%s","status":"verified"}' "$MOVE" | api POST /api/topology/move-operations/finish >/dev/null || true
                docker service ps "$SVC" --format '{{.Name}}\t{{.Node}}\t{{.CurrentState}}' | head -3
                log_success "mariadb relocated $FROM -> $TO_DB (DB window ~${DB_WIN}s, auth window ~${AUTH_WIN}s; MoveOperation $MOVE)"
                exit 0 ;;
            keycloak)
                # gm-4: SERVER-ONLY move — realms/clients/KEYS live in
                # MariaDB, which does NOT move (keycloak+DB in one
                # step is refused: two moves, DB first). Blue-green
                # start-first: old serves until new runs; the issuer
                # hostname never changes, so existing tokens stay
                # valid. No quiesce, no volumes, nothing deleted.
                SVC="polari-node_prf-keycloak"
                IMG="prf-keycloak:staging"
                DBSVC="polari-node_prf-mariadb"
                TO_KC=$TO
                api() { if [ "$1" = "POST" ]; then curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- "$POLARI_CORE_URL$2"; else curl -sk "$POLARI_CORE_URL$2"; fi; }
                kc_stable() {
                    local st
                    st=$(docker service inspect "$1" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)
                    case "$st" in updating|paused|rollback_started|rollback_paused) die "service $1 has an update in progress ($st) — wait, then retry" ;; esac
                }
                kc_stable "$SVC"; kc_stable "$DBSVC"; kc_stable "polari-node_backend"
                FROM=$(docker service inspect "$SVC" --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin) or []:
    if 'polari.machine' in c:
        print(c.split('==')[-1].strip()); break" || true)
                [ -n "$FROM" ] || die "cannot read $SVC's machine constraint"
                [ "$FROM" != "$TO_KC" ] || die "keycloak already on $TO_KC"
                NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"
                ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$TO_KC" 2>/dev/null || true)
                run_on_target() { if [ -n "$ALIAS" ]; then ssh "$ALIAS" "$@"; else bash -c "$*"; fi; }
                MOVE=$(printf '{"kind":"auth-move","subject":"prf-keycloak","fromMachine":"%s","toMachine":"%s","triggeredBy":"pol swarm relocate"}' "$FROM" "$TO_KC" | api POST /api/topology/move-operations | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['move']['name'] if d.get('ok') else '')")
                [ -n "$MOVE" ] || die "MoveOperation row not created — backend unreachable at $POLARI_CORE_URL"
                mv_step() { printf '{"name":"%s","step":"%s","status":"%s","receipt":"%s"}' "$MOVE" "$1" "$2" "${3:-}" | api POST /api/topology/move-operations/step >/dev/null || true; }
                mv_fail() { printf '{"name":"%s","status":"failed","error":"%s"}' "$MOVE" "$1" | api POST /api/topology/move-operations/finish >/dev/null || true; die "$1"; }
                AUTH_BASE="${POLARI_AUTH_URL:-https://auth.prf.${LOCAL_IP:-192.168.0.210}.nip.io}"
                JWKS="$AUTH_BASE/realms/Polari/protocol/openid-connect/certs"
                mv_step preflight running
                run_on_target "true" >/dev/null 2>&1 || mv_fail "target $TO_KC unreachable"
                curl -skf --max-time 6 "$JWKS" >/dev/null || mv_fail "keycloak is not healthy BEFORE the move (JWKS unreachable) — fix auth first, then move"
                mv_step preflight done "target reachable; JWKS answers pre-move; no updates converging"
                mv_step db-check running
                ACTIVE_DB_MOVE=$(api GET "/api/topology/move-operations?active=true" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print('1' if any(m['kind'] == 'database-move' or m['subject'] == 'prf-mariadb'
                 for m in d.get('moves', []) if m['name'] != '$MOVE') else '')" 2>/dev/null || true)
                [ -z "$ACTIVE_DB_MOVE" ] || mv_fail "the DB is ALSO moving — keycloak+DB in one step is two moves, DB first (gm-5), then this"
                DBSTATE=$(docker ps --filter name=$DBSVC --format '{{.Status}}' | head -1)
                case "$DBSTATE" in *healthy*) ;; *) mv_fail "prf-mariadb is not healthy ($DBSTATE) — the server-only move needs its DB answering" ;; esac
                mv_step db-check done "DB healthy + not moving; server-only move is legal"
                mv_step sync-image running
                LOCAL_ID=$(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null || true)
                TARGET_ID=$(run_on_target "docker image inspect $IMG --format '{{.Id}}'" 2>/dev/null || true)
                if [ -n "$LOCAL_ID" ] && [ "$LOCAL_ID" != "$TARGET_ID" ]; then
                    log_info "image content differs on $TO_KC — shipping $IMG"
                    docker save "$IMG" | run_on_target "docker load" || mv_fail "image sync to $TO_KC failed"
                    mv_step sync-image done "shipped $IMG (content differed)"
                else
                    mv_step sync-image done "image IDs match on $TO_KC"
                fi
                # Blue-green REQUIRES a readiness-gated healthcheck:
                # an ungated JVM container is "running" in seconds but
                # serves minutes later (measured as an outage). Apply
                # it to the live service if absent — this transition
                # is itself start-first + gated, so zero-downtime.
                HC=$(docker service inspect "$SVC" --format '{{json .Spec.TaskTemplate.ContainerSpec.Healthcheck}}' 2>/dev/null)
                if [ "$HC" = "null" ] || [ -z "$HC" ]; then
                    log_info "no healthcheck on $SVC — applying one (prerequisite for a zero-downtime swap)"
                    docker service update --update-order start-first \
                        --health-cmd "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /realms/master HTTP/1.0\r\n\r\n' >&3 && head -1 <&3 | grep -q 200" \
                        --health-interval 15s --health-timeout 10s \
                        --health-start-period 300s --health-retries 3 \
                        --detach=false "$SVC" >/dev/null || mv_fail "could not apply the readiness healthcheck"
                fi
                # Token continuity evidence: the SIGNING KEYS must be
                # identical after the move (same DB = same keys ⇒
                # every existing token/session stays valid; a raw
                # access token expires in ~60s, shorter than any
                # move — comparing kids is the honest check).
                PRE_KIDS=$(curl -sk --max-time 8 "$JWKS" | python3 -c "import json,sys; print(','.join(sorted(k['kid'] for k in json.load(sys.stdin).get('keys',[]))))" 2>/dev/null || true)
                mv_step service-update running
                docker service update --update-order start-first \
                    --constraint-rm "node.labels.polari.machine==$FROM" \
                    --constraint-add "node.labels.polari.machine==$TO_KC" \
                    --detach=false "$SVC" >/dev/null || mv_fail "service update failed"
                mv_step service-update done "start-first constraint swap converged (old served until new ran)"
                mv_step readiness running
                READY=""
                for i in $(seq 1 90); do
                    NODE=$(docker service ps "$SVC" --filter desired-state=running --format '{{.Node}}' | head -1)
                    ON=$(docker node inspect "$NODE" --format '{{index .Spec.Labels "polari.machine"}}' 2>/dev/null || true)
                    if [ "$ON" = "$TO_KC" ] && curl -skf --max-time 5 "$JWKS" >/dev/null 2>&1; then READY=1; break; fi
                    sleep 5
                done
                [ -n "$READY" ] || mv_fail "relocated keycloak never answered realm/JWKS on $TO_KC"
                mv_step readiness done "task on $TO_KC; realm + JWKS answer through the proxy (issuer unchanged)"
                mv_step verify running
                POST_KIDS=$(curl -sk --max-time 8 "$JWKS" | python3 -c "import json,sys; print(','.join(sorted(k['kid'] for k in json.load(sys.stdin).get('keys',[]))))" 2>/dev/null || true)
                if [ -n "$PRE_KIDS" ]; then
                    [ "$POST_KIDS" = "$PRE_KIDS" ] || mv_fail "SIGNING KEYS CHANGED across the move ($PRE_KIDS -> $POST_KIDS) — token continuity broken; did the DB move too?"
                    TOKOK="signing keys identical (kids unchanged) — existing tokens/sessions stay valid"
                else
                    TOKOK="pre-move kids unavailable — post-move kids: ${POST_KIDS:-none}"
                fi
                JH=$(api GET /auth/jwks-health | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok' if d.get('ok') or d.get('healthy') else json.dumps(d)[:60].replace(chr(34), chr(39)))" 2>/dev/null || echo unavailable)
                mv_step verify done "$TOKOK; backend jwks-health: $JH"
                mv_step retire done "nothing to delete — no data moved (realms/keys live in $DBSVC, untouched)"
                printf '{"name":"%s","status":"verified"}' "$MOVE" | api POST /api/topology/move-operations/finish >/dev/null || true
                docker service ps "$SVC" --format '{{.Name}}\t{{.Node}}\t{{.CurrentState}}' | head -3
                log_success "keycloak relocated $FROM -> $TO_KC (blue-green; MoveOperation $MOVE)"
                exit 0 ;;
            *) die "unknown service '$WHATSVC' (backend|file-store|keydb|keycloak|mariadb)" ;;
        esac
        api() { # method path [json-stdin]
            if [ "$1" = "POST" ]; then curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- "$POLARI_CORE_URL$2"; else curl -sk "$POLARI_CORE_URL$2"; fi
        }
        # gm-safety guard: NEVER start a move while a service update
        # is converging — a raced move's gate gets wiped by the
        # restart (learned live, backend@1785180981).
        ensure_stable() {
            local st
            st=$(docker service inspect "$1" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)
            case "$st" in
                updating|paused|rollback_started|rollback_paused)
                    die "service $1 has an update in progress ($st) — wait for convergence, then retry the move" ;;
            esac
        }
        ensure_stable "$SVC"
        ensure_stable "polari-node_backend"  # quiesce + receipts ride it
        FROM=$(docker service inspect "$SVC" --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin) or []:
    if 'polari.machine' in c:
        print(c.split('==')[-1].strip()); break" || true)
        [ -n "$FROM" ] || die "cannot read $SVC's machine constraint — is the node stack deployed?"
        [ "$FROM" != "$TO" ] || die "$SUBJECT already on $TO"
        NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"
        ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$TO" 2>/dev/null || true)
        SALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$FROM" 2>/dev/null || true)
        # '' alias = this machine (pol-core convention in nodes.yml)
        run_on_target() { if [ -n "$ALIAS" ]; then ssh "$ALIAS" "$@"; else bash -c "$*"; fi; }
        run_on_source() { if [ -n "$SALIAS" ]; then ssh "$SALIAS" "$@"; else bash -c "$*"; fi; }
        MOVE=$(printf '{"kind":"%s","subject":"%s","fromMachine":"%s","toMachine":"%s","triggeredBy":"pol swarm relocate"}' "$KIND" "$SUBJECT" "$FROM" "$TO" | api POST /api/topology/move-operations | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['move']['name'] if d.get('ok') else '')")
        [ -n "$MOVE" ] || die "MoveOperation row not created — backend unreachable at $POLARI_CORE_URL"
        mv_step() { printf '{"name":"%s","step":"%s","status":"%s","receipt":"%s"}' "$MOVE" "$1" "$2" "${3:-}" | api POST /api/topology/move-operations/step >/dev/null || true; }
        mv_fail() { # error [release-quiesce]
            printf '{"name":"%s","status":"failed","error":"%s"}' "$MOVE" "$1" | api POST /api/topology/move-operations/finish >/dev/null || true
            [ "${2:-}" = "release" ] && echo '{}' | api POST /api/quiesce/release >/dev/null || true
            die "$1"
        }
        # All data ops are VOLUME-level (docker run alpine / backend
        # image) — uniform across services whose containers lack
        # tar/find (MinIO), and across source/target hosts.
        vol_src() { run_on_source "docker run --rm -v $VOL:/data alpine $*"; }
        vol_tgt() { run_on_target "docker run --rm -v $VOL:/data alpine $*"; }
        # gm-safety preflight: fail EARLY, never mid-copy.
        mv_step preflight running
        run_on_target "true" >/dev/null 2>&1 || mv_fail "target $TO unreachable"
        SRC_KB=$(vol_src "du -sk /data" | awk '{print $1}')
        TGT_FREE_KB=$(run_on_target "df -k /var/lib/docker 2>/dev/null || df -k /" | tail -1 | awk '{print $4}')
        [ -n "$SRC_KB" ] && [ -n "$TGT_FREE_KB" ] || mv_fail "cannot size source/target (src=${SRC_KB:-?}KB free=${TGT_FREE_KB:-?}KB)"
        [ "$TGT_FREE_KB" -ge $((SRC_KB * 3)) ] || mv_fail "target $TO too full: ${TGT_FREE_KB}KB free < 3x source ${SRC_KB}KB — refusing before touching anything"
        mv_step preflight done "source ${SRC_KB}KB; target free ${TGT_FREE_KB}KB (>=3x ok); no update converging"
        # Same tag never means same code/content across nodes.
        mv_step sync-image running
        LOCAL_ID=$(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null || true)
        TARGET_ID=$(run_on_target "docker image inspect $IMG --format '{{.Id}}'" 2>/dev/null || true)
        if [ -n "$LOCAL_ID" ] && [ "$LOCAL_ID" != "$TARGET_ID" ]; then
            log_info "image content differs on $TO — shipping $IMG"
            docker save "$IMG" | run_on_target "docker load" || mv_fail "image sync to $TO failed"
            mv_step sync-image done "shipped $IMG (content differed)"
        else
            mv_step sync-image done "image IDs match on $TO"
        fi
        # Quiesce: short engage + poll (a flush can take minutes and
        # one long POST outlives proxy timeouts). For sidecar moves
        # the BACKEND gate is the upload gate — writes flow through
        # it. Idempotent per moveName -> a crashed move resumes.
        mv_step quiesce running
        printf '{"reason":"%s relocation","moveName":"%s"}' "$SUBJECT" "$MOVE" | timeout 30 curl -sk -X POST -H 'Content-Type: application/json' --data-binary @- --max-time 25 "$POLARI_CORE_URL/api/quiesce" >/dev/null 2>&1 || true
        QOK=""
        for i in $(seq 1 720); do
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
        # Snapshot: the verify baseline (kind-specific).
        mv_step snapshot running
        if [ "$VERIFY" = "sqlite" ]; then
            COUNT_PY="import sqlite3;c=sqlite3.connect('/data/managerObject_DB.db');ts=[r[0] for r in c.execute('select name from sqlite_master where type=' + chr(39) + 'table' + chr(39))];total=sum(c.execute('select count(*) from ' + chr(34) + t + chr(34)).fetchone()[0] for t in ts);dd=c.execute('select count(*) from DigitizedDataset').fetchone()[0] if 'DigitizedDataset' in ts else -1;print(len(ts), total, dd)"
            SNAP=$(run_on_source "docker run --rm -v $VOL:/data prf-backend:staging python3 -c \"$COUNT_PY\"") || mv_fail "snapshot failed" release
            read -r NTAB NROW NDD <<< "$SNAP"
            mv_step snapshot done "$NTAB tables / $NROW rows (DigitizedDataset $NDD)"
        else
            NROW=$(vol_src "sh -c 'find /data -type f -not -path \"*/.minio.sys/*\" -not -name .move-journal.json | wc -l'" | tr -d ' ')
            NKB=$(vol_src "du -sk /data" | awk '{print $1}')
            mv_step snapshot done "$NROW user objects / ${NKB}KB total (.minio.sys volatile, excluded from the count)"
        fi
        # STAGED copy: live target data untouched until the verified
        # swap; journals in BOTH volumes = crash-durable record.
        mv_step copy-data running
        STAGE=".incoming-${MOVE}"
        PREV=".previous-${MOVE}"
        JLINE="{\"move\":\"$MOVE\",\"from\":\"$FROM\",\"to\":\"$TO\",\"phase\":\"copying\",\"at\":$(date +%s)}"
        printf '%s' "$JLINE" | run_on_source "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
        run_on_target "docker volume create $VOL" >/dev/null 2>&1 || true
        printf '%s' "$JLINE" | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
        run_on_source "docker run --rm -v $VOL:/data alpine tar -C /data -cf - ." | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'rm -rf /data/$STAGE && mkdir -p /data/$STAGE && tar -C /data/$STAGE -xf -'" || mv_fail "staged copy to $TO failed — live target data untouched; re-run to resume" release
        mv_step copy-data done "staged into $STAGE on $TO (live data untouched)"
        if [ "$VERIFY" = "sqlite" ]; then
            # Second pass captures the receipt row just written
            # (quiesced, so nothing else changed).
            run_on_source "docker run --rm -v $VOL:/data alpine tar -C /data -cf - ." | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'tar -C /data/$STAGE -xf -'" || mv_fail "consistency re-copy failed — live target data untouched; re-run to resume" release
            STAGED_COUNT_PY="import sqlite3;c=sqlite3.connect('/vol/$STAGE/managerObject_DB.db');ts=[r[0] for r in c.execute('select name from sqlite_master where type=' + chr(39) + 'table' + chr(39))];total=sum(c.execute('select count(*) from ' + chr(34) + t + chr(34)).fetchone()[0] for t in ts);print(len(ts), total)"
            FROW=$(run_on_target "docker run --rm -v $VOL:/vol prf-backend:staging python3 -c \"$STAGED_COUNT_PY\"" 2>/dev/null | awk '{print $2}' || true)
            [ "$FROW" = "$NROW" ] || mv_fail "staged file has ${FROW:-?} rows != source $NROW — staged copy inconsistent; live target data untouched, re-run to resume" release
        else
            FCOUNT=$(vol_tgt "sh -c 'find /data/$STAGE -type f -not -path \"*/.minio.sys/*\" -not -name .move-journal.json | wc -l'" | tr -d ' ')
            [ "$FCOUNT" = "$NROW" ] || mv_fail "staged copy has ${FCOUNT:-?} user objects != source $NROW — inconsistent; live target data untouched, re-run to resume" release
        fi
        # SWAP, only now: live -> $PREV (kept until retire), staged
        # -> live. Dot-entries excluded from the sweep by the glob.
        run_on_target "docker run --rm -v $VOL:/data alpine sh -c 'mkdir -p /data/$PREV && for f in /data/*; do [ -e \"\$f\" ] || continue; mv \"\$f\" /data/$PREV/; done; mv /data/$STAGE/* /data/ 2>/dev/null; mv /data/$STAGE/.minio.sys /data/ 2>/dev/null; rm -rf /data/$STAGE'" || mv_fail "swap failed — staged copy + $PREV both on $TO, journal marks the state; recover manually or re-run" release
        printf '%s' "${JLINE/copying/swapped}" | run_on_target "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
        mv_step service-update running
        T0=$(date +%s)
        docker service update --update-order stop-first \
            --constraint-rm "node.labels.polari.machine==$FROM" \
            --constraint-add "node.labels.polari.machine==$TO" \
            --detach "$SVC" >/dev/null || mv_fail "service update failed" release
        mv_step service-update done "stop-first constraint swap issued"
        mv_step boot-ready running
        # Placement FIRST, then readiness.
        PLACED=""
        for i in $(seq 1 60); do
            NODE=$(docker service ps "$SVC" --filter desired-state=running --format '{{.Node}}' | head -1)
            ON=$(docker node inspect "$NODE" --format '{{index .Spec.Labels "polari.machine"}}' 2>/dev/null || true)
            [ "$ON" = "$TO" ] && PLACED=1 && break
            sleep 3
        done
        [ -n "$PLACED" ] || mv_fail "task never placed on $TO" release
        READY=""
        if [ "$VERIFY" = "sqlite" ]; then
            for i in $(seq 1 90); do
                if curl -skf --max-time 4 "$POLARI_CORE_URL/api/health" >/dev/null 2>&1; then READY=1; break; fi
                sleep 5
            done
        else
            for i in $(seq 1 60); do
                STATE=$(run_on_target "docker ps --filter name=$SVC --format '{{.Status}}'" | head -1)
                case "$STATE" in *healthy*) READY=1; break ;; esac
                sleep 5
            done
        fi
        [ -n "$READY" ] || mv_fail "relocated $SUBJECT never became ready on $TO"
        DOWN=$(( $(date +%s) - T0 ))
        if [ "$VERIFY" = "sqlite" ]; then
            # Re-assert the service-update receipt: its first post
            # landed on the OLD instance after the copy (lost by
            # design) — only applies when the BACKEND itself moved.
            mv_step service-update done "stop-first constraint swap converged (re-asserted post-cutover)"
        fi
        mv_step boot-ready done "ready on $TO; measured downtime ~${DOWN}s"
        mv_step verify-data running
        if [ "$VERIFY" = "sqlite" ]; then
            TTASK=$(run_on_target "docker ps -q -f name=$SVC" | head -1)
            [ -n "$TTASK" ] || mv_fail "no $SVC task running on $TO"
            LIVE_COUNT_PY="import sqlite3;c=sqlite3.connect('/app/data/managerObject_DB.db');ts=[r[0] for r in c.execute('select name from sqlite_master where type=' + chr(39) + 'table' + chr(39))];total=sum(c.execute('select count(*) from ' + chr(34) + t + chr(34)).fetchone()[0] for t in ts);dd=c.execute('select count(*) from DigitizedDataset').fetchone()[0] if 'DigitizedDataset' in ts else -1;print(len(ts), total, dd)"
            VER=$(run_on_target "docker exec $TTASK python3 -c \"$LIVE_COUNT_PY\"") || mv_fail "target row count failed"
            read -r TTAB TROW TDD <<< "$VER"
            [ "$TTAB" = "$NTAB" ] || mv_fail "DATA LOSS: target has $TTAB tables != snapshot $NTAB"
            [ "$TDD" = "$NDD" ] || mv_fail "DATA LOSS: DigitizedDataset $TDD != snapshot $NDD"
            MARKER=$(api GET "/api/topology/move-operations" | python3 -c "import json,sys; d=json.load(sys.stdin); print('1' if any(m['name']=='$MOVE' for m in d.get('moves',[])) else '')")
            [ -n "$MARKER" ] || mv_fail "marker MoveOperation row missing on relocated instance"
            mv_step verify-data done "tables $TTAB==$NTAB; DigitizedDataset $TDD==$NDD; marker present; rows $TROW post-dedup (staged file matched $NROW exactly pre-swap)"
        else
            TCOUNT=$(vol_tgt "sh -c 'find /data -type f -not -path \"*/.minio.sys/*\" -not -path \"*/.previous-*\" -not -path \"*/.incoming-*\" -not -name .move-journal.json | wc -l'" | tr -d ' ')
            [ "$TCOUNT" = "$NROW" ] || mv_fail "DATA LOSS: target serves $TCOUNT user objects != snapshot $NROW"
            mv_step verify-data done "target serves $TCOUNT user objects == snapshot $NROW (staged copy matched exactly pre-swap)"
        fi
        # Retire = the ONLY deletions: target .previous + its journal
        # (both now proven redundant). SOURCE volume never deleted;
        # its journal marks where the data went. Sidecar moves also
        # RELEASE the quiesce gate here (the backend didn't move).
        mv_step retire running
        vol_tgt "sh -c 'rm -rf /data/$PREV /data/.incoming-* && rm -f /data/.move-journal.json'" >/dev/null 2>&1 || true
        printf '{"move":"%s","from":"%s","to":"%s","phase":"retired-moved-to-%s","at":%s}' "$MOVE" "$FROM" "$TO" "$TO" "$(date +%s)" | run_on_source "docker run --rm -i -v $VOL:/data alpine sh -c 'cat > /data/.move-journal.json'" || true
        if [ "$VERIFY" != "sqlite" ]; then
            echo '{}' | api POST /api/quiesce/release >/dev/null || true
            RELNOTE="; quiesce released (backend did not move)"
        else
            RELNOTE=""
        fi
        mv_step retire done "target .previous + journal cleared; SOURCE volume kept intact on $FROM (rollback) with journal marking data moved to $TO$RELNOTE"
        printf '{"name":"%s","status":"verified"}' "$MOVE" | api POST /api/topology/move-operations/finish >/dev/null || true
        docker service ps "$SVC" --format '{{.Name}}\t{{.Node}}\t{{.CurrentState}}' | head -3
        log_success "$SUBJECT relocated $FROM -> $TO (downtime ~${DOWN}s; MoveOperation $MOVE)"
        log_info "old volume on $FROM is the rollback; topology row: pol allocate <instance> $TO if tracked" ;;
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
