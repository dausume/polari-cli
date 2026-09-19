#!/bin/bash
# scan.sh — `pol scan`: the ADVISORY scanning layer
# (SCANNING_AND_RELEASE_AUTOMATION_PLAN.md §2.2, built as scn-0 alongside ci-12's
# test pipeline).
#
# A THIN VERB, on purpose. Every line of behaviour lives in
# polari-jenkins/scan/scan.sh, which is what the pipeline runs and what the
# selftest exercises. This file resolves the checkout, points the scanner at it,
# and gets out of the way — so a person running `pol scan deps` by hand and the
# `polari-test` job running the same verb are running the same code, with the
# same pinned tools, and cannot disagree about what a scan IS.
#
# THE RULE: every scan exits 0. A finding is never a gate — not here, not in the
# test verdict, not in the release rule. Scans are recorded so a person can read
# them, and that is the whole of their authority (his standing rule 2026-09-19).
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCANNER="$ROOT/polari-jenkins/scan/scan.sh"

usage() {
printf '%b\n' "$(cat <<EOF
${BOLD}pol scan${NC} — the advisory scanners (scn-0). ${YELLOW}Nothing here gates anything.${NC}

  ${CYAN}targets${NC}
    source                 gitleaks (secrets in the tree) + trivy fs (misconfiguration, secrets, licences)
    deps                   trivy fs over the lockfiles + pip-audit + npm audit
    images [<ref>…]        trivy image, per built image (default: the three :staging tags)
    debs [<dir>]           trivy over each unpacked .deb (default: .generated/debs)
    all                    all four, then the summary

  ${CYAN}reading it${NC}
    summary                (re)write SCAN_SUMMARY.md from the reports already there
    --out <dir>            where reports go (default: <pool>/scan)

  ${CYAN}the tools${NC}
    lock                   the pinned scanners: image, digest, licence, what each scans
    lock-resolve           pull each image and write its digest back into scan-tools.lock
                           (then commit the change deliberately — the casc/plugins.txt discipline)

  Reports land as <out>/<tool>.json, one <out>/SKIPPED.txt line per tool that could
  not run, and <out>/SCAN_SUMMARY.md — counts by severity, per tool, with the totals.
  In the pipeline they are written into pool/test/<sha>/scan/ and carried in that
  sha's verdict, where they change nothing.
EOF
)"
}

case "${1:-help}" in
    help|--help|-h) usage ;;
    *) exec bash "$SCANNER" "$@" ;;
esac
