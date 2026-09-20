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
# the shared whiptail/plain dialog helpers (lifted out of prod.sh in ci-7b)
source "$SCRIPT_DIR/lib/tui.sh"
export POL_TUI_LIB="$SCRIPT_DIR/lib/tui.sh"
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

  ${CYAN}START HERE${NC}
    setup                             the one-shot walkthrough: it explains each option, checks the
                                      state live, says WHAT/HOW/WHERE, and DOES the local part for you
    setup --report                    read-only: the state and the "still to do, in order" list
    setup --yes                       answer every safe local question yes (never invents a token)
    setup --json [--step <name>]      the MACHINE protocol (polari-pipeline-setup/1) — one JSON document
         [--answer KEY=VALUE] [--run <id>]   on stdout, logs on stderr. It never prompts and never runs
                                      anything privileged; a privileged action is described, naming a verb.
    verbs                             the ALLOWLIST any front end runs through (shell-verbs.json)
    setup --step <name>               re-run one step: role checkout network secrets isle stages controller

  ${CYAN}THE BRANCH MODEL${NC} — dev iterate · test decide · main release (ci-12)
    promote test [--dry-run]          fast-forward EVERY repo in the forest from dev to test and push,
                                      innermost-first, ff-only. It refuses — naming the repo — if any
                                      repo is not fast-forwardable, and stops there so nothing outside
                                      it has moved. Pushing to test kicks off polari-test: wipe, build,
                                      scan, test, ONE verdict.
    promote main [--dry-run]          the same, test → main — but it REFUSES unless the superproject sha
         [--force-untested]           on test has a PASSED test verdict. --force-untested overrides it
                                      with a line naming the sha and the verdict it is overriding.
    promote status                    where dev, test and main are, and each one's verdict
    test-status [<sha>]               the verdict for a sha (default: the tip of test) — what was built,
                                      what the selftests said, what the isle stages said, and the
                                      advisory scan counts that changed none of it
    report [<sha>]                    THE ONE PAGE for a sha (ci-3): the verdict and why, the debs with
                                      their sha256 and the image ids that were installed, the scan
                                      counts, the device selftests, and per isle stage the install
                                      time-to-online, the verify details, the suites that ran INSIDE
                                      the product, the uninstall verdict with the product's own
                                      findings, and the leak diff. It is a release asset too.
    queue [--json]                    both poll queues: pending / newest sha / since / running.
                                      ONE item deep, latest wins — a newer change REPLACES the pending
                                      one, nothing ever queues behind it, and the run always takes the
                                      branch TIP rather than the sha that triggered it.
                                      \`covered <sha> (refused: …)\` on main means the release rule has
                                      ANSWERED for that sha (pool/release/<sha>/refused.json) and no
                                      tick will re-run it until main moves or that sha's verdict changes.
    scan …                            the advisory scanners — see \`pol scan help\`

  ${CYAN}the pipeline device${NC} — where the throwaway isle goes (ci-7)
    config                            print the device configuration + the testing stages in force
    target local                      the throwaway isle VM is created on THIS machine
    target ssh <alias>                …on another device, over ssh (an ALIAS, never an address)
    preflight [--isle] [--json]       (A) is the device CLEAR and does it have room? exit 4 = refused
    isle up|verify|down|status        the throwaway VM itself
    isle authorize [<alias>]          put THE PIPELINE USER'S OWN key (init-device made it) on the isle
                                      device, over the alias you already reach it by. The controller runs
                                      as polari-ci and cannot read your ~/.ssh — without this every isle
                                      stage refuses at the preflight. Idempotent; it verifies the target's
                                      host key against your own known_hosts and refuses on a mismatch.
    stages                            CI_ISLE_STAGES — what each throwaway isle tests, and so what may
                                      ever be released (pol jenkins setup --step stages to change it)

  ${CYAN}wiping between stages, and proving it${NC} — deploy a new isle each time (ci-10)
    isle uninstall [--stage N] [--json <f>]
                                      run the PRODUCT'S OWN \`isle uninstall --everything\` inside the
                                      guest as a TEST, then its verify + the hand-back proof.
                                      clean|dirty|failed|skipped — a dirty hand-back blocks the release.
    isle wipe [--dry-run]             remove everything this pipeline made on the target and NOTHING
                                      else (the \`polari-ci-\` tag). It prints both lists: what it
                                      removed, and what it found and left alone.
    isle leakcheck baseline           the reading every stage is diffed against (before stage 1)
    isle leakcheck check [--stage N]  after a \`down\`: anything NEW that survived the wipe is a LEAK,
                                      and so is RAM or disk that did not come back. exit 5 = leaked.
    isle leakcheck report [--stage N] the table: kind | item | baseline | now | verdict
    isle leakcheck snapshot           the raw reading of the target, to stdout, writing nothing

  ${CYAN}the offline cache${NC} — build once, reuse (ci-9)
    cache status                      what is cached, per area, against CI_CACHE_MAX_GB, and the hit
                                      rate of the last run (pool/<version>/cache-report.json)
    cache prune [--older-than N]      the ONE deleter: entries nothing has used for > N days
                                      (default 30). retention.sh prune never touches the cache.
    cache proxies up|down|status      TIER TWO, opt-in (CI_CACHE_PROXIES=on): a docker pull-through
                                      registry + devpi + verdaccio + apt-cacher-ng on 127.0.0.1.
                                      A pipeline never starts them; it uses them only if they answer.
    core-artifacts resolve|fetch      app mode: which official release the core comes from, and pull
                                      its debs once into the cache (CI_CORE_SOURCE=release:<tag>)

  ${CYAN}the settings, in Polari${NC} — the cicd app owns them; device.env follows (ci-8)
    sync pull                         rewrite device.env from the core (\$CI_CORE_URL/api/cicd). Never
                                      fatal: no answer = keep this device.env and say so
    sync push                         report readiness, the routes armed and secret PRESENCE back
    sync status                       what it would do, and whether the core answers

  ${CYAN}configuration + secrets${NC}
    doctor [--strict]                 (B) what is set up, what is not, and what to do about it
    init-device                       (C) create the polari-ci user + /etc/polari-jenkins/secrets (needs sudo)
    secrets [status]                  the catalogue: each secret's NAME, WHERE the thing it unlocks
                                      goes (which release pool, which registry), the routes that use
                                      it, and present/absent. Never a value.
    secrets put <area>/<name>         store one, value from stdin
    secrets rm  <area>/<name>         remove one
    secrets mv  <old> <new>           rename one in place, keeping its mode and owner (ci-12 renamed
                                      github/github_token → github/release_token and
                                      registries/ghcr_token → github/registry_token; the old names
                                      still work and the doctor says so)
EOF
)"
}

ensure_env(){
    [ -f .env ] || { sed "s#^POLARI_SUITE=.*#POLARI_SUITE=$ROOT#; s#^UID=.*#UID=$(id -u)#; s#^GID=.*#GID=$(id -g)#; s#^DOCKER_GID=.*#DOCKER_GID=$(getent group docker | cut -d: -f3)#" .env.example > .env; log_info "wrote polari-jenkins/.env (gitignored)"; }
    mkdir -p jenkins_home pool
    jd_source
    # ci-12: in the SYSTEM posture the secrets directory is root:polari-ci 0750,
    # so a person without passwordless sudo cannot even SEE whether the admin
    # password is there. `secrets_have` then says no, and the old code went on to
    # generate a new one — which fails on the write and stops `up` dead, on a
    # device that had a perfectly good password all along. Say what is true
    # instead: only root and the controller can read it, and that is the posture
    # working.
    if ! secrets_have admin/jenkins_admin_password; then
        if [ "$(secrets_mode)" = system ] && ! sudo -n true 2>/dev/null; then
            log_info "the admin password is in $(secrets_dir)/admin/jenkins_admin_password — root:$CI_USER 0640, so only sudo and the controller can read it. Not regenerating."
        else
            PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
            printf '%s' "$PW" | jd_secrets_put admin/jenkins_admin_password >/dev/null
            log_warn "generated the local admin password (stored in $(secrets_dir)/admin/jenkins_admin_password). Shown once: $PW"
        fi
    fi
    [ "$(secrets_mode)" = repo ] && chmod -R go-rwx secrets 2>/dev/null || true
    # ci-12: what the HOST calls the two paths the controller knows as
    # /var/polari-pool and /var/jenkins_home. A `docker -v` issued from inside
    # the controller is resolved by the daemon, on the host, so anything that
    # mounts one of those paths needs the host's name for it.
    export CI_HOST_POOL="$J/pool"
    export CI_HOST_JENKINS_HOME="${JENKINS_HOME:-$J/jenkins_home}"
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
             jd_setup_line
             echo; jd_secrets_status; echo; bash "$J/doctor.sh" || true ;;

    # ---- ci-12: the branch model. promote.sh owns the gate and the marker;
    # polari-cli/shells/push-all-dev.sh owns the forest sweep (ONE sweep, given a
    # --branch / --promote-from parameter rather than copied).
    promote) shift; jd_export_for_compose; exec bash "$J/promote.sh" "${1:-status}" "${@:2}" ;;
    test-status) shift; jd_export_for_compose; jd_test_status "${1:-}" ;;
    report)      shift; jd_export_for_compose; jd_report "${1:-}" ;;
    queue)   shift; jd_export_for_compose; jd_in_controller quiet.sh queue "${1:-}" ;;
    scan)    shift; jd_export_for_compose; exec bash "$J/scan/scan.sh" "$@" ;;

    # ---- the pipeline device (ci-7)
    setup|guide) shift; jd_setup "$@" ;;     # `guide` is the old name, kept as an alias
    # ci-11a: THE ALLOWLIST, printed. Every command any front end may run on this
    # device's behalf, by id, with its argv fixed and its parameters' regexes. The
    # file is the contract; this verb is just a reader of it.
    verbs)   cat "$J/shell-verbs.json" ;;
    config)  jd_config ;;
    stages)  jd_source; stages_print; echo "CI_ISLE_STAGES=$CI_ISLE_STAGES   (change it: pol jenkins setup --step stages)" ;;
    target)  shift; jd_target "${1:-}" "${2:-}" ;;
    sync)    shift; jd_sync "${1:-status}" ;;   # ci-8: Polari holds these settings; device.env follows
    # ---- ci-9: the offline-first cache, and app mode's pulled core
    cache)   shift; jd_cache "$@" ;;
    core-artifacts) shift; jd_export_for_compose; bash "$J/isle/core-artifacts.sh" "${1:-status}" "${2:-}" ;;
    preflight) shift; jd_export_for_compose; bash "$J/isle/preflight.sh" "$@" ;;
    isle)    shift; jd_export_for_compose
             # ci-10: leakcheck is its own script (it reads the target and never
             # changes it); everything else is the throwaway VM's own verbs.
             if [ "${1:-}" = leakcheck ]; then shift; exec bash "$J/isle/leakcheck.sh" "${1:-report}" "${@:2}"; fi
             # ci-12 (§76 addendum 3): `authorize` is the ONE verb here that is
             # deliberately run by the INTERACTIVE user and not through the
             # controller — it copies the PIPELINE user's public key to the
             # target over the alias this person already reaches it by.
             if [ "${1:-}" = authorize ]; then shift; exec bash "$J/isle/authorize.sh" "$@"; fi
             bash "$J/isle/throwaway.sh" "${1:-status}" "${@:2}" ;;

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
                 mv)        shift; jd_secrets_mv "${1:-}" "${2:-}" ;;
                 *)         die "pol jenkins secrets [status|put <area>/<name>|rm <area>/<name>|mv <old> <new>]" ;;
             esac ;;

    help|--help|-h) usage ;;
    *)       log_error "unknown: pol jenkins $1"; echo; usage; exit 2 ;;
esac
