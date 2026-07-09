#!/bin/bash
# pol registry — service-kind accountability.
#
# The registry (pol-build/registry/services.yml at the suite root) is the
# catalog of EVERY service kind, its configuration variations, and the
# auto-generated interconnection artifacts that wire prf/psc instances to
# each other and to child instances. `check` enforces accountability:
# every service declared in any compose file must have a registry entry.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

REGISTRY="$POL_SUITE_ROOT/pol-build/registry/services.yml"

show_help() {
    pol_box "pol registry — service accountability"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}list${NC}              all registered service kinds (one line each)
  ${CYAN}show${NC} <kind>       full registry entry for one service kind
  ${CYAN}interconnects${NC}     the auto-generated artifacts that wire
                    instances together (runtime-configs, peer token,
                    client secrets, proxy configs, scr-7 seam)
  ${CYAN}check${NC}             ACCOUNTABILITY: diff services declared in the
                    compose files vs the registry — unregistered
                    services fail, undeployed registrations warn

Registry file: pol-build/registry/services.yml
"
}

need_pyyaml() {
    python3 -c "import yaml" 2>/dev/null || die "needs python3-yaml (apt install python3-yaml)"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    list)
        need_pyyaml
        python3 - "$REGISTRY" <<'EOF'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1]))
for s in reg["services"]:
    kinds = ", ".join(s.get("connects_to", {}).keys()) or "-"
    print(f"  {s['kind']:<18} -> {kinds}")
EOF
        ;;
    show)
        need_pyyaml
        [ -n "$1" ] || die "usage: pol registry show <kind>"
        python3 - "$REGISTRY" "$1" <<'EOF'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1]))
for s in reg["services"]:
    if s["kind"] == sys.argv[2]:
        yaml.safe_dump(s, sys.stdout, sort_keys=False, default_flow_style=False)
        break
else:
    sys.exit(f"unknown kind: {sys.argv[2]} (pol registry list)")
EOF
        ;;
    interconnects)
        need_pyyaml
        python3 - "$REGISTRY" <<'EOF'
import sys, yaml
reg = yaml.safe_load(open(sys.argv[1]))
for name, ic in reg["interconnects"].items():
    print(f"\n  {name}")
    print(f"    artifact:  {ic['artifact']}")
    print(f"    wires:     {ic['wires']}")
    print(f"    consumers: {', '.join(ic['consumed_by'])}")
EOF
        ;;
    check)
        need_pyyaml
        python3 - "$REGISTRY" "$POL_SUITE_ROOT" <<'EOF'
import sys, yaml, glob, os
reg = yaml.safe_load(open(sys.argv[1]))
root = sys.argv[2]

# service-name -> registered kind (compose service names differ per file;
# map by the appears_in declarations + known name aliases)
ALIASES = {
    "backend": {"polari-rf-node": "prf-backend", ".": "prf-backend"},
    "frontend": {"polari-rf-node": "prf-frontend", ".": "prf-frontend"},
    "backend-b": {"polari-rf-node": "prf-backend-b"},
    "frontend-b": {"polari-rf-node": "prf-frontend-b"},
    "keydb-b": {"polari-rf-node": "prf-keydb-b"},
    "prf-backend": {".": "prf-backend"}, "prf-frontend": {".": "prf-frontend"},
    "dask-worker": {"polari-rf-node": "prf-dask"},
    "polari-framework-tests": {"polari-rf-node": "prf-test-harness"},
    "polari-framework-server": {"polari-rf-node": "prf-test-harness"},
    "polari-frontend-tests": {"polari-rf-node": "prf-test-harness"},
}
registered = {s["kind"] for s in reg["services"]}
DASK_MSCI = {"dask-scheduler", "dask-worker-a", "dask-worker-b", "msci-engines",
             "prf-msci-engines", "remote-worker", "prf-dask-scheduler"}

seen = set()
problems = 0
for repo, base in ((".", root), ("polari-rf-node", os.path.join(root, "polari-rf-node"))):
    for f in sorted(glob.glob(os.path.join(base, "docker-compose*.yml"))):
        try:
            doc = yaml.safe_load(open(f))
        except Exception as e:
            print(f"  [warn] unparseable {f}: {e}"); continue
        for name in (doc or {}).get("services", {}):
            kind = ALIASES.get(name, {}).get(repo, name)
            if kind in DASK_MSCI or name in DASK_MSCI:
                kind = "prf-msci-engines" if "msci" in name or "worker" == name else "prf-dask"
            seen.add(kind)
            if kind not in registered:
                print(f"  UNREGISTERED: service '{name}' in {os.path.relpath(f, root)}")
                problems += 1
for kind in sorted(registered - seen):
    print(f"  [note] registered but not found deployed: {kind}")
print(f"\n  {len(seen)} deployed kinds checked against {len(registered)} registered")
sys.exit(1 if problems else 0)
EOF
        [ $? -eq 0 ] && log_success "registry accountability: OK" || die "unregistered services found — add them to pol-build/registry/services.yml"
        ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown registry command: $COMMAND"; show_help; exit 1 ;;
esac
