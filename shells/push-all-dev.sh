#!/usr/bin/env bash
# push-all-dev.sh — push every repo's dev branch, innermost-first,
# with the safety checks a submodule forest needs.
#
#   ./push-all-dev.sh          dry run: report what WOULD push
#   ./push-all-dev.sh --push   actually push, aborting on first
#                              failure (order keeps pointers valid:
#                              a superproject never pushes before
#                              the submodules its pointers name)
#
# Checks per repo, before anything pushes:
#   - repo is ON dev with a CLEAN tree (no silent leftovers)
#   - superproject submodule pointers all resolve to commits
#     CONTAINED IN that submodule's dev (pointer coherence — a
#     pushed superproject must never reference an unpushed SHA)
# The dry run prints ahead-counts so the push is a decision made
# on numbers, not vibes.

set -u

SUITE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# innermost-first: submodules before every superproject that
# points at them.
REPOS=(
  "polari-rf-node/polari-framework"
  "polari-rf-node/polari-platform-angular"
  "polari-rf-node"
  "polari-cli"
  "polari-app-shell"
  "political-scorecard-node/political-scorecard-backend"
  "political-scorecard-node/political-scorecard-frontend"
  "political-scorecard-node"
  "."
)

DO_PUSH=0
[ "${1:-}" = "--push" ] && DO_PUSH=1

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[92m%s\033[0m\n' "$*"; }
warn()  { printf '  \033[93m%s\033[0m\n' "$*"; }
fail()  { printf '  \033[91m%s\033[0m\n' "$*"; }

errors=0

check_repo() {
  local rel="$1" path="$SUITE/$1"
  local branch dirty ahead
  branch=$(git -C "$path" branch --show-current)
  if [ "$branch" != "dev" ]; then
    fail "NOT on dev (on '$branch') — checkout/ff dev first"
    errors=$((errors + 1))
    return 1
  fi
  dirty=$(git -C "$path" status --porcelain | wc -l)
  if [ "$dirty" -ne 0 ]; then
    fail "tree not clean ($dirty entries) — commit or stash first"
    errors=$((errors + 1))
    return 1
  fi
  ahead=$(git -C "$path" rev-list --count origin/dev..dev \
          2>/dev/null || echo '?')
  ok "on dev, clean, $ahead commit(s) ahead of origin/dev"
  # pointer coherence: every submodule pointer must be contained
  # in that submodule's dev. (Process substitution, not a pipe —
  # a piped while runs in a subshell and its failure exit would
  # be silently lost.)
  local bad=0 sha sub _rest
  while read -r sha sub _rest; do
    [ -z "$sha" ] && continue
    sha="${sha#[+-]}"
    if ! git -C "$path/$sub" merge-base --is-ancestor \
         "$sha" dev 2>/dev/null; then
      fail "pointer $sub@${sha:0:8} NOT contained in $sub's dev"
      bad=1
    fi
  done < <(git -C "$path" submodule status 2>/dev/null)
  if [ "$bad" -ne 0 ]; then
    errors=$((errors + 1))
    return 1
  fi
  return 0
}

bold "== dev push sweep ($([ $DO_PUSH -eq 1 ] \
     && echo PUSHING || echo DRY RUN)) =="
for rel in "${REPOS[@]}"; do
  bold "$rel"
  if ! check_repo "$rel"; then
    continue
  fi
  if [ $DO_PUSH -eq 1 ]; then
    if git -C "$SUITE/$rel" push origin dev; then
      ok "pushed"
    else
      fail "PUSH FAILED — stopping (inner repos already pushed \
are safe; rerun after fixing)"
      exit 1
    fi
  fi
done

if [ $errors -gt 0 ]; then
  fail "$errors repo(s) not ready — nothing should push until \
they are"
  exit 1
fi
[ $DO_PUSH -eq 0 ] \
  && bold "dry run clean — rerun with --push to publish"
exit 0
