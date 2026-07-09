#!/bin/bash
# pol build — the jinja-script build pipeline.
#
# CURRENT STATE (bld-1): wraps the EXISTING rf-node jinja-gen renderer
# (Ansible port of the isle-mesh embed-jinja engine) + its semantic parity
# harness. Later phases (see BUILD_SYSTEM_PLAN.md):
#   bld-2  pol-build/ python renderer + credential-free manifests
#   bld-3  per-service annotated files under pol-services/
#   bld-4  proxy generation (segments/assembly, nginx -t validation)
#   bld-5  swarm output mode ('pol build render --topology swarm')
# The command surface here is designed for that future — flags that are
# not implemented yet REFUSE with the exact phase that adds them (honest
# absence, knobs-and-suggestions).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

show_help() {
    pol_box "pol build — jinja-script pipeline"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}render${NC} [--topology single|swarm]
        Render the compose family from templates into jinja-build/.
        Currently: rf-node jinja-gen (ansible). --topology swarm is
        NOT built yet (arrives in bld-5; single is the only mode).

  ${CYAN}parity${NC}
        Semantic parity: 'docker compose config' of each generated file
        diffed against its hand-written twin (all 10 rf-node variants).

  ${CYAN}detect${NC} [project_dir]
        List files carrying inline jinja-script markers (# jinja-start).

  ${CYAN}clean${NC}
        Remove rendered mirror trees (jinja-build/).

${BOLD}PIPELINE${NC} (isle-mesh embed-jinja idiom)
  annotated working file  --detect/process-->  jinja-templates/<f>.j2
  jinja-templates/*.j2    --render--------->  jinja-build/<f>
  jinja-build/<f>         --parity--------->  vs hand-written <f>
"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    render)
        TOPOLOGY="single"
        while [ $# -gt 0 ]; do case "$1" in
            --topology) TOPOLOGY="$2"; shift 2 ;;
            *) shift ;;
        esac; done
        if [ "$TOPOLOGY" = "swarm" ]; then
            die "swarm topology is not built yet — it lands in bld-5 (BUILD_SYSTEM_PLAN.md §3). Only --topology single renders today."
        fi
        command -v ansible-playbook >/dev/null 2>&1 || \
            die "ansible-playbook not found (bld-2 replaces it with a python renderer). Install: pipx install ansible-core"
        cd "$POL_RF_NODE"
        log_info "Rendering rf-node compose family via jinja-gen/playbook.yml"
        ansible-playbook jinja-gen/playbook.yml
        log_success "rendered into $POL_RF_NODE/jinja-build/" ;;
    parity)
        cd "$POL_RF_NODE"
        exec bash jinja-gen/check-parity.sh ;;
    detect)
        PROJ="${1:-$POL_RF_NODE}"
        exec bash "$POL_RF_NODE/jinja-gen/embedded-jinja-detector.sh" "$PROJ" ;;
    clean)
        rm -rf "$POL_RF_NODE/jinja-build"
        log_success "removed $POL_RF_NODE/jinja-build" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown build command: $COMMAND"; show_help; exit 1 ;;
esac
