#!/bin/bash
# pol deploy — shell-based ssh deployment to configured nodes (bld-6,
# isle-mesh join.sh idiom). Targets live in pol-build/manifests/nodes.yml
# (no secrets — credentials SELF-GENERATE on the target via the setup
# scripts; certs interlink via the ca/ toolkit + generated proxy configs).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"

show_help() {
    pol_box "pol deploy — ssh deploys to configured nodes"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}nodes${NC}                     list configured targets + their roles
  ${CYAN}preflight <node>${NC}          ssh reachability, docker, git, disk — no changes
  ${CYAN}run <node> --role <r>${NC}     full deploy: clone/pull the public repo on the
                            target, run the self-generating setup, bring the
                            role up (engines|remote-worker|node)
  ${CYAN}run <node> --role <r> --dry-run${NC}
                            print every remote command without executing

${BOLD}HOW IT STAYS SECURE${NC}
  - ssh key auth only (aliases from ~/.ssh/config)
  - repos are public; nothing secret is pushed — the target GENERATES its
    own credentials (setup scripts are skip-if-exists + random)
  - remote-worker role points back at this node's scheduler via CORE_IP

Targets: pol-build/manifests/nodes.yml
"
}

node_field() {  # node_field <node> <field>
    python3 - "$NODES_FILE" "$1" "$2" <<'EOF'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1]))
n = reg["nodes"].get(sys.argv[2]) or sys.exit(f"unknown node '{sys.argv[2]}' — pol deploy nodes")
print(n[sys.argv[3]] if sys.argv[3] in n else reg.get(sys.argv[3], ""))
EOF
}

COMMAND=$1; shift || true
case "$COMMAND" in
    nodes)
        python3 - "$NODES_FILE" <<'EOF'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1]))
for name, n in reg["nodes"].items():
    print(f"  {name:<12} ssh={n['ssh']:<12} roles={','.join(n['roles'])}")
    print(f"  {'':<12} {n.get('notes','')}")
EOF
        ;;
    preflight)
        NODE=${1:?node required (pol deploy nodes)}
        SSH=$(node_field "$NODE" ssh)
        pol_box "preflight: $NODE ($SSH)"
        ssh -o ConnectTimeout=8 "$SSH" '
            echo "  host:    $(hostname) ($(uname -m))"
            echo "  docker:  $(docker --version 2>/dev/null || echo MISSING)"
            docker info >/dev/null 2>&1 && echo "  daemon:  reachable (no sudo)" || echo "  daemon:  NOT reachable without sudo"
            echo "  git:     $(git --version 2>/dev/null || echo MISSING)"
            echo "  python3: $(python3 --version 2>/dev/null || echo MISSING)"
            echo "  disk:    $(df -h ~ | tail -1 | awk "{print \$4\" free\"}")"
            echo "  mem:     $(free -h | awk "/^Mem/{print \$7\" available\"}")"
        ' && log_success "preflight OK — pol deploy run $NODE --role <r>" ;;
    run)
        NODE=${1:?node required}; shift || true
        ROLE=""; DRY=false
        while [ $# -gt 0 ]; do case "$1" in
            --role) ROLE="$2"; shift 2 ;;
            --dry-run) DRY=true; shift ;;
            *) shift ;;
        esac; done
        [ -n "$ROLE" ] || die "need --role (engines|remote-worker|node) — see 'pol deploy nodes' for what $NODE supports"
        SSH=$(node_field "$NODE" ssh)
        DIR=$(node_field "$NODE" repo_dir)
        URL=$(node_field "$NODE" repo_url)
        CORE_IP="${LOCAL_IP:-$(hostname -I | awk '{print $1}')}"

        case "$ROLE" in
            engines)
                UP_CMD="cd $DIR/polari-rf-node && docker compose -f docker-compose.msci-engines.yml up -d --build" ;;
            remote-worker)
                UP_CMD="cd $DIR/polari-rf-node && CORE_IP=$CORE_IP docker compose -f docker-compose.remote-worker.yml --profile dask up -d --build" ;;
            node)
                UP_CMD="cd $DIR/polari-rf-node && LOCAL_IP=\$(hostname -I | awk '{print \$1}') ./staging-setup.sh && LOCAL_IP=\$(hostname -I | awk '{print \$1}') docker compose -f docker-compose.staging-nip.yml up -d --build" ;;
            *) die "unknown role '$ROLE' (engines|remote-worker|node)" ;;
        esac

        STEPS=(
            "if [ -d $DIR/.git ]; then git -C $DIR pull --recurse-submodules; else git clone --recurse-submodules $URL $DIR; fi"
            "$UP_CMD"
        )
        pol_box "deploy: $NODE role=$ROLE (core ip $CORE_IP)"
        for s in "${STEPS[@]}"; do
            if $DRY; then
                echo "  [dry-run] ssh $SSH '$s'"
            else
                log_info "ssh $SSH: ${s:0:80}…"
                ssh "$SSH" "$s"
            fi
        done
        if ! $DRY; then
            log_success "deployed $ROLE on $NODE"
        else
            log_info "dry-run complete — rerun without --dry-run to execute"
        fi ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown deploy command: $COMMAND"; show_help; exit 1 ;;
esac
