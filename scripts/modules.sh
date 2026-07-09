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

${BOLD}NOT BUILT YET${NC} (honest refusal): enable/disable per deployment —
module activation is registration-in-code today (polariServer). A
module-manifest knob (registry-driven, per-instance) is future work;
the service registry's variations field is where it will hang."
}

COMMAND=$1; shift || true
case "$COMMAND" in
    list)
        pol_box "PRF module packages"
        echo "  feature modules (selftest-bearing):"
        for d in "$FW"/*/; do
            n=$(basename "$d")
            if ls "$d"selftest_*.py >/dev/null 2>&1; then
                cnt=$(ls "$d"selftest_*.py | wc -l)
                printf "    %-24s %s selftest suite(s)\n" "$n" "$cnt"
            fi
        done
        echo "  legacy modules/ dir:"
        for d in "$FW"/modules/*/; do echo "    $(basename "$d")"; done
        echo "  module machinery: moduleService/ (discovery, dependency tracker, scaffolder)" ;;
    deps)
        docker ps --format '{{.Names}}' | grep -qx prf-backend || die "prf-backend not running — pol suite up / pol node up first"
        log_info "Running module dependency selftest in prf-backend"
        docker exec prf-backend python3 -m moduleService.selftest_module_dependencies ;;
    selftest)
        MOD=$1
        [ -n "$MOD" ] || die "usage: pol modules selftest <module> (see pol modules list)"
        docker ps --format '{{.Names}}' | grep -qx prf-backend || die "prf-backend not running — pol suite up / pol node up first"
        FOUND=0
        for st in $(docker exec prf-backend sh -c "ls $MOD/selftest_*.py 2>/dev/null" | sed 's/\.py$//' | tr / .); do
            FOUND=1
            log_info "docker exec prf-backend python3 -m $st"
            docker exec prf-backend python3 -m "$st"
        done
        [ "$FOUND" = "1" ] || die "no selftests found for module '$MOD' (pol modules list)" ;;
    enable|disable)
        die "module enable/disable knobs are not built yet — activation is registration-in-code (polariServer). See 'pol modules help'." ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown modules command: $COMMAND"; show_help; exit 1 ;;
esac
