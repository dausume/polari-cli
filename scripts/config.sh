#!/bin/bash
# pol config — effective-configuration visibility, with NESTED per-service
# views (pol config service <kind> …) backed by the service registry.
# Read-only by design: values are CHANGED via the setup scripts + knobs
# (pol security …) or by editing the generated files they own — this
# namespace tells you what is in effect, where it came from, and which
# knob moves it.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

REGISTRY="$POL_SUITE_ROOT/pol-build/registry/services.yml"

show_help() {
    pol_box "pol config — effective configuration"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}show${NC}              the whole picture: env selection, LOCAL_IP,
                    credential files, generated artifacts, knobs set
  ${CYAN}knobs${NC}             every POLARI_* knob: purpose, current state
  ${CYAN}generated${NC}         generated artifacts + which script owns each
  ${CYAN}env${NC}               environment selection (rf setup.yml current-setup,
                    LOCAL_IP autodetection)

${BOLD}NESTED — per-service configuration${NC}
  ${CYAN}service <kind>${NC}            full config surface of one service kind
  ${CYAN}service <kind> files${NC}      just its env files/mounts + existence
  ${CYAN}service <kind> knobs${NC}      just its knobs + current state
  ${CYAN}service <kind> connects${NC}   its interconnects (what wires it to whom)
  (kinds: pol registry list)

${BOLD}HOW TO CHANGE VALUES${NC}
  Credentials    pol security setup [dev|prod] (+ knobs, see 'pol config knobs')
  Env selection  edit polari-rf-node/setup.yml current-setup.env
  Per-run        export the knob before the command (e.g. LOCAL_IP=…)
"
}

need_pyyaml() { python3 -c "import yaml" 2>/dev/null || die "needs python3-yaml"; }

# Knob catalog: name | what it configures | consumed by
KNOBS="POLARI_SUITE_ROOT|suite checkout location (out-of-tree installs)|pol dispatcher
LOCAL_IP|staging address for nip.io domains + compose interpolation|all staging flows
POLARI_KC_ADMIN_USER|suite Keycloak admin username|setup-polari-security.sh
POLARI_KC_ADMIN_PASS|Keycloak admin password (suite + rf-node)|setup scripts
POLARI_MYSQL_ROOT_PASS|suite MariaDB root password|setup-polari-security.sh
POLARI_KC_DB_PASS|Keycloak DB user password (suite + rf-node)|setup scripts
POLARI_PSC_DB_PASS|PSC DB user password|setup-polari-security.sh
POLARI_MINIO_ROOT_USER|MinIO root/access user|setup scripts + compose interpolation
POLARI_MINIO_ROOT_PASS|MinIO root/secret password|setup scripts + compose interpolation
POLARI_MARIADB_ROOT_PASS|rf-node MariaDB root password|staging/prod-setup.sh
POLARI_OBJECTS_DB_PASS|rf-node polari object-DB password (dbcombo)|staging/prod-setup.sh + compose
POLARI_KEYDB_PASS|twin-B KeyDB password|dbcombo compose
POLARI_BE_SECRET|polari-backend KC client secret override|staging/prod-setup.sh
POLARI_CONFIRM_PROD|skip the are-you-on-prod prompt (yes)|setup-polari-security.sh
POLARI_PROD_DOMAIN|production domain|rf prod-setup.sh
POLARI_STAGING_DOMAIN|custom staging base domain (e.g. polari-staging.test); unset = <LOCAL_IP>.nip.io|nip-staging-setup.sh, pol suite up
CERT_MODE|staging cert trust: self-signed (default) or step-ca (unified internal root + guided walkthrough)|nip-staging-setup.sh
CERT_BACKEND|prod/suite Phase-3 knob: step-ca (default once triggered) — internal cert issuer|setup-polari-security.sh, ca/*.sh
PUBLIC_EDGE|prod Phase-3 knob: letsencrypt for a browser-trusted public edge, else none|setup-polari-security.sh, ca/*.sh
LE_DOMAIN|Let's Encrypt domain for the public edge cert|ca/setup-letsencrypt.sh
LE_EMAIL|Let's Encrypt account email|ca/setup-letsencrypt.sh
DO_API_TOKEN|DigitalOcean DNS API token (DNS-01 challenge for Let's Encrypt)|ca/setup-letsencrypt.sh"

knob_state() { [ -n "${!1:-}" ] && echo -e "${GREEN}set${NC}" || echo -e "${DIM}unset${NC}"; }

cmd_knobs() {
    pol_box "POLARI_* knobs"
    echo "$KNOBS" | while IFS='|' read -r k desc who; do
        printf "  %-26b %-7b %s\n" "${CYAN}$k${NC}" "$(knob_state "$k")" "$desc  ${who:+(→ $who)}"
    done
    echo -e "\n  Set a knob for one run:  ${CYAN}POLARI_KC_DB_PASS=… pol security setup prod${NC}"
}

cmd_env() {
    pol_box "environment selection"
    local cur_env
    cur_env=$(grep -A1 "^current-setup:" "$POL_RF_NODE/setup.yml" 2>/dev/null | grep "env:" | awk '{print $2}')
    echo "  rf-node setup.yml current-setup.env : ${cur_env:-<unreadable>}"
    echo "  LOCAL_IP (env)                      : ${LOCAL_IP:-<unset — autodetects to $(lan_ip)>}"
    echo "  suite .env (compose interpolation)  : $([ -f "$POL_SUITE_ROOT/.env" ] && echo present || echo 'MISSING — pol security setup')"
}

cmd_generated() {
    pol_box "generated artifacts (owner script → artifact)"
    need_pyyaml
    python3 - "$REGISTRY" "$POL_SUITE_ROOT" <<'EOF'
import sys, yaml, glob, os
reg = yaml.safe_load(open(sys.argv[1])); root = sys.argv[2]
for name, ic in reg["interconnects"].items():
    pats = ic["artifact"].split(" + ")
    for pat in pats:
        pat = pat.split(" (")[0].strip()
        if "{" in pat:  # brace expansion e.g. {minio,client}.env
            base, rest = pat.split("{"); opts, tail = rest.split("}")
            expanded = [base + o + tail for o in opts.split(",")]
        else:
            expanded = [pat]
        for e in expanded:
            hits = glob.glob(os.path.join(root, e))
            state = "present" if hits else "absent"
            gen = ", ".join(ic["generated_by"]) if isinstance(ic["generated_by"], list) else ic["generated_by"]
            print(f"  [{state:^7}] {e}")
            print(f"            generated by: {gen}")
EOF
}

cmd_service() {
    need_pyyaml
    local kind="$1" sub="${2:-show}"
    [ -n "$kind" ] || die "usage: pol config service <kind> [show|files|knobs|connects] — kinds: pol registry list"
    python3 - "$REGISTRY" "$POL_SUITE_ROOT" "$kind" "$sub" <<'EOF'
import sys, yaml, os
reg = yaml.safe_load(open(sys.argv[1])); root, kind, sub = sys.argv[2:5]
svc = next((s for s in reg["services"] if s["kind"] == kind), None)
if not svc: sys.exit(f"unknown kind '{kind}' — see: pol registry list")
cfg = svc.get("config") or {}
def exists(p):
    p = p.split(" | ")[0].split(" (")[0].strip()
    return "present" if os.path.exists(os.path.join(root, p)) else "absent/generated-later"
if sub in ("show",):
    print(f"\n  kind:      {kind}")
    print(f"  context:   {svc.get('context','-')}")
    print(f"  deploys:   {len(svc.get('appears_in',[]))} compose file(s)")
    for f in svc.get("appears_in", []): print(f"             - {f}")
    if svc.get("variations"): print(f"  variations: {svc['variations']}")
if sub in ("show", "files"):
    print("  config files:")
    for key in ("env_files", "mounts", "baked", "generated", "interpolation", "certs"):
        for f in (cfg.get(key) or ([] if not isinstance(cfg.get(key), str) else [cfg[key]])):
            tag = f"[{exists(f)}]" if key in ("env_files","mounts","generated") else f"[{key}]"
            print(f"    {tag:>24}  {f}")
    if not cfg: print("    (none — image defaults only)")
if sub in ("show", "knobs"):
    knobs = cfg.get("knobs") or []
    print("  knobs:")
    for k in knobs:
        name = k.split(" ")[0]
        state = "set" if os.environ.get(name) else "unset"
        print(f"    [{state:^5}]  {k}")
    if not knobs: print("    (none)")
if sub in ("show", "connects"):
    print("  connects to:")
    for peer, via in (svc.get("connects_to") or {}).items():
        via_s = via if isinstance(via, str) else "(direct)"
        print(f"    {peer:<18} via {via_s}")
        if isinstance(via, str) and via in reg["interconnects"]:
            print(f"    {'':<18}     {reg['interconnects'][via]['wires']}")
EOF
}

COMMAND=$1; shift || true
case "$COMMAND" in
    show)
        cmd_env; echo; bash "$SCRIPT_DIR/security.sh" status; echo; cmd_knobs ;;
    knobs)     cmd_knobs ;;
    env)       cmd_env ;;
    generated) cmd_generated ;;
    service)   cmd_service "$@" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown config command: $COMMAND"; show_help; exit 1 ;;
esac
