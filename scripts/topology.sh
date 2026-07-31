#!/bin/bash
# pol topology — the swarm/compose topology as core-instance DATA (top-2).
#
# Desired state lives as rows on the CORE Polari instance
# (/api/topology/*, built top-1); files (topologies/*.topology.yml,
# nodes.yml) are the INTERCHANGE format. This script syncs the two
# (pull/push), reports OBSERVED state (report), and shows drift
# (diff). Nothing here deploys anything — apply/export-to-manifests
# land in top-3/4 and refuse honestly below.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"
PACKAGES_DIR="$POL_SUITE_ROOT/topologies"
#: The machine name the local (non-ssh) host reports as. The core
#: seeds itself as 'pol-core' (the research core; renamed from staging-a 2026-07-27).
LOCAL_NODE="${POLARI_LOCAL_NODE:-pol-core}"

show_help() {
    pol_box "pol topology — topology as core-instance data"
    echo -e "
${BOLD}READ${NC}
  ${CYAN}status${NC}               active topology + row counts
  ${CYAN}graph${NC} [name]         instances / modules / edges / connections
  ${CYAN}validate${NC} [name]      evidence-bearing findings (each names its knob)
  ${CYAN}diff${NC} [name]          desired vs observed drift + package-file drift

${BOLD}SYNC (files <-> rows)${NC}
  ${CYAN}pull${NC} [name]          rows -> topologies/<name>.topology.yml (portable,
                       credential-free package)
  ${CYAN}push${NC} [file]          package file -> rows (idempotent-by-name); always
                       refreshes machines from nodes.yml. No file = just nodes.yml
  ${CYAN}report${NC} [--node <n>]  observe what THIS host (or ssh node <n>) actually
                       runs -> TopologyObservation row (never guessed)

${BOLD}WRITE (rows only — deploys stay human-invoked)${NC}
  ${CYAN}assign${NC} <module> <instance> [--from <instance>]
                       move/enable a module (rewrites ModuleAssignment,
                       re-resolves dependency edges)
  ${CYAN}resolve${NC} [name]       recompute edge providers from assignments
  ${CYAN}modules-env${NC} [instance]  the POLARI_MODULES an instance's rows
                       derive (requires-closure included; default prf-a).
                       Swarm/staging deploys read THIS — a hand-set
                       POLARI_MODULES is a warned override

${BOLD}BUILD + RUN (top-3)${NC}
  ${CYAN}render${NC} [name]        topology rows -> pol-build/manifests/topology-<name>/
                       (bundle manifests + stacks + ordered actions), then
                       render.py byte-parity against the generated bundles
  ${CYAN}apply${NC} [name] [--plan]  replay the rendered actions (compose up /
                       stack deploy per group). --plan prints only. LOCAL
                       machine only — remote nodes are top-4
  ${CYAN}deploy${NC} <file|name> [--plan]  full portable-package flow:
                       push -> render -> apply. Round trip: pull after
                       deploy reproduces the package byte-for-byte

Backend: the core instance's /api/topology/* — reached via
\$POLARI_CORE_URL when set, else docker exec into local prf-backend."
}

need_pyyaml() {
    python3 -c "import yaml" 2>/dev/null || die "needs python3-yaml (apt install python3-yaml)"
}

# be_call METHOD PATH  — body on stdin for POST; response on stdout.
# Rides the shared core-api transport (POLARI_CORE_URL, else the
# compose prf-backend OR swarm polari-node_backend container).
source "$SCRIPT_DIR/lib/core-api.sh"
be_call() {
    core_api "$@" || die "no local backend container (compose prf-backend or swarm polari-node_backend) and POLARI_CORE_URL unset — start the node/suite or point POLARI_CORE_URL at the core"
}

# pretty PYTHON_SNIPPET — feeds be_call output through a formatter.
pretty() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

resolve_name() {  # $1 = explicit name or empty -> active topology
    if [ -n "$1" ]; then echo "$1"; return; fi
    be_call GET /api/topology/summary | pretty "print(d.get('activeTopology',''))"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    status)
        pol_box "topology status"
        be_call GET /api/topology/summary | pretty "
print('  active topology:', d.get('activeTopology') or '(none)')
for t in d.get('topologies', []):
    star = '*' if t['isActive'] else ' '
    print(f\"  {star} {t['name']:<16} {t['status']:<10} {t['description'][:60]}\")
print('  rows:', ', '.join(f'{k.replace(chr(39),chr(39))}={v}' for k,v in sorted(d.get('counts',{}).items()) if v))" ;;
    graph)
        NAME=$(resolve_name "$1"); [ -n "$NAME" ] || die "no active topology — pol topology push first"
        be_call GET "/api/topology/graph?name=$NAME" | pretty "
if not d.get('ok'): raise SystemExit('  ' + str(d.get('error')))
t = d['topology']
print(f\"  {t['name']} [{t['status']}] default target: {t['defaultTarget']}\")
print('  INSTANCES')
for i in d['instances']:
    print(f\"    {i['name']:<10} {i['kind']:<7} {i['orchestrationTarget']:<8} db={i['dbBackend']:<14} @{i['machineName'] or '(unpinned)'}\")
    mods = [a['moduleName'] + ('' if a['state']=='enabled' else f\" ({a['state']})\") for a in d['assignments'] if a['instanceName']==i['name']]
    if mods: print('               modules: ' + ', '.join(mods))
print('  DEPENDENCY EDGES')
for e in d['edges']:
    mark = 'OK ' if e['status']=='resolved' else ('DEG' if e['status']=='degraded' else '!! ')
    print(f\"    [{mark}] {e['moduleName']}@{e['consumerInstanceName']} -> {e['dependsOnModule']} @ {e['providerInstanceName'] or '(no provider)'}\")
print(f\"  CONNECTIONS ({len(d['connections'])} typed wires; pol registry interconnects for artifacts)\")
for c in d['connections']:
    print(f\"    {c['interconnectKey']:<24} {c['fromKind']} -> {c['toKind']}\")" ;;
    validate)
        NAME=$(resolve_name "$1"); [ -n "$NAME" ] || die "no active topology"
        echo '{}' | be_call POST "/api/topology/validate?name=$NAME" | pretty "
if not d.get('ok'): raise SystemExit('  ' + str(d.get('error')))
print(f\"  topology {d['topology']}: {'VALID' if d['valid'] else 'INVALID'} ({d['errorCount']} errors, {d['warnCount']} warnings)\")
for f in d['findings']:
    print(f\"  [{f['severity']}] {f['check']} @ {f['subject']}\")
    print(f\"      evidence: {f['evidence']}\")
    print(f\"      knob:     {f['knob']}\")
    print(f\"      action:   {f['action']}\")"
        ;;
    pull)
        need_pyyaml
        NAME=$(resolve_name "$1"); [ -n "$NAME" ] || die "no active topology"
        mkdir -p "$PACKAGES_DIR"
        OUT="$PACKAGES_DIR/$NAME.topology.yml"
        be_call GET "/api/topology/export?name=$NAME" | python3 -c "
import json, sys, yaml
d = json.load(sys.stdin)
if not d.get('ok'): raise SystemExit('  export failed: ' + str(d.get('error')))
doc = d['document']
header = (
 '# ============================================================\n'
 '# PORTABLE POLARI TOPOLOGY PACKAGE — credential-free by\n'
 '# construction (secrets self-generate on every target).\n'
 '# Re-deploy anywhere: pol topology push <this file>, then\n'
 '# pol topology apply (top-3/4). Safe to commit/share.\n'
 '# ============================================================\n')
with open(sys.argv[1], 'w') as fh:
    fh.write(header)
    yaml.safe_dump(doc, fh, sort_keys=False, default_flow_style=False)
print('  wrote', sys.argv[1])
print(f\"  {len(doc['instances'])} instances, {len(doc['assignments'])} assignments, \"
      f\"{len(doc['edges'])} edges, {len(doc['connections'])} connections\")" "$OUT"
        log_success "pulled topology '$NAME' -> topologies/$NAME.topology.yml" ;;
    push)
        need_pyyaml
        FILE=$1
        [ -z "$FILE" ] || [ -f "$FILE" ] || [ -f "$PACKAGES_DIR/$FILE" ] || [ -f "$PACKAGES_DIR/$FILE.topology.yml" ] || die "no such package file: $FILE"
        [ -n "$FILE" ] && { [ -f "$FILE" ] || FILE=$(ls "$PACKAGES_DIR/$FILE" 2>/dev/null || ls "$PACKAGES_DIR/$FILE.topology.yml"); }
        python3 -c "
import json, sys, yaml
pkg_file, nodes_file = sys.argv[1], sys.argv[2]
doc = {'kind': 'polari-topology-package', 'schema_version': '1'}
if pkg_file:
    doc = yaml.safe_load(open(pkg_file))
# files -> rows: nodes.yml machines ALWAYS refresh into the doc
# (idempotent-by-name on the backend).
nodes = yaml.safe_load(open(nodes_file)) or {}
machines = {m['name']: m for m in doc.get('machines', [])}
for name, spec in (nodes.get('nodes') or {}).items():
    machines.setdefault(name, {
        'name': name, 'ssh_alias': spec.get('ssh', name),
        'arch': '', 'mem_gb': 0.0,
        'roles_json': json.dumps(spec.get('roles', [])),
        'swarm_role': 'none',
        'repo_dir': spec.get('repo_dir', '~/polari-suite'),
        'source': 'nodes.yml', 'notes': spec.get('notes', '')})
doc['machines'] = sorted(machines.values(), key=lambda m: m['name'])
json.dump(doc, sys.stdout)
" "$FILE" "$NODES_FILE" | be_call POST /api/topology/import | pretty "
if not d.get('ok'): raise SystemExit('  push failed: ' + str(d.get('error')))
print(f\"  created {len(d['created'])} rows, skipped {len(d['skipped'])} (idempotent-by-name)\")
for c in d['created']: print(f\"    + {c['class']} {c['name']}\")"
        log_success "pushed ${FILE:-nodes.yml machines} -> core rows" ;;
    diff)
        NAME=$(resolve_name "$1"); [ -n "$NAME" ] || die "no active topology"
        pol_box "drift: desired vs observed ($NAME)"
        be_call GET "/api/topology/drift?name=$NAME" | pretty "
if not d.get('ok'): raise SystemExit('  ' + str(d.get('error')))
print('  observed nodes:', ', '.join(d['observedNodes']) or '(none — run pol topology report)')
if not d['inDrift']: print('  NO DRIFT — observed state matches the topology')
for r in d['rows']:
    print(f\"  [{r['kind']}] {r['subject']} @ {r.get('machine','')}\")
    print(f\"      {r['evidence']}\")
    print(f\"      suggested: {r['suggestedCommand']}\")"
        # package-file drift: committed package vs live rows
        PKG="$PACKAGES_DIR/$NAME.topology.yml"
        if [ -f "$PKG" ]; then
            need_pyyaml
            be_call GET "/api/topology/export?name=$NAME" | python3 -c "
import json, sys, yaml
live = json.load(sys.stdin)
if live.get('ok'):
    pkg = yaml.safe_load(open(sys.argv[1]))
    if json.dumps(pkg, sort_keys=True) == json.dumps(live['document'], sort_keys=True):
        print('  package file topologies/%s.topology.yml == live rows' % sys.argv[2])
    else:
        print('  PACKAGE DRIFT: topologies/%s.topology.yml differs from live rows' % sys.argv[2])
        print('      suggested: pol topology pull %s   (refresh the file)' % sys.argv[2])
        print('      or:        pol topology push topologies/%s.topology.yml' % sys.argv[2])
" "$PKG" "$NAME"
        fi ;;
    report)
        NODE="$LOCAL_NODE"; RUN=""
        [ "$1" = "--node" ] && { NODE=$2; shift 2; }
        if [ "$NODE" != "$LOCAL_NODE" ]; then
            need_pyyaml
            ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$NODE")
            [ -n "$ALIAS" ] || die "node '$NODE' not in nodes.yml (pol deploy nodes)"
            RUN="ssh -o ConnectTimeout=8 $ALIAS"
        fi
        log_info "observing $NODE (docker ps + stacks)"
        # the compose/swarm service LABELS are what drift matching
        # resolves to registry kinds (container names are aliases).
        # remote runs get ONE quoted command string — ssh re-splits
        # bare args and the label templates carry inner quotes.
        PS_CMD='docker ps --format "{{.Names}}\t{{.State}}\t{{.Image}}\t{{.Label \"com.docker.compose.service\"}}{{.Label \"com.docker.swarm.service.name\"}}"'
        LS_CMD='docker stack ls --format "{{.Name}}"'
        if [ -n "$RUN" ]; then
            SERVICES=$($RUN "$PS_CMD" 2>/dev/null || true)
            STACKS=$($RUN "$LS_CMD" 2>/dev/null || true)
        else
            SERVICES=$(bash -c "$PS_CMD" 2>/dev/null || true)
            STACKS=$(bash -c "$LS_CMD" 2>/dev/null || true)
        fi
        python3 -c "
import json, sys
services = [{'name': p[0], 'state': p[1] if len(p) > 1 else '',
             'image': p[2] if len(p) > 2 else '',
             'service': (p[3] if len(p) > 3 else '').split('_')[-1]}
            for line in sys.argv[1].splitlines() if line
            for p in [line.split('\t')]]
stacks = [{'name': s} for s in sys.argv[2].splitlines() if s]
json.dump({'node': sys.argv[3], 'services': services,
           'stacks': stacks, 'source': 'pol topology report'},
          sys.stdout)
" "$SERVICES" "$STACKS" "$NODE" | be_call POST /api/topology/observe | pretty "
print(('  recorded ' + d['observation'] + ' against topology ' + (d['topology'] or '(none)')) if d.get('ok') else '  failed: ' + str(d.get('error')))"
        log_success "observation posted — pol topology diff to compare" ;;
    assign)
        MODULE=$1; TO=$2; FROM=""
        [ "$3" = "--from" ] && FROM=$4
        [ -n "$MODULE" ] && [ -n "$TO" ] || die "usage: pol topology assign <module> <instance> [--from <instance>]"
        python3 -c "
import json, sys
p = {'module': sys.argv[1], 'to_instance': sys.argv[2]}
if sys.argv[3]: p['from_instance'] = sys.argv[3]
json.dump(p, sys.stdout)" "$MODULE" "$TO" "$FROM" | be_call POST /api/topology/assign | pretty "
if not d.get('ok'): raise SystemExit('  assign failed: ' + str(d.get('error')))
print('  assignment:', d['assignment'])
if d['disabled']: print('  disabled:', ', '.join(d['disabled']))
for c in d['resolve']['changed']:
    print(f\"  edge {c['edge']}: {c['from']['provider'] or '(none)'} -> {c['to']['provider'] or '(none)'} [{c['to']['status']}]\")
print('  rows updated — deploying the change stays yours:', d['suggestedCommand'])" ;;
    modules-env)
        INST=${1:-prf-a}
        be_call GET "/api/topology/modules-env/$INST" | pretty "
if not d.get('ok'):
    print('  REFUSED:', d.get('refusal'))
    print('  knob:', d.get('suggestion'))
    raise SystemExit(1)
print(f\"  {d['instance']} @ {d['topology']} — {d['count']} modules\")
print('  assigned:', ', '.join(d['assigned']))
for mod, why in sorted((d.get('addedByRequires') or {}).items()):
    print(f\"  + {mod} (required by {', '.join(why)})\")
print()
print('  POLARI_MODULES=' + d['env'])" ;;
    resolve)
        NAME=$(resolve_name "$1"); [ -n "$NAME" ] || die "no active topology"
        echo '{}' | be_call POST "/api/topology/resolve?name=$NAME" | pretty "
print(f\"  {d['edges']} edges checked, {len(d['changed'])} changed\" if d.get('ok') else '  failed: ' + str(d.get('error')))
for c in d.get('changed', []):
    print(f\"    {c['edge']}: -> {c['to']['provider'] or '(none)'} [{c['to']['status']}]\")" ;;
    render)
        need_pyyaml
        NAME=$(resolve_name "$1"); [ -n "$NAME" ] || die "no active topology"
        PKG="$PACKAGES_DIR/$NAME.topology.yml"
        # rows are the source of truth — refresh the package first
        bash "$SCRIPT_DIR/topology.sh" pull "$NAME" >/dev/null
        python3 "$POL_SUITE_ROOT/pol-build/tools/topology_render.py" "$PKG" --out-root "$POL_SUITE_ROOT"
        OUT="$POL_SUITE_ROOT/pol-build/manifests/topology-$NAME"
        # byte-parity gate: the emitted manifests must reproduce the
        # project's generated bundles exactly (render.py --check idiom)
        if [ -f "$OUT/bundles-suite.yml" ]; then
            python3 "$POL_SUITE_ROOT/pol-build/render.py" "$POL_SUITE_ROOT" --manifest "$OUT/bundles-suite.yml" || die "suite bundle parity failed"
        fi
        if [ -f "$OUT/bundles-node.yml" ]; then
            python3 "$POL_SUITE_ROOT/pol-build/render.py" "$POL_RF_NODE" --manifest "$OUT/bundles-node.yml" || die "node bundle parity failed"
        fi
        log_success "topology '$NAME' rendered -> pol-build/manifests/topology-$NAME/ (parity OK)" ;;
    apply)
        need_pyyaml
        PLAN=""; NAME_ARG=""
        for arg in "$@"; do
            case "$arg" in
                --plan) PLAN=1 ;;
                *) NAME_ARG=$arg ;;
            esac
        done
        NAME=$(resolve_name "$NAME_ARG"); [ -n "$NAME" ] || die "no active topology"
        ACTIONS="$POL_SUITE_ROOT/pol-build/manifests/topology-$NAME/actions.yml"
        [ -f "$ACTIONS" ] || bash "$SCRIPT_DIR/topology.sh" render "$NAME"
        pol_box "topology apply${PLAN:+ (plan only)}: $NAME"
        python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for a in doc['actions']:
    where = 'REMOTE ' + a['machine'] if a['remote'] else 'local'
    print(f\"  {a['order']}. [{where}] {a['group']:<14} {a['command']}\")
" "$ACTIONS"
        if [ -n "$PLAN" ]; then
            log_info "plan only — nothing executed. Run without --plan to apply local actions."
            exit 0
        fi
        # execute LOCAL actions in order via the existing pol paths
        # (they self-record for pol start/rebuild/stop); remote
        # machines refuse honestly until top-4 wires pol deploy in.
        python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for a in doc['actions']:
    print(('SKIP-REMOTE' if a['remote'] else 'RUN') + '\t' + a['command'])
" "$ACTIONS" | while IFS=$'\t' read -r MODE CMD; do
            if [ "$MODE" = "SKIP-REMOTE" ]; then
                log_warn "remote compose action skipped (pol deploy run <node> --role <r> drives it): $CMD"
                continue
            fi
            log_info "applying: $CMD"
            if [[ "$CMD" == *"swarm deploy"* ]]; then
                # stack actions carry their placement constraints from
                # the topology (stacks.yml) into stackify
                STACKS="$POL_SUITE_ROOT/pol-build/manifests/topology-$NAME/stacks.yml"
                CONSTRAINTS=$(python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])) if len(sys.argv) > 1 else {}
out = []
for s in (doc or {}).get('stacks', []):
    if s.get('placement'):
        svc = s['source'].replace('docker-compose.', '').replace('.yml', '')
        out.append(svc + '=' + s['placement'].replace(' ', ''))
print(' '.join(out))" "$STACKS" 2>/dev/null || true)
                # shellcheck disable=SC2086
                POL_STACK_CONSTRAINTS="$CONSTRAINTS" pol ${CMD#pol } || die "action failed: $CMD"
            else
                # shellcheck disable=SC2086
                pol ${CMD#pol } || die "action failed: $CMD"
            fi
        done
        log_success "topology '$NAME' applied — pol topology report && pol topology diff to verify" ;;
    deploy)
        TARGET=$1; shift || true
        [ -n "$TARGET" ] || die "usage: pol topology deploy <package-file|name> [--plan]"
        if [ -f "$TARGET" ]; then PKG="$TARGET";
        elif [ -f "$PACKAGES_DIR/$TARGET.topology.yml" ]; then PKG="$PACKAGES_DIR/$TARGET.topology.yml";
        else die "no such package: $TARGET (topologies/*.topology.yml)"; fi
        need_pyyaml
        NAME=$(python3 -c "import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))['topology']['name'])" "$PKG")
        log_info "deploying portable package '$NAME' (push -> render -> apply $*)"
        bash "$SCRIPT_DIR/topology.sh" push "$PKG"
        bash "$SCRIPT_DIR/topology.sh" render "$NAME"
        bash "$SCRIPT_DIR/topology.sh" apply "$@" "$NAME" ;;
    export)
        # export == pull: the package file IS the export artifact
        bash "$SCRIPT_DIR/topology.sh" pull "$@" ;;
    allocate)
        # pol allocate <module|instance> <instance|machine> — the
        # targeted-deploy path (top-4). Module -> instance rewrites the
        # assignment (rows only); instance -> machine moves the
        # instance, re-renders, and re-deploys THAT group.
        need_pyyaml
        WHAT=$1; WHERE=$2; GRACEFUL=""
        [ "${3:-}" = "--graceful" ] && GRACEFUL=1
        [ -n "$WHAT" ] && [ -n "$WHERE" ] || die "usage: pol allocate <module> <instance> | pol allocate <instance> <machine> [--graceful]"
        NAME=$(resolve_name ""); [ -n "$NAME" ] || die "no active topology"
        MODE=$(be_call GET "/api/topology/graph?name=$NAME" | python3 -c "
import json, sys
d = json.load(sys.stdin)
what, where = sys.argv[1], sys.argv[2]
instances = {i['name'] for i in d.get('instances', [])}
machines = {m['name'] for m in d.get('machines', [])}
if what in instances and where in machines: print('instance')
elif where in instances: print('module')
else: print('unknown')" "$WHAT" "$WHERE")
        case "$MODE" in
            module)
                bash "$SCRIPT_DIR/topology.sh" assign "$WHAT" "$WHERE" ;;
            instance)
                log_info "moving instance '$WHAT' -> machine '$WHERE' (row + render + targeted deploy)"
                printf '{"name": "%s", "machine_name": "%s", "placement_constraint": ""}' "$WHAT" "$WHERE" | \
                    be_call POST /api/topology/instance | pretty "
print(('  instance row updated: ' + ', '.join(d['updated'])) if d.get('ok') else sys.exit('  failed: ' + str(d.get('error'))))"
                bash "$SCRIPT_DIR/topology.sh" render "$NAME"
                STACKS="$POL_SUITE_ROOT/pol-build/manifests/topology-$NAME/stacks.yml"
                GROUP=$(python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for a in doc['actions']:
    if sys.argv[2] in a['instances']:
        print(a['group'] + '\t' + a['command'] + '\t' + ('1' if a['remote'] else ''))
        break" "$POL_SUITE_ROOT/pol-build/manifests/topology-$NAME/actions.yml" "$WHAT")
            IFS=$'\t' read -r GNAME GCMD GREMOTE <<< "$GROUP"
                [ -n "$GNAME" ] || die "instance '$WHAT' maps to no build group after render"
                if [ "$GNAME" = "engines-stack" ] && [ -n "$GRACEFUL" ]; then
                    # gm-1: BLUE-GREEN engine relocation — every step
                    # receipted as a MoveOperation row (durations
                    # measured server-side; prior moves yield expected
                    # durations). start-first + the routing mesh keep
                    # :9500 answering throughout.
                    SVC="polari-engines_msci-engines"
                    IMG="prf-msci-engines:staging"
                    # gm-safety guard: never start a move while a
                    # service update is converging.
                    UPD=$(docker service inspect "$SVC" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}' 2>/dev/null || true)
                    case "$UPD" in
                        updating|paused|rollback_started|rollback_paused)
                            die "service $SVC has an update in progress ($UPD) — wait for convergence, then retry" ;;
                    esac
                    FROM=$(docker service inspect "$SVC" --format '{{json .Spec.TaskTemplate.Placement.Constraints}}' 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin) or []:
    if 'polari.machine' in c:
        print(c.split('==')[-1].strip()); break" || true)
                    [ -n "$FROM" ] || die "cannot read $SVC's current machine constraint — is the engines stack deployed?"
                    [ "$FROM" != "$WHERE" ] || die "engines already on $WHERE"
                    MOVE=$(printf '{"kind":"engine-relocation","subject":"msci-engines","fromMachine":"%s","toMachine":"%s","triggeredBy":"pol allocate --graceful"}' "$FROM" "$WHERE" | be_call POST /api/topology/move-operations | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['move']['name'] if d.get('ok') else '')")
                    [ -n "$MOVE" ] || log_warn "MoveOperation row not created (backend unreachable?) — continuing, steps unreceipted"
                    mv_step() { # key status [receipt]
                        [ -n "$MOVE" ] || return 0
                        printf '{"name":"%s","step":"%s","status":"%s","receipt":"%s"}' "$MOVE" "$1" "$2" "${3:-}" | be_call POST /api/topology/move-operations/step >/dev/null || true
                    }
                    mv_fail() { # error
                        [ -n "$MOVE" ] && printf '{"name":"%s","status":"failed","error":"%s"}' "$MOVE" "$1" | be_call POST /api/topology/move-operations/finish >/dev/null || true
                        die "$1"
                    }
                    ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$WHERE" 2>/dev/null || true)
                    mv_step check-image running
                    if [ -n "$ALIAS" ] && ! ssh "$ALIAS" "docker image inspect $IMG" >/dev/null 2>&1; then
                        mv_step check-image done "absent on $WHERE"
                        mv_step ship-image running
                        log_info "syncing $IMG to $WHERE (docker save | ssh docker load)"
                        docker save "$IMG" | ssh "$ALIAS" docker load || mv_fail "image sync to $WHERE failed"
                        SIZE=$(docker image inspect "$IMG" --format '{{.Size}}')
                        mv_step ship-image done "shipped $((SIZE/1000000))MB to $WHERE"
                    else
                        mv_step check-image done "present on $WHERE (or local node)"
                        mv_step ship-image skipped "already on target"
                    fi
                    mv_step ensure-label running
                    docker node ls --format '{{.ID}}' | while read -r NID; do docker node inspect "$NID" --format '{{index .Spec.Labels "polari.machine"}}'; done | grep -qx "$WHERE" || mv_fail "no swarm node labeled polari.machine=$WHERE (pol swarm join $WHERE)"
                    mv_step ensure-label done "node labeled $WHERE in swarm"
                    mv_step service-update running
                    log_info "blue-green: start-first constraint swap $FROM -> $WHERE"
                    docker service update --update-order start-first \
                        --constraint-rm "node.labels.polari.machine==$FROM" \
                        --constraint-add "node.labels.polari.machine==$WHERE" \
                        --detach=false "$SVC" >/dev/null || mv_fail "service update failed"
                    mv_step service-update done "swarm converged (start-first)"
                    mv_step readiness running
                    READY=""
                    for i in $(seq 1 60); do
                        NODE=$(docker service ps "$SVC" --filter desired-state=running --format '{{.Node}}' | head -1)
                        ON=$(docker node inspect "$NODE" --format '{{index .Spec.Labels "polari.machine"}}' 2>/dev/null || true)
                        if [ "$ON" = "$WHERE" ] && curl -sf --max-time 3 "http://${LOCAL_IP:-localhost}:9500/capability" >/dev/null 2>&1; then READY=1; break; fi
                        sleep 2
                    done
                    [ -n "$READY" ] || mv_fail "new task on $WHERE never answered /capability"
                    mv_step readiness done "task on $WHERE answers /capability via mesh"
                    mv_step verify running
                    be_call POST /api/topology/providers/reprobe </dev/null >/dev/null 2>&1 || true
                    CAP=$(curl -sf --max-time 5 "http://${LOCAL_IP:-localhost}:9500/capability" | head -c 60 || true)
                    [ -n "$CAP" ] || mv_fail "capability verify failed after relocation"
                    mv_step verify done "capability answers; probe cache invalidated"
                    [ -n "$MOVE" ] && printf '{"name":"%s","status":"verified"}' "$MOVE" | be_call POST /api/topology/move-operations/finish >/dev/null || true
                    docker service ps "$SVC" --format '{{.Name}}\t{{.Node}}\t{{.CurrentState}}' | head -3
                    log_success "graceful relocation $FROM -> $WHERE complete (MoveOperation ${MOVE:-unreceipted})"
                elif [ "$GNAME" = "engines-stack" ]; then
                    # swarm distributes CONFIG, not images — sync the
                    # locally-built image to the target node first
                    ALIAS=$(python3 -c "import sys,yaml; print((yaml.safe_load(open(sys.argv[1]))['nodes'].get(sys.argv[2]) or {}).get('ssh',''))" "$NODES_FILE" "$WHERE" 2>/dev/null || true)
                    IMG="prf-msci-engines:staging"
                    if [ -n "$ALIAS" ]; then
                        if ! ssh "$ALIAS" "docker image inspect $IMG" >/dev/null 2>&1; then
                            log_info "syncing $IMG to $WHERE (docker save | ssh docker load — one-time)"
                            docker save "$IMG" | ssh "$ALIAS" docker load || die "image sync to $WHERE failed"
                        fi
                    fi
                    CONSTRAINTS=$(python3 -c "
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
out = []
for s in (doc or {}).get('stacks', []):
    if s.get('placement'):
        svc = s['source'].replace('docker-compose.', '').replace('.yml', '')
        out.append(svc + '=' + s['placement'].replace(' ', ''))
print(' '.join(out))" "$STACKS")
                    log_info "deploying engines stack with constraints: $CONSTRAINTS"
                    POL_STACK_CONSTRAINTS="$CONSTRAINTS" pol swarm deploy engines || die "targeted deploy failed"
                    docker stack ps polari-engines --format '{{.Name}}\t{{.Node}}\t{{.CurrentState}}' | head -5
                elif [ -n "$GREMOTE" ]; then
                    log_warn "'$WHAT' is a compose group on a remote machine — drive it with: pol deploy run $WHERE --role <r> (push branches first; nodes pull GitHub)"
                else
                    log_info "re-running local group: $GCMD"
                    pol ${GCMD#pol } || die "targeted deploy failed"
                fi
                log_success "allocated $WHAT -> $WHERE — pol topology report && pol topology diff to verify" ;;
            *)
                die "cannot interpret 'pol allocate $WHAT $WHERE' — first arg must be a module or instance, second an instance or machine (pol topology graph)" ;;
        esac ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown topology command: $COMMAND"; show_help; exit 1 ;;
esac
