#!/bin/bash
# pol modules — PRF module visibility + dependency checks.
# Modules are the framework's feature packages (materialsScience, scoring,
# aquaponics, simulations, …) tracked by moduleService/ (moduleDiscovery,
# module_dependency_tracker). This namespace LISTS what exists, runs the
# dependency selftest against a live backend, and is honest that
# enable/disable knobs are not built yet.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

FW="$POL_RF_NODE/polari-framework"

show_help() {
    pol_box "pol modules — PRF feature modules"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}list${NC}        every module package in polari-framework (feature
              modules with selftests, legacy modules/, core packages)
  ${CYAN}deps${NC}        run moduleService's dependency selftest INSIDE the
              running prf-backend container (host python can't import
              the server — PyJWT mismatch)
  ${CYAN}selftest <module>${NC}
              run one module's selftest suite in the container
              (e.g. scoring, aquaponics, materialsScience)
  ${CYAN}registry${NC}    the module register (modules/polari-modules.json):
              official | vendor | self, downloaded flags, repos
  ${CYAN}get <module>${NC}   clone a split-out module into modules/ (mp-2 —
              refuses honestly while the module still ships in-tree)
  ${CYAN}drop <module>${NC}  remove the LOCAL copy of a split-out module
              (refuses on uncommitted work; get brings it back)

${BOLD}NOT BUILT YET${NC} (honest refusal): enable/disable per deployment —
module activation is registration-in-code today (polariServer). A
module-manifest knob (registry-driven, per-instance) is future work;
the service registry's variations field is where it will hang."
}

COMMAND=$1; shift || true
case "$COMMAND" in
    list)
        pol_box "PRF module packages"
        echo "  feature modules (selftest-bearing; both import roots — mp-1):"
        for d in "$FW"/*/ "$FW"/modules/*/; do
            n=$(basename "$d")
            [ "$n" = "modules" ] && continue
            if ls "$d"selftest_*.py >/dev/null 2>&1; then
                loc=""
                case "$d" in */modules/*) loc=" [modules/]" ;; esac
                cnt=$(ls "$d"selftest_*.py | wc -l)
                printf "    %-24s %s selftest suite(s)%s\n" "$n" "$cnt" "$loc"
            fi
        done
        echo "  registry modules (modules/):"
        for d in "$FW"/modules/*/; do echo "    $(basename "$d")"; done
        echo "  register: $FW/modules/polari-modules.json (pol modules registry)"
        echo "  module machinery: moduleService/ (discovery, dependency tracker, scaffolder)" ;;
    registry)
        pol_box "polari module register (modules/polari-modules.json)"
        python3 - "$FW/modules/polari-modules.json" "$FW" <<'PYEOF'
import json, os, sys
path, root = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(path))
except Exception as e:
    sys.exit(f'no readable register at {path}: {e}')
for name, e in sorted(doc.get('modules', {}).items()):
    here = os.path.isdir(os.path.join(root, e.get('path', '')))
    flag = 'downloaded' if here else 'NOT downloaded'
    repo = e.get('repo') or '(ships with this checkout — repo split pending mp-2)'
    print(f"  {name:20} {e.get('kind','?'):8} {flag:14} {repo}")
    if e.get('description'):
        print(f"  {'':20} {e['description']}")
PYEOF
        ;;
    get|drop)
        MOD=${1:?usage: pol modules $COMMAND <module>}
        REPO=$(python3 -c "
import json,sys
doc=json.load(open('$FW/modules/polari-modules.json'))
print(doc.get('modules',{}).get('$MOD',{}).get('repo',''))" 2>/dev/null || true)
        if [ -z "$REPO" ]; then
            die "'$MOD' has not been split into its own repo yet (MODULE_PROJECTS_PLAN mp-2) — its code ships with this checkout; nothing to $COMMAND. The register is $FW/modules/polari-modules.json"
        fi
        if [ "$COMMAND" = "get" ]; then
            log_info "git clone $REPO -> modules/$MOD"
            git -C "$FW/modules" clone "$REPO" "$MOD" || die "clone failed"
            log_success "downloaded — the register's downloaded flag re-derives from the filesystem"
        else
            [ -d "$FW/modules/$MOD/.git" ] || die "modules/$MOD is not its own git checkout — refusing to delete code that may hold local work"
            if [ -n "$(git -C "$FW/modules/$MOD" status --porcelain)" ]; then
                die "modules/$MOD has uncommitted changes — commit/push them first"
            fi
            log_info "removing local copy modules/$MOD (repo: $REPO)"
            rm -rf "$FW/modules/$MOD"
            log_success "dropped — pol modules get $MOD brings it back"
        fi ;;
    deps)
        docker ps --format '{{.Names}}' | grep -qx prf-backend || die "prf-backend not running — pol suite up / pol node up first"
        log_info "Running module dependency selftest in prf-backend"
        docker exec prf-backend python3 -m moduleService.selftest_module_dependencies ;;
    selftest)
        MOD=$1
        [ -n "$MOD" ] || die "usage: pol modules selftest <module> (see pol modules list)"
        docker ps --format '{{.Names}}' | grep -qx prf-backend || die "prf-backend not running — pol suite up / pol node up first"
        FOUND=0
        # mp-1: modules live in either import root; PYTHONPATH in the
        # image resolves modules/<m> under its plain name.
        for st in $(docker exec prf-backend sh -c "ls $MOD/selftest_*.py 2>/dev/null || ls modules/$MOD/selftest_*.py 2>/dev/null" | sed 's#^modules/##; s/\.py$//' | tr / .); do
            FOUND=1
            log_info "docker exec prf-backend python3 -m $st"
            docker exec prf-backend python3 -m "$st"
        done
        [ "$FOUND" = "1" ] || die "no selftests found for module '$MOD' (pol modules list)" ;;
    enable|disable)
        die "module enable/disable lives on the TOPOLOGY now: ModuleAssignment rows on the core instance. Use 'pol topology assign <module> <instance>' (or drag the module chip in the Topology tab). In-process activation is still registration-in-code (polariServer)." ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown modules command: $COMMAND"; show_help; exit 1 ;;
esac
