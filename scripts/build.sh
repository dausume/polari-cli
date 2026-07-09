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
  ${CYAN}render${NC} [bundle] [--topology single|swarm]
        Render the compose bundle family into jinja-build/ — all ten, or
        ONE bundle by name (e.g. 'render docker-compose.twin-b.yml').
        --topology swarm is NOT built yet (bld-5; single only).

  ${CYAN}list${NC}
        Every compose bundle: hand-written file, generated twin, and
        whether a generator covers it (the suite-root trio has none
        until bld-3).

  ${CYAN}promote${NC} [--project suite]
        Copy freshly rendered bundles OVER the root deployable files —
        the explicit step after editing pol-services/ sources. Shows a
        diffstat per file; refuses if nothing was rendered.

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
    list)
        pol_box "compose bundles (hand-written vs generated)"
        echo "  rf-node family (generator: pol build render — parity-harnessed):"
        for f in "$POL_RF_NODE"/docker-compose*.yml; do
            b=$(basename "$f")
            gen="$POL_RF_NODE/jinja-build/$b"
            state="generated-twin $( [ -f "$gen" ] && echo present || echo MISSING — run pol build render )"
            printf "    %-38s %s\n" "$b" "$state"
        done
        echo "  suite-root trio (NO generator yet — bld-3 covers them):"
        for f in "$POL_SUITE_ROOT"/docker-compose*.yml; do
            printf "    %-38s hand-written only\n" "$(basename "$f")"
        done
        echo
        echo "  lifecycle wrappers: suite/node/engines/dask/twin/remote-worker roles"
        echo "  (pol compose help); dbcombo overlay via 'pol db use combo --role twin'" ;;
    render)
        TOPOLOGY="single"; ONLY=""; PROJECT="node"
        while [ $# -gt 0 ]; do case "$1" in
            --topology) TOPOLOGY="$2"; shift 2 ;;
            --project)  PROJECT="$2"; shift 2 ;;
            -*) shift ;;
            *) ONLY="$1"; shift ;;
        esac; done
        if [ "$PROJECT" = "suite" ]; then
            log_info "Rendering suite bundles (per-service annotated sources -> dev/staging/prod)"
            python3 "$POL_SUITE_ROOT/pol-build/render.py" "$POL_SUITE_ROOT" \
                --manifest "$POL_SUITE_ROOT/pol-build/manifests/suite-bundles.yml" \
                && log_success "suite trio rendered, byte-parity verified" \
                || die "suite bundle parity FAILED — inspect jinja-build/ diffs"
            exit 0
        fi
        if [ "$TOPOLOGY" = "swarm" ]; then
            die "swarm topology is not built yet — it lands in bld-5 (BUILD_SYSTEM_PLAN.md §3). Only --topology single renders today."
        fi
        # bld-3: manifest render — per-service/bundle annotated sources
        # (polari-rf-node/pol-services/) -> all ten variants, byte-parity
        # gated against the root files.
        python3 -c "import jinja2, yaml" 2>/dev/null || \
            die "needs python3-jinja2 + pyyaml to render (pip install jinja2 pyyaml)"
        log_info "Rendering the rf-node bundle family (per-service annotated sources)"
        python3 "$POL_SUITE_ROOT/pol-build/render.py" "$POL_RF_NODE" \
            --manifest "$POL_SUITE_ROOT/pol-build/manifests/node-bundles.yml" \
            && log_success "all ten rf-node bundles rendered, byte-parity verified" \
            || die "node bundle parity FAILED — a root compose file drifted from pol-services/ (edit the source, render, then 'pol build promote')" ;;
    promote)
        # Only the suite manifest promotes today; rf-node root files are
        # still hand-canonical until its re-authoring lands.
        MAPPING="docker-compose.yml docker-compose.staging-nip.yml docker-compose.prod.yml"
        PROMOTED=0
        for f in $MAPPING; do
            GEN="$POL_SUITE_ROOT/jinja-build/$f"
            [ -f "$GEN" ] || die "no rendered $f — run: pol build render --project suite"
            if ! diff -q "$GEN" "$POL_SUITE_ROOT/$f" >/dev/null 2>&1; then
                CH=$(diff "$GEN" "$POL_SUITE_ROOT/$f" | grep -c '^[<>]' || true)
                cp "$GEN" "$POL_SUITE_ROOT/$f"
                log_success "promoted $f ($CH changed line(s))"
                PROMOTED=1
            else
                log_info "$f already up to date"
            fi
        done
        [ "$PROMOTED" = "1" ] && log_warn "review + commit the promoted root files" ;;
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
