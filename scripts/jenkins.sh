#!/bin/bash
# jenkins.sh — `pol jenkins`: the host-tier build + publish controller
# (polari-jenkins/ sub-project; CICD_PIPELINE_PLAN.md). Loopback-only UI,
# polls GitHub, publishes only where a secret is present AND the route is
# allowed. ci-7 adds THE PIPELINE DEVICE: where the throwaway isle goes,
# whether the device is fit to run it, and where the secrets live.
#
#   pol jenkins help
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"; J="$ROOT/polari-jenkins"
source "$SCRIPT_DIR/lib/jenkins-device.sh"
cd "$J"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol jenkins${NC} — the host-tier build + publish pipeline (polari-jenkins/)

  ${CYAN}the controller${NC}
    up | down | restart | build       compose the controller (UI on 127.0.0.1 only)
    status                            compose ps + UI health + secrets + doctor
    logs                              follow (the log prints secret NAMES, never values)

  ${CYAN}the pipeline device${NC} — where the throwaway isle goes (ci-7)
    guide                             a short walkthrough that writes device.env
    config                            print the device configuration in force
    target local                      the throwaway isle VM is created on THIS machine
    target ssh <alias>                …on another device, over ssh (an ALIAS, never an address)
    preflight [--isle] [--json]       (A) is the device CLEAR and does it have room? exit 4 = refused
    isle up|verify|down|status        the throwaway VM itself

  ${CYAN}configuration + secrets${NC}
    doctor [--strict]                 (B) what is set up, what is not, and what to do about it
    init-device                       (C) create the polari-ci user + /etc/polari-jenkins/secrets (needs sudo)
    secrets [status]                  which secrets exist (names only) and which routes are ARMED
    secrets put <area>/<name>         store one, value from stdin
    secrets rm  <area>/<name>         remove one
EOF
)"
}

ensure_env(){
    [ -f .env ] || { sed "s#^POLARI_SUITE=.*#POLARI_SUITE=$ROOT#; s#^UID=.*#UID=$(id -u)#; s#^GID=.*#GID=$(id -g)#; s#^DOCKER_GID=.*#DOCKER_GID=$(getent group docker | cut -d: -f3)#" .env.example > .env; log_info "wrote polari-jenkins/.env (gitignored)"; }
    mkdir -p jenkins_home pool
    jd_source
    if ! secrets_have admin/jenkins_admin_password; then
        PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
        printf '%s' "$PW" | jd_secrets_put admin/jenkins_admin_password >/dev/null
        log_warn "generated the local admin password (stored in $(secrets_dir)/admin/jenkins_admin_password). Shown once: $PW"
    fi
    [ "$(secrets_mode)" = repo ] && chmod -R go-rwx secrets 2>/dev/null || true
    jd_export_for_compose     # CI_ROUTES / CI_EXECUTORS / the isle target reach casc + the jobs
}
compose(){ docker compose -p polari-jenkins "$@"; }

case "${1:-help}" in
    up)      ensure_env; compose up -d --build
             log_success "polari-jenkins up → http://127.0.0.1:$(grep ^JENKINS_PORT .env | cut -d= -f2)  (admin / $(secrets_dir)/admin/jenkins_admin_password)"
             echo; bash "$J/doctor.sh" || true ;;
    down)    compose down ;;
    restart) ensure_env; compose restart ;;
    build)   ensure_env; compose build ;;
    logs)    compose logs -f --tail=200 ;;
    status)  compose ps
             C=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${JENKINS_PORT:-8080}/login" || true); echo "UI: HTTP $C"
             echo; jd_secrets_status; echo; bash "$J/doctor.sh" || true ;;

    # ---- the pipeline device (ci-7)
    guide)   jd_guide ;;
    config)  jd_config ;;
    target)  shift; jd_target "${1:-}" "${2:-}" ;;
    preflight) shift; jd_export_for_compose; bash "$J/isle/preflight.sh" "$@" ;;
    isle)    shift; jd_export_for_compose; bash "$J/isle/throwaway.sh" "${1:-status}" ;;

    # ---- configuration + secrets
    doctor)  shift; bash "$J/doctor.sh" "$@" ;;
    init-device)
             shift
             if [ "$(id -u)" = 0 ]; then exec bash "$J/init-device.sh" "$@"; fi
             log_info "init-device creates a system user and a root-owned secrets directory — re-running through sudo"
             exec sudo bash "$J/init-device.sh" "$@" ;;
    secrets) shift
             case "${1:-status}" in
                 status|'') jd_secrets_status ;;
                 put)       shift; jd_secrets_put "${1:-}" ;;
                 rm)        shift; jd_secrets_rm "${1:-}" ;;
                 *)         die "pol jenkins secrets [status|put <area>/<name>|rm <area>/<name>]" ;;
             esac ;;

    help|--help|-h) usage ;;
    *)       log_error "unknown: pol jenkins $1"; echo; usage; exit 2 ;;
esac
