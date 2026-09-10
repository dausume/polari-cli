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
  ${CYAN}tier${NC} <node> [--check | reach|member|hardware] [--install]
              --check: what the machine qualifies for (docker, virt flags, /dev/kvm, libvirt, IOMMU);
              a tier: label the swarm node (polari.tier) + the topology machine row; hardware
              tier refuses without kvm + libvirt on the target

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
        CORE_IP="${LOCAL_IP:-$(lan_ip)}"

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
