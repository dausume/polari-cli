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
              official | vendor | self, downloaded flags, repos,
              sizes, migration waves, requires
  ${CYAN}get <module>${NC}   clone a split-out module into modules/ (mp-2 —
              refuses honestly while the module still ships in-tree)
  ${CYAN}drop <module>${NC}  remove the LOCAL copy of a split-out module
              (refuses on uncommitted work, on required_by_core, and
              while a downloaded module requires it)
  ${CYAN}publish <module> [--repo <git-url>]${NC}
              mp-2 split: git subtree split modules/<m> (history
              kept) + push to the module's own repo; prints every
              git command it runs. --repo fills the register field
              the first time.
  ${CYAN}register <name> [--vendor <git-url>] [--kind k] [--path p]
              [--repo url] [--desc text]${NC}
              upsert a register entry. --vendor = third-party module
              (kind vendor, downloaded after 'pol modules get')

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

def dir_size(d):
    total = 0
    for base, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x != '__pycache__']
        for f in files:
            try:
                total += os.path.getsize(os.path.join(base, f))
            except OSError:
                pass
    if total >= 1 << 20:
        return f'{total / (1 << 20):.1f}M'
    return f'{total / (1 << 10):.0f}K'

for name, e in sorted(doc.get('modules', {}).items()):
    mod_dir = os.path.join(root, e.get('path', ''))
    here = os.path.isdir(mod_dir)
    flag = 'downloaded' if here else 'NOT downloaded'
    size = dir_size(mod_dir) if here else '-'
    repo = e.get('repo') or '(ships with this checkout — repo split pending mp-2)'
    wave = f" wave {e['wave']}" if e.get('wave') is not None else ''
    print(f"  {name:20} {e.get('kind','?'):8} {flag:14} {size:>7}"
          f"{wave}  {repo}")
    tags = []
    if e.get('required_by_core'):
        tags.append('required_by_core (drop refuses)')
    if e.get('requires'):
        tags.append('requires: ' + ', '.join(e['requires']))
    if tags:
        print(f"  {'':20} [{'; '.join(tags)}]")
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
            die "'$MOD' has not been split into its own repo yet (MODULE_PROJECTS_PLAN mp-2) — its code ships with this checkout; nothing to $COMMAND. The register is $FW/modules/polari-modules.json (pol modules publish $MOD does the split)"
        fi
        if [ "$COMMAND" = "get" ]; then
            [ -d "$FW/modules/$MOD" ] && die "modules/$MOD is already downloaded"
            log_info "git clone $REPO -> modules/$MOD"
            git -C "$FW/modules" clone "$REPO" "$MOD" || die "clone failed"
            log_success "downloaded — the register's downloaded flag re-derives from the filesystem"
        else
            # mp-3 coherence: refuse drops the core (or another
            # downloaded module) still depends on.
            BLOCK=$(python3 - "$FW" "$MOD" <<'PYEOF'
import json, os, sys
root, mod = sys.argv[1], sys.argv[2]
doc = json.load(open(os.path.join(root, 'modules', 'polari-modules.json')))
mods = doc.get('modules', {})
entry = mods.get(mod, {})
if entry.get('required_by_core'):
    print(f"'{mod}' is required_by_core — the framework imports it "
          f"statically; it cannot be dropped")
    sys.exit(0)
for name, e in mods.items():
    here = os.path.isdir(os.path.join(root, e.get('path', f'modules/{name}')))
    if here and mod in (e.get('requires') or []):
        print(f"downloaded module '{name}' requires '{mod}' — drop "
              f"'{name}' first (or keep both)")
        sys.exit(0)
PYEOF
)
            [ -n "$BLOCK" ] && die "$BLOCK"
            [ -d "$FW/modules/$MOD/.git" ] || die "modules/$MOD is not its own git checkout — refusing to delete code that may hold local work"
            if [ -n "$(git -C "$FW/modules/$MOD" status --porcelain)" ]; then
                die "modules/$MOD has uncommitted changes — commit/push them first"
            fi
            log_info "removing local copy modules/$MOD (repo: $REPO)"
            rm -rf "$FW/modules/$MOD"
            log_success "dropped — pol modules get $MOD brings it back"
        fi ;;
    publish)
        MOD=${1:?usage: pol modules publish <module> [--repo <git-url>]}; shift
        REPO_ARG=""
        while [ $# -gt 0 ]; do case "$1" in
            --repo) REPO_ARG=$2; shift 2 ;;
            *) die "unknown publish option: $1" ;;
        esac; done
        [ -d "$FW/modules/$MOD" ] || {
            if [ -d "$FW/$MOD" ]; then
                die "'$MOD' still lives at the framework root — run its mp-4 migration wave (git mv into modules/) before publishing; see MODULE_PROJECTS_PLAN.md"
            fi
            die "no modules/$MOD directory (pol modules registry)"
        }
        REPO=$(python3 -c "
import json
doc=json.load(open('$FW/modules/polari-modules.json'))
print(doc.get('modules',{}).get('$MOD',{}).get('repo',''))")
        if [ -n "$REPO_ARG" ]; then
            REPO=$REPO_ARG
            python3 - "$FW" "$MOD" "$REPO" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from moduleService.module_registry import load_registry, save_registry
root, mod, repo = sys.argv[1:4]
doc = load_registry(root)
entry = doc['modules'].setdefault(mod, {'kind': 'official', 'path': f'modules/{mod}', 'description': ''})
entry['repo'] = repo
save_registry(doc, root)
print(f'register: {mod}.repo = {repo}')
PYEOF
        fi
        [ -n "$REPO" ] || die "'$MOD' has no repo in the register — pass --repo <git-url> the first time (create the repo first, e.g.: gh repo create polari-module-$MOD --public)"
        SPLIT_BRANCH="_split-$MOD"
        pol_box "publish $MOD -> $REPO (in-tree copy stays AUTHORITATIVE until mp-3/mp-4 retire it)"
        log_info "RUN: git -C $FW subtree split --prefix=modules/$MOD -b $SPLIT_BRANCH"
        git -C "$FW" subtree split --prefix="modules/$MOD" -b "$SPLIT_BRANCH" || die "subtree split failed"
        log_info "RUN: git -C $FW push $REPO $SPLIT_BRANCH:main"
        git -C "$FW" push "$REPO" "$SPLIT_BRANCH:main" || {
            git -C "$FW" branch -D "$SPLIT_BRANCH" >/dev/null 2>&1
            die "push failed (does the repo exist + do you have access?)"
        }
        log_info "RUN: git -C $FW branch -D $SPLIT_BRANCH"
        git -C "$FW" branch -D "$SPLIT_BRANCH"
        log_success "published modules/$MOD -> $REPO (main). Re-run after in-tree changes to re-push the subtree." ;;
    register)
        MOD=${1:?usage: pol modules register <name> [--vendor <git-url>] [--kind k] [--path p] [--repo url] [--desc text]}; shift
        KIND="" PATH_ARG="" REPO_ARG="" DESC=""
        while [ $# -gt 0 ]; do case "$1" in
            --vendor) KIND=vendor; REPO_ARG=$2; shift 2 ;;
            --kind) KIND=$2; shift 2 ;;
            --path) PATH_ARG=$2; shift 2 ;;
            --repo) REPO_ARG=$2; shift 2 ;;
            --desc) DESC=$2; shift 2 ;;
            *) die "unknown register option: $1" ;;
        esac; done
        python3 - "$FW" "$MOD" "$KIND" "$PATH_ARG" "$REPO_ARG" "$DESC" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from moduleService.module_registry import (MODULE_KINDS, load_registry,
                                           save_registry)
root, mod, kind, path, repo, desc = sys.argv[1:7]
doc = load_registry(root)
entry = doc['modules'].get(mod, {})
kind = kind or entry.get('kind') or 'official'
if kind not in MODULE_KINDS:
    sys.exit(f'kind "{kind}" not one of {MODULE_KINDS}')
entry['kind'] = kind
entry['path'] = path or entry.get('path') or f'modules/{mod}'
if repo:
    entry['repo'] = repo
else:
    entry.setdefault('repo', '')
if desc:
    entry['description'] = desc
else:
    entry.setdefault('description', '')
doc['modules'][mod] = entry
save_registry(doc, root)
fresh = load_registry(root)['modules'][mod]
flag = 'downloaded' if fresh['downloaded'] else 'NOT downloaded (pol modules get)'
print(f"registered: {mod} kind={fresh['kind']} path={fresh['path']} "
      f"repo={fresh['repo'] or '(none)'} — {flag}")
PYEOF
        ;;
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
