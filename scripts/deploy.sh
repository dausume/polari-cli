#!/bin/bash
# pol deploy — shell-based ssh deployment to configured nodes (bld-6,
# isle-mesh join.sh idiom). Targets live in pol-build/manifests/nodes.yml
# (no secrets — credentials SELF-GENERATE on the target via the setup
# scripts; certs interlink via the ca/ toolkit + generated proxy configs).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/core-api.sh"

NODES_FILE="$POL_SUITE_ROOT/pol-build/manifests/nodes.yml"

show_help() {
    pol_box "pol deploy — ssh deploys to configured nodes"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}nodes${NC}                     list configured targets + their roles
  ${CYAN}preflight <node>${NC}          ssh reachability, docker, git, disk — no changes
  ${CYAN}run <node> --role <r>${NC}     full deploy: clone/pull the public suite repo on the
                            target (ff-only, then ONLY the role's pieces via
                            bootstrap-dev.sh — never the whole forest), run the
                            self-generating setup, bring the role up
                            (engines|remote-worker|node)
  ${CYAN}selftest <node> [--ref BRANCH] [--modules a.b_selftest,…]${NC}
                            run framework selftests on that machine (a separate
                            <repo_dir>-test checkout at the ref; deps in a private
                            pip --target folder; host engines images) — keeps
                            heavy test runs off the live-stack machine
  ${CYAN}run <node> --role <r> --dry-run${NC}
                            print every remote command without executing

${BOLD}HOW IT STAYS SECURE${NC}
  - ssh key auth only (aliases from ~/.ssh/config)
  - repos are public; nothing secret is pushed — the target GENERATES its
    own credentials (setup scripts are skip-if-exists + random)
  - remote-worker role points back at this node's scheduler via CORE_IP

  ${CYAN}install${NC} <node> --route swarm-worker|swarm-server|isle-member|isle-core [--profile lean|full --domain D] [--dry-run]
              put a Polari instance on a nodes.yml machine over ssh:
                swarm-worker  docker + join THIS manager's swarm (work is placed by pol allocate)
                swarm-server  docker + the suite checkout + pol, then `pol prod apply --yes` THERE
                isle-member   fetch this isle's bootstrap from its core and run it (sudo; --host to host apps)
                isle-core     ship the polari-complete deb, install it, run `isle core-install` (interactive)
  ${CYAN}status${NC} <node>   what runs there: swarm node + tasks placed on it, or the isle (router, agent,
              polari.isle answering, open doors, hardware guests) — read-only, over ssh
  ${CYAN}uninstall${NC} <node> --route swarm-worker|swarm-server|isle-member|isle-core [--yes] [--dry-run]
              the reverse of install: leave the swarm / pol prod down / the isle's own full
              wipe (`isle uninstall --everything`, ISLE_CONFIRM_DELETE=yes only with --yes)
  ${CYAN}grant${NC} <node> --group remote|app [--user U]
              install a permission group on the machine (one password prompt, once):
                remote  ssh + swarm + AI-assisted setup — exactly the commands pol deploy sends
                app     the app-setup route — what the store's doors run for a person
  ${CYAN}audit${NC} <node> [--json]   the os-security audit on that machine (every ring, pass/fail, verdict), over ssh
  ${CYAN}inventory${NC} <node> [--post <core url>]   what Polari put on that machine and in what form, and its ssh surface (read-only; --post stores it as rows)
  ${CYAN}posture${NC} <node> status|dev|production [--for 8h] [--relax a,b] [--cidr <isle cidr>]   the node's posture (plan §16): dev = named isle-scoped relaxations, time-boxed, reverted by a timer and on reboot; refused on a production route
  ${CYAN}harden${NC} <node> [--scenario S] [--dry-run|--enforce] | --report [--rules] | --revert
                          the os-security rings on that machine, WARN-ONLY unless --enforce (renders here, ships, applies there, audits);
                          --report = what enforcing would break (kernel ALLOWED + seccomp-log lines); --revert = stock docker-default back
  ${CYAN}tier${NC} <node> [--check | reach|member|hardware] [--install]
              --check: what the machine qualifies for (docker, virt flags, /dev/kvm, libvirt, IOMMU);
              a tier: label the swarm node (polari.tier) + the topology machine row; hardware
              tier refuses without kvm + libvirt on the target

Targets: pol-build/manifests/nodes.yml
"
}

engines_env() {  # engines_env <node> -> "BOARD_ENGINES_URL=http://<ip>:9830 ESP_ENGINES_URL=..." from the node's `engines:` map
    # (sim-1, 2026-10-19: a STANDALONE node cannot reach a worker through the topology provider - that builds a URL only for
    # swarm placements - so the sanctioned fallback is the *_ENGINES_URL knob; the ip is resolved over ssh at deploy time and
    # never written into the registry, per the privacy rule)
    python3 - "$NODES_FILE" "$1" <<'EOF2'
import subprocess, sys, yaml
reg = yaml.safe_load(open(sys.argv[1])); n = reg["nodes"].get(sys.argv[2]) or {}
ips = {}
def ip_of(node):
    if node not in ips:
        alias = (reg["nodes"].get(node) or {}).get("ssh", "")
        cmd = ["ssh", alias, "hostname -I | awk '{print $1}'"] if alias else ["sh", "-c", "hostname -I | awk '{print $1}'"]
        ips[node] = subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip()
    return ips[node]
out = []
for fam, ref in (n.get("engines") or {}).items():
    ip = ip_of(ref["node"])
    if ip:
        out.append("%s_ENGINES_URL=http://%s:%s" % (fam.upper().replace("-", "_"), ip, ref["port"]))
print(" ".join(out))
EOF2
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
        CORE_IP="${LOCAL_IP:-$(lan_ip)}"

        case "$ROLE" in
            engines)
                UP_CMD="cd $DIR/polari-rf-node && docker compose -f docker-compose.msci-engines.yml up -d --build" ;;
            remote-worker)
                UP_CMD="cd $DIR/polari-rf-node && CORE_IP=$CORE_IP docker compose -f docker-compose.remote-worker.yml --profile dask up -d --build" ;;
            node)
                # The PRF dev certs FIRST (generate-prf-certs.sh dev: self-generating, no prompts): the
                # keycloak image build COPYs prf-keycloak/certs/prf-kc.{crt,key}, which staging-setup.sh
                # does not make — a fresh target without them fails the build (2026-10-11, econ-core).
                # (setup-polari-security.sh --skip-subs makes only the SUITE's pol-* certs, not these.)
                ENGINES_ENV=$(engines_env "$NODE")     # the node's engine workers by knob (nodes.yml `engines:`), ips resolved now
                UP_CMD="cd $DIR/polari-rf-node && bash generate-prf-certs.sh dev < /dev/null && LOCAL_IP=\$(hostname -I | awk '{print \$1}') ./staging-setup.sh && $ENGINES_ENV LOCAL_IP=\$(hostname -I | awk '{print \$1}') docker compose -f docker-compose.staging-nip.yml up -d --build" ;;
            *) die "unknown role '$ROLE' (engines|remote-worker|node)" ;;
        esac

        # The checkout step pulls the SUITE (ff-only) and then only the pieces this role needs, through
        # bootstrap-dev.sh (piece-wise; a piece that cannot be pulled warns and never blocks). It used
        # to be `git pull --recurse-submodules`, which recursed into every nested submodule of the
        # whole forest — a single unreachable one (2026-10-11: Isle-Mesh/isle-manager-app, an ssh
        # GitHub URL with no host key on econ-core) aborted the pull AND skipped the role's build.
        PIECES="polari-rf-node polari-cli"
        STEPS=(
            "if [ -d $DIR/.git ]; then git -C $DIR pull --ff-only; else git clone --branch dev $URL $DIR; fi"
            "cd $DIR && ./bootstrap-dev.sh $PIECES"
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
    selftest)
        # Run framework selftest suites on ANOTHER machine (his ask 2026-10-18: leverage the three devices; pol-core keeps the live stack and
        # had 4 GB free). A separate test checkout (<repo_dir>-test) so the node's own deploy checkout is never touched; the framework at --ref
        # (a branch an agent pushed, default dev); the Python deps in a PRIVATE folder via `pip install --target` (no system change, delete the
        # folder to undo); suites run on the host so the engines seam reaches that machine's local engine images exactly as on pol-core.
        NODE=${1:?node required (pol deploy nodes)}; shift || true
        REF="dev"; MODS="board.board_selftest,cmod.cmod_selftest,hwnocode.hwnocode_selftest,moduleService.selftest_manifests"; DRY=false
        while [ $# -gt 0 ]; do case "$1" in
            --ref) REF="$2"; shift 2 ;; --modules) MODS="$2"; shift 2 ;; --dry-run) DRY=true; shift ;; *) shift ;;
        esac; done
        SSH=$(node_field "$NODE" ssh); DIR=$(node_field "$NODE" repo_dir); URL=$(node_field "$NODE" repo_url)
        [ -n "$SSH" ] || die "$NODE is this machine — run the suites here, or pick another node (pol deploy nodes)"
        TDIR="${DIR}-test"; ENV_DIR='$HOME/.polari-test-env'; FW="$TDIR/polari-rf-node/polari-framework"
        # Each run gets its OWN framework worktree (2026-10-18: two agents' runs shared one checkout and one tested the other's branch)
        RUN="${TDIR}-runs/$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '_')-$$"
        STEPS=(
            "if [ -d $TDIR/.git ]; then git -C $TDIR fetch -q origin && git -C $TDIR checkout -q -B dev origin/dev; else git clone -q --branch dev $URL $TDIR; fi"
            "cd $TDIR && ./bootstrap-dev.sh polari-rf-node polari-cli >/dev/null"
            "git -C $FW fetch -q origin $REF && mkdir -p ${TDIR}-runs && git -C $FW worktree add -q -f --detach $RUN FETCH_HEAD && echo \"framework at $REF: \$(git -C $RUN log --oneline -1) (own worktree $RUN)\""
            "REQ=\$(sha256sum $FW/requirements.txt | cut -c1-16); if [ \"\$(cat $ENV_DIR/.req 2>/dev/null)\" != \"\$REQ\" ]; then echo 'installing the test deps into $ENV_DIR (pip --target; no system change)'; python3 -m pip install -q --target $ENV_DIR -r $FW/requirements.txt && echo \$REQ > $ENV_DIR/.req; fi"
            "cd $RUN && rc=0; for m in \$(echo $MODS | tr , ' '); do out=\$(PYTHONPATH=.:modules:$ENV_DIR timeout 3600 python3 -m \$m 2>&1); line=\$(printf '%s\\n' \"\$out\" | grep -E 'checks passed|passed\$' | tail -1); echo \"  \$m: \${line:-NO SUMMARY (crashed or timed out) — last lines:}\"; [ -n \"\$line\" ] || { printf '%s\\n' \"\$out\" | tail -5; rc=1; }; case \"\$line\" in *\"checks passed\"*) n=\${line%%/*}; d=\${line#*/}; d=\${d%% *}; [ \"\$n\" = \"\$d\" ] || rc=1 ;; esac; done; cd / && git -C $FW worktree remove -f $RUN; exit \$rc"
        )
        pol_box "selftest on $NODE: framework @ $REF — $MODS"
        RC=0
        for s in "${STEPS[@]}"; do
            if $DRY; then echo "  [dry-run] ssh $SSH '$s'"; else ssh "$SSH" "$s" || { RC=$?; [ "$s" = "${STEPS[-1]}" ] || die "step failed on $NODE: ${s:0:80}"; }; fi
        done
        $DRY || { [ $RC = 0 ] && log_success "all suites passed on $NODE (@ $REF)" || log_warn "some suites failed on $NODE (@ $REF) — see above (manifests' known pspp/testing failure counts as a failure here)"; }
        exit $RC ;;
    install)
        NODE=${1:?node required (pol deploy nodes)}; shift || true
        ROUTE=""; PROFILE="lean"; DOMAIN=""; DRY=false; HOST_FLAG=""; YES=false
        while [ $# -gt 0 ]; do case "$1" in
            --route) ROUTE="$2"; shift 2 ;; --profile) PROFILE="$2"; shift 2 ;; --domain) DOMAIN="$2"; shift 2 ;;
            --host) HOST_FLAG="--host"; shift ;; --yes) YES=true; shift ;; --dry-run) DRY=true; shift ;; *) shift ;;
        esac; done
        SSH=$(node_field "$NODE" ssh); DIR=$(node_field "$NODE" repo_dir); URL=$(node_field "$NODE" repo_url)
        [ -n "$SSH" ] || die "$NODE is this machine — run the route's own command here (pol prod guide / isle core-install)"
        ENSURE_DOCKER='command -v docker >/dev/null 2>&1 || { echo "installing docker"; curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker "$USER"; }'
        ENSURE_SUITE="if [ -d $DIR/.git ]; then git -C $DIR pull --recurse-submodules -q; else git clone --recurse-submodules $URL $DIR; fi; command -v pol >/dev/null 2>&1 || bash $DIR/polari-cli/shells/install-cli.sh"
        case "$ROUTE" in
            swarm-worker)
                STEPS=("$ENSURE_DOCKER")
                AFTER="bash '$SCRIPT_DIR/swarm.sh' join '$NODE'" ;;
            swarm-server)
                [ -n "$DOMAIN" ] || die "--domain <public domain> required for a server"
                AUTH=off; [ "$PROFILE" = full ] && AUTH=keycloak
                STEPS=("$ENSURE_DOCKER" "$ENSURE_SUITE"
                       "cd $DIR && POL_PROD_DOMAIN=$DOMAIN POL_PROD_AUTH=$AUTH POL_PROD_IMAGE_TAG=${POL_PROD_IMAGE_TAG:-prod} POL_PROD_IMAGE_REPO=${POL_PROD_IMAGE_REPO:-} pol prod apply --yes")
                AFTER="" ;;
            isle-member)
                # the JOIN INFO the isle core printed: fetch its bootstrap script over the isle, verify, run
                # the isle core's LAN address: ISLE_CORE_IP, else the ssh alias 'isle-core' resolved from ~/.ssh/config
                CORE_IP="${ISLE_CORE_IP:-$(ssh -G isle-core 2>/dev/null | awk '/^hostname /{print $2}')}"
                [ -n "$CORE_IP" ] && [ "$CORE_IP" != isle-core ] || die "the isle core's address is needed (ISLE_CORE_IP=…)"
                FP="${ISLE_CA_FINGERPRINT:-}"
                [ -n "$FP" ] || FP=$(ssh -o ConnectTimeout=8 isle-core "sudo -n openssl x509 -in /etc/isle-mesh/ca/isle-root.crt -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2" 2>/dev/null || true)
                [ -n "$FP" ] || die "the isle CA fingerprint is needed (ISLE_CA_FINGERPRINT=…) — it is printed by isle core-install / isle status on the core"
                # the JOIN INFO's own fetch: https://apt.isle/isle-bootstrap.sh resolved to the core (its CA is not trusted yet → -k; the sha check below is the guard)
                SHA="${ISLE_BOOTSTRAP_SHA256:-$(ssh -o ConnectTimeout=8 isle-core "sha256sum /usr/share/isle-mesh/isle-cli/scripts/isle-bootstrap.sh 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)}"
                STEPS=("$ENSURE_DOCKER"
                       "curl -fsSk -o /tmp/isle-bootstrap.sh --resolve apt.isle:443:$CORE_IP https://apt.isle/isle-bootstrap.sh && { [ -z '$SHA' ] || echo '$SHA  /tmp/isle-bootstrap.sh' | sha256sum -c - ; }"
                       "sudo bash /tmp/isle-bootstrap.sh --fingerprint '$FP' --core $CORE_IP $HOST_FLAG")
                AFTER="" ;;
            isle-core)
                DEB=$(ls "$POL_SUITE_ROOT"/.generated/debs/polari-complete_*.deb 2>/dev/null | sort -V | tail -1)
                [ -n "$DEB" ] || die "no polari-complete deb staged in .generated/debs — pol prod debs build"
                $DRY || scp -q "$DEB" "$SSH:/tmp/$(basename "$DEB")"
                # --yes = unattended (defers the security walkthrough: isle security setup later)
                CI="sudo isle core-install"; $YES && CI="sudo isle core-install --skip-security"
                STEPS=("sudo apt-get install -y /tmp/$(basename "$DEB")" "$CI")
                AFTER="" ;;
            *) die "--route swarm-worker|swarm-server|isle-member|isle-core" ;;
        esac
        pol_box "install: $NODE route=$ROUTE"
        for s in "${STEPS[@]}"; do
            if $DRY; then echo "  [dry-run] ssh -t $SSH '${s:0:140}'"; else log_info "ssh $SSH: ${s:0:90}…"; ssh -t -o ConnectTimeout=8 "$SSH" "$s" || die "step failed on $NODE"; fi
        done
        if [ -n "$AFTER" ]; then if $DRY; then echo "  [dry-run] $AFTER"; else eval "$AFTER"; fi; fi
        $DRY && log_info "dry-run complete — rerun without --dry-run to execute" || log_success "install ($ROUTE) done on $NODE" ;;
    status)
        NODE=${1:?node required}; SSH=$(node_field "$NODE" ssh)
        pol_box "status: $NODE"
        # the swarm's view (from this manager)
        NID=$(for id in $(docker node ls -q 2>/dev/null); do docker node inspect --format '{{.ID}} {{.Spec.Labels}}' "$id" | grep -q "polari.machine:$NODE" && echo "$id"; done | head -1)
        if [ -n "$NID" ]; then
            docker node inspect --format '  swarm        {{.Spec.Role}} {{.Status.State}} {{.Spec.Availability}} labels={{.Spec.Labels}}' "$NID"
            T=$(docker node ps "$NID" --filter desired-state=running --format '{{.Name}} {{.CurrentState}}' 2>/dev/null | sed 's/^/                 /'); echo "  tasks        $([ -n "$T" ] && echo || echo none)$T"
        else echo "  swarm        not a member of this swarm"; fi
        [ -n "$SSH" ] || { echo "  (this machine)"; exit 0; }
        ssh -o ConnectTimeout=8 "$SSH" 'set +e
echo "  host         $(hostname) up $(uptime -p 2>/dev/null | sed s/^up\ //) · $(free -h | awk "/^Mem/{print \$7}") free · docker $(docker --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+" | head -1)"
if command -v isle >/dev/null 2>&1; then
  echo "  isle cli     $(dpkg-query -W -f=\${Version} polari-complete 2>/dev/null || echo present)"
  S=$(isle status 2>/dev/null | sed "s/\x1b\[[0-9;]*m//g")
  echo "  router       $(echo "$S" | grep -m1 -E "Router is reachable|Router.*not" | sed "s/^ *//")"
  echo "  agent        $(docker ps --format "{{.Names}} {{.Status}}" 2>/dev/null | grep -E "^isle-(vlan|remote)-agent" || echo "not running")"
  echo "  polari.isle  HTTP $(curl -sk --max-time 6 -o /dev/null -w "%{http_code}" https://polari.isle/ 2>/dev/null) · $(docker ps --format "{{.Names}}" | grep -c "^prf-isle") prf-isle containers"
  echo "  doors        $(isle url exposures 2>/dev/null | sed "s/\x1b\[[0-9;]*m//g" | tail -1 | sed "s/^ *//")"
  command -v virsh >/dev/null 2>&1 && echo "  guests       $(virsh list --all 2>/dev/null | tail -n +3 | awk "NF{print \$2\"(\"\$3\")\"}" | tr "\n" " ")"
else
  echo "  isle cli     none (swarm-only machine)"
fi
echo "  containers   $(docker ps --format "{{.Names}}" 2>/dev/null | wc -l) running"' ;;
    uninstall)
        NODE=${1:?node required}; shift || true
        ROUTE=""; YES=false; DRY=false
        while [ $# -gt 0 ]; do case "$1" in --route) ROUTE="$2"; shift 2 ;; --yes) YES=true; shift ;; --dry-run) DRY=true; shift ;; *) shift ;; esac; done
        SSH=$(node_field "$NODE" ssh)
        case "$ROUTE" in
            swarm-worker)
                NID=$(for id in $(docker node ls -q 2>/dev/null); do docker node inspect --format '{{.ID}} {{.Spec.Labels}}' "$id" | grep -q "polari.machine:$NODE" && echo "$id"; done | head -1)
                [ -n "$NID" ] || die "$NODE is not in this swarm"
                STEPS=("docker swarm leave"); PRE="docker node update --availability drain $NID"; POST="sleep 5; docker node rm --force $NID" ;;
            swarm-server) DIR=$(node_field "$NODE" repo_dir); STEPS=("cd $DIR && pol prod down"); PRE=""; POST="" ;;
            isle-member|isle-core)
                $YES || die "the isle's full wipe is irreversible on that device (backup → destroy --purge → apt purge) — add --yes to confirm (dry-run shows the steps)"
                STEPS=("sudo ISLE_CONFIRM_DELETE=yes isle uninstall --everything --force"); PRE=""; POST="" ;;
            *) die "--route swarm-worker|swarm-server|isle-member|isle-core" ;;
        esac
        pol_box "uninstall: $NODE route=$ROUTE"
        if $DRY; then [ -n "$PRE" ] && echo "  [dry-run] $PRE"; for s in "${STEPS[@]}"; do echo "  [dry-run] ssh -t $SSH '$s'"; done; [ -n "$POST" ] && echo "  [dry-run] $POST"; log_info "dry-run complete"; exit 0; fi
        [ -n "$PRE" ] && eval "$PRE"
        for s in "${STEPS[@]}"; do log_info "ssh $SSH: $s"; ssh -t -o ConnectTimeout=8 "$SSH" "$s" || log_warn "step returned non-zero on $NODE: $s"; done
        [ -n "$POST" ] && eval "$POST"
        log_success "uninstall ($ROUTE) done on $NODE — pol deploy status $NODE" ;;
    grant)
        NODE=${1:?node required}; shift || true
        GROUP=""; GUSER=""
        while [ $# -gt 0 ]; do case "$1" in --group) GROUP="$2"; shift 2 ;; --user) GUSER="$2"; shift 2 ;; *) shift ;; esac; done
        [ "$GROUP" = remote ] || [ "$GROUP" = app ] || die "--group remote|app"
        SSH=$(node_field "$NODE" ssh); [ -n "$SSH" ] || die "$NODE is this machine — sudo bash polari-cli/shells/groups/install-groups.sh $GROUP \$USER"
        [ -n "$GUSER" ] || GUSER=$(ssh -o ConnectTimeout=8 "$SSH" 'id -un') || die "ssh to $SSH failed"
        pol_box "grant: $NODE group=polari-$GROUP user=$GUSER"
        scp -q "$SCRIPT_DIR/../shells/groups/install-groups.sh" "$SCRIPT_DIR/../shells/groups/polari-$GROUP.sudoers" "$SSH:/tmp/" || die "scp failed"
        if ssh -o ConnectTimeout=8 "$SSH" 'sudo -n true' 2>/dev/null; then
            ssh "$SSH" "sudo bash /tmp/install-groups.sh $GROUP $GUSER" && log_success "polari-$GROUP installed on $NODE"
        else
            log_warn "$NODE needs a password for sudo — this is the ONE interactive step; run it there (or in a terminal here with ssh -t):"
            echo "    ssh -t $SSH 'sudo bash /tmp/install-groups.sh $GROUP $GUSER'"
            echo "    (the files are already at /tmp on $NODE; afterwards pol deploy needs no password on it)"
            [ -t 0 ] && ssh -t "$SSH" "sudo bash /tmp/install-groups.sh $GROUP $GUSER" && log_success "polari-$GROUP installed on $NODE"
        fi ;;
    audit)
        NODE=${1:?node required}; shift || true
        SSH=$(node_field "$NODE" ssh); DIR=$(node_field "$NODE" repo_dir)
        if [ -z "$SSH" ]; then bash "$SCRIPT_DIR/../../os-security/audit.sh" "$@"; exit $?; fi
        pol_box "audit: $NODE"
        # the target may not have the checkout: ship audit.sh itself, it is self-contained
        scp -q "$SCRIPT_DIR/../../os-security/audit.sh" "$SSH:/tmp/os-security-audit.sh" || die "scp failed"
        ssh -o ConnectTimeout=8 "$SSH" "bash /tmp/os-security-audit.sh $*"; RC=$?
        [ $RC = 0 ] && log_success "$NODE: hardened" || log_warn "$NODE: not yet hardened (verdict above) — os-security/README.md"
        exit $RC ;;
    inventory)
        # what Polari put on that machine and in what form + its ssh capabilities (read-only; os-security/inventory.sh);
        # --post <core url> stores it as DeviceInventory + SshCapability rows (the isle topology shows the ssh surface)
        NODE=${1:?node required}; shift || true
        SSH=$(node_field "$NODE" ssh); POST=""; while [ $# -gt 0 ]; do case "$1" in --post) POST="$2"; shift 2 ;; *) shift ;; esac; done
        INV="$SCRIPT_DIR/../../os-security/inventory.sh"
        if [ -z "$SSH" ]; then OUT=$(bash "$INV" 2>/dev/null); else scp -q "$INV" "$SSH:/tmp/polari-inventory.sh" || die "scp failed"; OUT=$(ssh -o ConnectTimeout=8 "$SSH" "bash /tmp/polari-inventory.sh; rm -f /tmp/polari-inventory.sh" 2>/dev/null); fi
        echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || die "$NODE: inventory did not produce JSON"
        if [ -n "$POST" ]; then
            echo "$OUT" | python3 -c "
import json,sys,urllib.request
inv=json.load(sys.stdin); body=json.dumps({'device': sys.argv[2], 'inventory': inv}).encode()
req=urllib.request.Request(sys.argv[1].rstrip('/')+'/api/security/inventory', data=body, headers={'Content-Type':'application/json'}, method='POST')
try:
    r=json.load(urllib.request.urlopen(req, timeout=20)); print('%s: %s — formats: %s — ssh: %s (%s)' % (r.get('device'), r.get('role'), r.get('formats'), r['ssh']['verdict'], r['ssh']['vector']))
    a=r['ssh']; print('  assurance: %s — %s%s' % (a.get('assurance','?').upper(), a.get('reasons',''), (' — levels: ' + a['levels']) if a.get('levels') else ''))
except Exception as e: sys.exit('post failed: %s' % e)" "$POST" "$NODE"
        else
            echo "$OUT" | python3 -c "
import json,sys; d=json.load(sys.stdin); s=d['ssh']; dk=d['docker']
print('%s: %s · docker %s swarm %s · kvm %s' % (sys.argv[1], d['os'], dk['version'], dk['swarm'], d['kvm']))
print('  formats: debs %s · containers %s · stacks %s · checkouts %s · guests %s' % ([x.split('|')[0] for x in d['debs']], [c['name'] for c in dk['containers']], dk['stacks'], [c.split('|')[0] for c in d['checkouts']], d['guests']))
print('  rings: apparmor files %s · sudoers %s · /etc/isle-mesh %s · /etc/polari %s' % (d['apparmor_polari'], d['sudoers_polari'], d['etc_isle_mesh'], d['etc_polari']))
print('  ssh: listen %s · password %s · root %s · keys %d (%s) · reaches %s · fail2ban %s · failed 24h %s' % (s['listen'] or 'none', s['password_auth'] or '?', s['permit_root'] or '?', len(s['authorized_keys']), ','.join(sorted({k['type'] for k in s['authorized_keys']})), [h.split('|')[-1] for h in s['ssh_config_hosts']], s['fail2ban'], s['recent_failed_logins_24h']))" "$NODE"
        fi; exit 0 ;;
    posture)
        # plan §16 (his rulings 2026-09-14): a DEV posture is a list of named, isle-scoped relaxations, time-boxed;
        # production = every relaxation reverted. Runs os-security/posture.sh ON the node as root. Never on a production route.
        NODE=${1:?node required}; shift || true
        SSH=$(node_field "$NODE" ssh); PS="$SCRIPT_DIR/../../os-security/posture.sh"
        if [ -z "$SSH" ]; then
            if [ "${1:-status}" = status ]; then bash "$PS" status; else sudo bash "$PS" "$@"; fi
        else
            scp -q "$PS" "$SSH:/tmp/polari-posture.sh" || die "scp failed"
            if [ "${1:-status}" = status ]; then ssh -o ConnectTimeout=8 "$SSH" "bash /tmp/polari-posture.sh status; rm -f /tmp/polari-posture.sh"
            else ssh -t -o ConnectTimeout=8 "$SSH" "sudo bash /tmp/polari-posture.sh $*; rm -f /tmp/polari-posture.sh"; fi
        fi; exit $? ;;
    harden)
        # sec-1a across the home machines: render here, ship the rendered scenario + scripts to the node, apply there WARN-ONLY
        # (complain profiles, node-wide docker-default in complain, the other rings printed) unless --enforce; --dry-run prints;
        # --report = what enforcing would break (the kernel's ALLOWED/seccomp-log lines); --revert = docker's stock docker-default back.
        NODE=${1:?node required}; shift || true
        SSH=$(node_field "$NODE" ssh); SCN=""; MODEARGS=(); REPORT=false; REVERT=false; RARGS=()
        while [ $# -gt 0 ]; do case "$1" in --scenario) SCN="$2"; shift 2 ;; --report) REPORT=true; shift ;; --revert) REVERT=true; shift ;; --enforce|--dry-run|--complain) MODEARGS+=("$1"); shift ;; *) RARGS+=("$1"); shift ;; esac; done
        OSD="$SCRIPT_DIR/../../os-security"
        if [ -z "$SSH" ]; then bash "$SCRIPT_DIR/security.sh" os $($REPORT && echo allowed || { $REVERT && echo revert || echo apply; }) ${SCN:+--scenario "$SCN"} "${MODEARGS[@]}" "${RARGS[@]}"; exit $?; fi
        # scenario: the node's role — an isle agent running there → isle; else the swarm's profile (lean unless told)
        [ -n "$SCN" ] || SCN=$(ssh -o ConnectTimeout=8 "$SSH" "docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^isle-(vlan|remote)-agent$' && echo isle || echo swarm-lean")
        pol_box "harden: $NODE ($SCN, $($REPORT && echo report || { $REVERT && echo revert || { case " ${MODEARGS[*]} " in *" --enforce "*) echo ENFORCE ;; *) echo warn-only ;; esac; }; }))"
        REMOTE=/tmp/os-security-$SCN
        if $REPORT; then ssh -o ConnectTimeout=8 "$SSH" "sudo -n python3 $REMOTE/allowed.py ${RARGS[*]}"; exit $?; fi
        python3 "$OSD/render.py" --scenario "$SCN" --apps-from-manifests >/dev/null || die "render failed"
        ssh -o ConnectTimeout=8 "$SSH" "rm -rf $REMOTE && mkdir -p $REMOTE/out" || die "ssh failed"
        tar -C "$OSD" -cf - apply.sh audit.sh allowed.py escape-test.sh syscalls_x86_64.json "out/$SCN" | ssh "$SSH" "tar -C $REMOTE -xf -" || die "ship failed"
        if $REVERT; then ssh -t -o ConnectTimeout=8 "$SSH" "sudo -n bash $REMOTE/apply.sh --scenario $SCN --revert-docker-default"; exit $?; fi
        ssh -o ConnectTimeout=8 "$SSH" "sudo -n true 2>/dev/null" || { case " ${MODEARGS[*]} " in *" --dry-run "*) ;; *) die "$NODE: sudo needs a password there — run: ssh -t $SSH 'sudo bash $REMOTE/apply.sh --scenario $SCN ${MODEARGS[*]}' (or pol deploy grant $NODE)" ;; esac; }
        ssh -o ConnectTimeout=8 "$SSH" "sudo -n bash $REMOTE/apply.sh --scenario $SCN ${MODEARGS[*]} 2>&1 || bash $REMOTE/apply.sh --scenario $SCN --dry-run ${MODEARGS[*]}"; RC=$?
        case " ${MODEARGS[*]} " in *" --dry-run "*) ;; *) ssh -o ConnectTimeout=8 "$SSH" "sudo -n bash $REMOTE/audit.sh --scenario $SCN" || true
            log_info "$NODE: warn-only rings loaded; after a day: pol deploy harden $NODE --report --rules   (revert: pol deploy harden $NODE --revert)" ;; esac
        exit $RC ;;
    tier)
        NODE=${1:?node required}; shift || true
        WANT=""; CHECK=false; INSTALL=false
        while [ $# -gt 0 ]; do case "$1" in --check) CHECK=true; shift ;; --install) INSTALL=true; shift ;; reach|member|hardware|core) WANT="$1"; shift ;; *) shift ;; esac; done
        SSH=$(node_field "$NODE" ssh)
        PROBE='echo "docker=$(command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && echo yes || echo no) virt=$(grep -c -E "vmx|svm" /proc/cpuinfo) kvm=$([ -e /dev/kvm ] && echo yes || echo no) libvirt=$(command -v virsh >/dev/null 2>&1 && echo yes || echo no) iommu=$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l) agent=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -cE "^isle-(vlan|remote)-agent$") isle=$(command -v isle >/dev/null 2>&1 && echo yes || echo no)"'
        if [ -n "$SSH" ]; then FACTS=$(ssh -o ConnectTimeout=8 "$SSH" "$PROBE") || die "ssh to $SSH failed"; else FACTS=$(bash -c "$PROBE"); fi
        eval "$(echo "$FACTS" | tr ' ' '\n' | sed 's/^/F_/')"
        ELIG="reach"; [ "$F_docker" = yes ] && ELIG="member"; [ "$F_kvm" = yes ] && [ "$F_libvirt" = yes ] && ELIG="hardware"
        pol_box "tier: $NODE"
        echo "  docker $F_docker · cpu virt flags $F_virt · /dev/kvm $F_kvm · libvirt $F_libvirt · IOMMU groups $F_iommu · isle agent $F_agent · isle cli $F_isle"
        echo "  qualifies for: $ELIG$([ "$F_kvm" = yes ] && [ "$F_libvirt" = no ] && echo '  (hardware needs libvirt: sudo apt install -y qemu-kvm libvirt-daemon-system)')"
        $CHECK && exit 0
        [ -n "$WANT" ] || die "give a tier (reach|member|hardware|core) or --check"
        if [ "$WANT" = hardware ] && [ "$F_kvm" = yes ] && [ "$F_libvirt" = no ] && $INSTALL; then
            [ -n "$SSH" ] || die "install libvirt here yourself: sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils"
            log_info "installing libvirt on $NODE (the polari-remote group allows this without a password)"
            ssh -t -o ConnectTimeout=8 "$SSH" 'sudo apt-get install -y --no-install-recommends qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils && sudo usermod -aG libvirt "$USER" && sudo usermod -aG kvm "$USER" && sudo systemctl enable --now libvirtd' \
                && { F_libvirt=yes; ELIG=hardware; log_success "libvirt installed on $NODE"; } || die "libvirt install failed on $NODE (is polari-remote granted? pol deploy grant $NODE --group remote)"
        fi
        case "$WANT" in
            hardware) [ "$ELIG" = hardware ] || die "$NODE does not qualify for the hardware tier (needs /dev/kvm + libvirt on the target — add --install to put libvirt there)" ;;
            member)   [ "$F_docker" = yes ] || die "$NODE has no working docker — member tier needs it" ;;
        esac
        NODE_ID=$(docker node ls --format '{{.ID}} {{json .}}' 2>/dev/null | grep "polari.machine=$NODE\|" | awk '{print $1}' | while read -r id; do docker node inspect --format '{{.ID}} {{.Spec.Labels}}' "$id" | grep -q "polari.machine:$NODE" && echo "$id"; done | head -1)
        if [ -n "$NODE_ID" ]; then docker node update --label-add "polari.tier=$WANT" "$NODE_ID" >/dev/null && log_success "swarm node labelled polari.tier=$WANT"; else log_warn "$NODE is not in this swarm — no node label (pol swarm join $NODE)"; fi
        if printf '{"name": "%s", "tier": "%s"}' "$NODE" "$WANT" | core_api POST /api/topology/machine >/dev/null 2>&1; then log_success "topology machine row: $NODE tier=$WANT"; else log_warn "no core reachable — the machine row keeps its tier until pol topology push"; fi
        [ "$WANT" = hardware ] && [ "$F_agent" -gt 0 ] && log_info "isle member: hardware apps use 'isle vm' on this device (isle onboard --hardware is the isle-side verb requested in NOTES-FROM-POL-CORE.md)"
        log_success "$NODE → tier $WANT" ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown deploy command: $COMMAND"; show_help; exit 1 ;;
esac
