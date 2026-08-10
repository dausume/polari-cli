#!/usr/bin/env bash
# push-all-dev.sh — push every repo's dev branch, innermost-first,
# with the safety checks a submodule forest needs.
#
#   ./push-all-dev.sh              dry run: report what WOULD push
#   ./push-all-dev.sh --push      actually push, aborting on first
#                                 failure (order keeps pointers valid:
#                                 a superproject never pushes before
#                                 the submodules its pointers name)
#   ./push-all-dev.sh --with-isle  ALSO push the Isle-Mesh repo on
#                                 isle-core over SSH (dev). Combine
#                                 with --push to actually push it;
#                                 alone it dry-runs the isle side too.
#
# Env: ISLE_HOST (default isle-core), ISLE_REPO (default ~/Isle-Mesh).
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
WITH_ISLE=0
for arg in "$@"; do
  case "$arg" in
    --push) DO_PUSH=1 ;;
    --with-isle) WITH_ISLE=1 ;;
  esac
done
ISLE_HOST="${ISLE_HOST:-isle-core}"
ISLE_REPO="${ISLE_REPO:-Isle-Mesh}"   # relative to the SSH login home

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[92m%s\033[0m\n' "$*"; }
warn()  { printf '  \033[93m%s\033[0m\n' "$*"; }
fail()  { printf '  \033[91m%s\033[0m\n' "$*"; }

errors=0

# ---- artifact guard ----------------------------------------------
# No build artifacts in git. They are large, they change on every
# rebuild, and git keeps every version forever — one 28MB router image
# cost ~170MB of history before anyone noticed. Worse, a built VM image
# or deb can carry secrets (host keys, shadow, TLS keys). Catch them
# here, BEFORE they reach a public origin, where removing them means
# rewriting shared history.
#
# Each artifact type is supposed to have a fetch-or-build path instead
# (see Isle-Mesh's get-router-image.sh for the pattern).
ARTIFACT_MAX_BYTES="${ARTIFACT_MAX_BYTES:-1048576}"   # 1 MB
ARTIFACT_RE='\.(qcow2|img|img\.gz|iso|ipk|deb|apk|rpm|jar|war|tar|tar\.gz|tgz|zip|so|dylib|bin)$'
# gradle-wrapper.jar is the sanctioned exception: it must be committed
# for the wrapper to bootstrap at all.
ARTIFACT_ALLOW_RE='gradle/wrapper/gradle-wrapper\.jar$'

# Prints offending "size path" lines; empty output = clean.
find_artifacts() {
  git -C "$1" ls-tree -r -l HEAD 2>/dev/null \
    | awk -v max="$ARTIFACT_MAX_BYTES" '$4 ~ /^[0-9]+$/ && $4 > max {print $4, $5}' \
    | grep -E "$ARTIFACT_RE" \
    | grep -vE "$ARTIFACT_ALLOW_RE" || true
}

check_artifacts() {
  local path="$1" found
  found=$(find_artifacts "$path")
  [ -z "$found" ] && return 0
  fail "build artifacts tracked in git (>$((ARTIFACT_MAX_BYTES / 1024))KB) — refusing to push:"
  printf '%s\n' "$found" | while read -r size file; do
    fail "    $((size / 1024))KB  $file"
  done
  fail "    untrack them (git rm --cached) + .gitignore, and give each"
  fail "    a fetch-or-build path. Override for this run: ARTIFACT_MAX_BYTES=huge"
  return 1
}

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
  if ! check_artifacts "$path"; then
    errors=$((errors + 1))
    return 1
  fi
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

# ---- optional: the Isle-Mesh repo on isle-core, over SSH ----
if [ $WITH_ISLE -eq 1 ]; then
  bold "Isle-Mesh @ $ISLE_HOST:~/$ISLE_REPO (dev)"
  isle_state=$(ssh "$ISLE_HOST" "cd \"$ISLE_REPO\" 2>/dev/null && \
    printf '%s|%s|%s' \
      \"\$(git branch --show-current)\" \
      \"\$(git status --porcelain | wc -l | tr -d ' ')\" \
      \"\$(git rev-list --count origin/dev..dev 2>/dev/null || echo new)\"" \
    2>/dev/null)
  ibranch="${isle_state%%|*}"; irest="${isle_state#*|}"
  idirty="${irest%%|*}"; iahead="${irest#*|}"
  if [ -z "$isle_state" ]; then
    fail "could not reach $ISLE_HOST or ~/$ISLE_REPO"
    exit 1
  elif [ "$ibranch" != "dev" ]; then
    fail "isle-core NOT on dev (on '$ibranch') — fix there first"
    exit 1
  elif [ "$idirty" != "0" ]; then
    fail "isle-core tree not clean ($idirty entries) — commit there first"
    exit 1
  fi
  ok "on dev, clean, $iahead ahead of origin/dev (new = branch not yet on origin)"
  # same artifact guard, run on the isle side
  isle_artifacts=$(ssh "$ISLE_HOST" "cd \"$ISLE_REPO\" && \
    git ls-tree -r -l HEAD 2>/dev/null \
    | awk -v max=$ARTIFACT_MAX_BYTES '\$4 ~ /^[0-9]+\$/ && \$4 > max {print \$4, \$5}' \
    | grep -E '$ARTIFACT_RE' | grep -vE '$ARTIFACT_ALLOW_RE'" 2>/dev/null || true)
  if [ -n "$isle_artifacts" ]; then
    fail "build artifacts tracked in Isle-Mesh — refusing to push:"
    printf '%s\n' "$isle_artifacts" | while read -r size file; do
      fail "    $((size / 1024))KB  $file"
    done
    exit 1
  fi
  ok "no tracked build artifacts"
  if [ $DO_PUSH -eq 1 ]; then
    if ssh "$ISLE_HOST" "cd \"$ISLE_REPO\" && git push -u origin dev"; then
      ok "pushed (isle-core)"
    else
      fail "isle-core push FAILED"
      exit 1
    fi
  fi
fi

[ $DO_PUSH -eq 0 ] \
  && bold "dry run clean — rerun with --push to publish"
exit 0
