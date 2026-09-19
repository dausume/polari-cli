#!/usr/bin/env bash
# push-all-dev.sh — push every repo's branch, innermost-first,
# with the safety checks a submodule forest needs.
#
#   ./push-all-dev.sh              dry run: report what WOULD push
#   ./push-all-dev.sh --push      actually push, aborting on first
#   --skip-modules                 skip the polari-module-* subtree re-publish
#                                 (after polari-framework pushes, stale module
#                                 subtrees are split + pushed to their repos)
#                                 failure (order keeps pointers valid:
#                                 a superproject never pushes before
#                                 the submodules its pointers name)
#   ./push-all-dev.sh --with-isle  ALSO push the Isle-Mesh repo on
#                                 isle-core over SSH (dev). Combine
#                                 with --push to actually push it;
#                                 alone it dry-runs the isle side too.
#
# ci-12 — THE BRANCH MODEL (his ruling 2026-09-19: dev → test → main).
# ONE sweep, parameterised; there is no second copy of this walk.
#
#   --branch <b>                   the branch being published (default dev)
#   --promote-from <src>           PROMOTION: fast-forward <branch> to
#                                  origin/<src> in every repo, innermost-first,
#                                  and push it. FF-ONLY: a repo whose <branch>
#                                  is not a fast-forward of origin/<src> stops
#                                  the sweep and is NAMED. The working tree is
#                                  never switched — `git fetch . <src>:<branch>`
#                                  moves the ref, so a promotion can run while
#                                  the checkout sits on dev.
#   --summary-json <path>          write {branch, from, repos:{repo: sha}} —
#                                  the promotion marker polari-jenkins reads
#
# A promotion reads origin/<src>, not the local <src>: promoting what is
# PUBLISHED is the only thing a poller on another machine can ever see.
#
# Env: ISLE_HOST (default isle-core), ISLE_REPO (default ~/Isle-Mesh).
#
# Checks per repo, before anything pushes:
#   - CLEAN tree (no silent leftovers); on <branch> when not promoting
#   - superproject submodule pointers all resolve to commits
#     CONTAINED IN that submodule's branch (pointer coherence — a
#     pushed superproject must never reference an unpushed SHA)
# The dry run prints ahead-counts so the push is a decision made
# on numbers, not vibes.

set -u

SUITE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# innermost-first: submodules before every superproject that
# points at them. Isle-Mesh is a first-class suite submodule with its
# own GitHub origin — since the 2026-08-17 purge, the suite checkout IS
# its working copy (--with-isle remains for a box that still keeps a
# separate ~/Isle-Mesh clone).
REPOS=(
  "Isle-Mesh"
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
SKIP_MODULES=0
BRANCH=dev          # ci-12: the branch being published
PROMOTE_FROM=""     # ci-12: ff <BRANCH> to origin/<PROMOTE_FROM> first
SUMMARY_JSON=""     # ci-12: the promotion marker polari-jenkins reads
while [ $# -gt 0 ]; do
  case "$1" in
    --push) DO_PUSH=1 ;;
    --with-isle) WITH_ISLE=1 ;;
    --skip-modules) SKIP_MODULES=1 ;;
    --branch) BRANCH="${2:-dev}"; shift ;;
    --promote-from) PROMOTE_FROM="${2:-}"; shift ;;
    --summary-json) SUMMARY_JSON="${2:-}"; shift ;;
    --help|-h) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
  esac
  shift
done
[ -n "$PROMOTE_FROM" ] && SKIP_MODULES=1   # a promotion republishes no module subtree: the
                                           # polari-module-* repos follow polari-framework's
                                           # own branch model, not the suite's promotion.
declare -A PROMOTED_SHA=()
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
# ── module subtrees ───────────────────────────────────────────────────
# Every modules/<m> with a repo in polari-modules.json is ALSO its own
# public project (polari-module-<m>); the in-tree copy is authoritative.
# After polari-framework pushes, compare each module's subtree (tree
# hash of HEAD:modules/<m>) with the module repo's main and re-publish
# only the stale ones (subtree split + push). Dry run just reports.
# Skip with --skip-modules.
publish_module_subtrees() {
  local fw="$SUITE/polari-rf-node/polari-framework"
  local reg="$fw/modules/polari-modules.json"
  [ -f "$reg" ] || { warn "no module registry — skipping subtrees"; return 0; }
  local stale=() fresh=0 unreachable=() failed=()
  while IFS=$'\t' read -r mod path repo; do
    [ -n "$repo" ] || continue
    [ -d "$fw/$path" ] || continue
    local local_tree remote_tree
    local_tree=$(git -C "$fw" rev-parse "HEAD:$path" 2>/dev/null) || continue
    if git -C "$fw" fetch -q "$repo" main 2>/dev/null; then
      remote_tree=$(git -C "$fw" rev-parse FETCH_HEAD^{tree} 2>/dev/null)
    else
      remote_tree=""; unreachable+=("$mod")
    fi
    if [ "$local_tree" = "$remote_tree" ]; then
      fresh=$((fresh + 1)); continue
    fi
    stale+=("$mod")
    if [ $DO_PUSH -eq 1 ]; then
      local br="_split-$mod"
      git -C "$fw" branch -D "$br" >/dev/null 2>&1 || true
      if git -C "$fw" subtree split --prefix="$path" -b "$br" >/dev/null 2>&1 \
         && git -C "$fw" push -q "$repo" "$br:main"; then
        ok "module $mod -> ${repo##*/} (re-published)"
      else
        fail "module $mod: subtree publish FAILED ($repo)"; failed+=("$mod")
      fi
      git -C "$fw" branch -D "$br" >/dev/null 2>&1 || true
    fi
  done < <(python3 - "$reg" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
for name, e in sorted(doc.get('modules', {}).items()):
    print(f"{name}\t{e.get('path') or 'modules/' + name}\t{e.get('repo') or ''}")
PYEOF
)
  if [ $DO_PUSH -eq 1 ]; then
    ok "module subtrees: $fresh up to date, ${#stale[@]} re-published, ${#failed[@]} failed"
    [ ${#failed[@]} -eq 0 ] || return 1
  else
    if [ ${#stale[@]} -eq 0 ]; then
      ok "module subtrees: all $fresh up to date with their polari-module-* repos"
    else
      warn "module subtrees STALE (re-published on --push): ${stale[*]}"
    fi
  fi
  [ ${#unreachable[@]} -eq 0 ] || warn "module repos unreachable/empty: ${unreachable[*]}"
  return 0
}

find_artifacts() {
  git -C "$1" ls-tree -r -l "${2:-HEAD}" 2>/dev/null \
    | awk -v max="$ARTIFACT_MAX_BYTES" '$4 ~ /^[0-9]+$/ && $4 > max {print $4, $5}' \
    | grep -E "$ARTIFACT_RE" \
    | grep -vE "$ARTIFACT_ALLOW_RE" || true
}

check_artifacts() {
  local path="$1" found
  found=$(find_artifacts "$path" "${2:-HEAD}")
  [ -z "$found" ] && return 0
  fail "build artifacts tracked in git (>$((ARTIFACT_MAX_BYTES / 1024))KB) — refusing to push:"
  printf '%s\n' "$found" | while read -r size file; do
    fail "    $((size / 1024))KB  $file"
  done
  fail "    untrack them (git rm --cached) + .gitignore, and give each"
  fail "    a fetch-or-build path. Override for this run: ARTIFACT_MAX_BYTES=huge"
  return 1
}

# ci-12 — PROMOTION, ff-only, without touching the working tree.
# `git fetch . <src>:<dst>` updates a ref that is NOT checked out and refuses
# anything but a fast-forward unless the refspec is forced — which is exactly
# the rule his model wants: "refuse if any repo is not ff-able and say which".
promote_repo() {
  local rel="$1" path="$SUITE/$1" src="origin/$PROMOTE_FROM" head behind
  git -C "$path" fetch -q origin "$PROMOTE_FROM" 2>/dev/null || {
    fail "cannot fetch origin/$PROMOTE_FROM — is the branch published?"; return 1; }
  git -C "$path" fetch -q origin "$BRANCH" 2>/dev/null || true
  head=$(git -C "$path" rev-parse "$src" 2>/dev/null) || {
    fail "no $src in this repo — promote $PROMOTE_FROM first"; return 1; }
  # already there?
  if [ "$(git -C "$path" rev-parse "refs/heads/$BRANCH" 2>/dev/null || echo none)" = "$head" ] \
     && [ "$(git -C "$path" rev-parse "origin/$BRANCH" 2>/dev/null || echo none)" = "$head" ]; then
    ok "$BRANCH already == $src (${head:0:8}) — nothing to promote"
    PROMOTED_SHA["$rel"]="$head"
    return 0
  fi
  # ff-ability: the existing <branch> (local or remote) must be an ANCESTOR of src
  local existing=""
  existing=$(git -C "$path" rev-parse "refs/heads/$BRANCH" 2>/dev/null \
             || git -C "$path" rev-parse "origin/$BRANCH" 2>/dev/null || true)
  if [ -n "$existing" ] && ! git -C "$path" merge-base --is-ancestor "$existing" "$head"; then
    behind=$(git -C "$path" rev-list --count "$head..$existing" 2>/dev/null || echo '?')
    fail "NOT fast-forwardable: $BRANCH (${existing:0:8}) has $behind commit(s) that $PROMOTE_FROM does not"
    fail "    this repo must be reconciled by hand — the promotion stops here, innermost-first, so"
    fail "    nothing outside it has moved"
    return 1
  fi
  if ! check_artifacts "$path" "$head"; then return 1; fi
  if [ $DO_PUSH -eq 1 ]; then
    git -C "$path" fetch -q . "$PROMOTE_FROM:$BRANCH" 2>/dev/null \
      || git -C "$path" fetch -q origin "$PROMOTE_FROM:$BRANCH" || {
        fail "the local ref $BRANCH would not fast-forward to ${head:0:8}"; return 1; }
  fi
  PROMOTED_SHA["$rel"]="$head"
  ok "$BRANCH → ${head:0:8} (ff from $PROMOTE_FROM)$([ $DO_PUSH -eq 1 ] || echo '  [dry run]')"
  return 0
}

check_repo() {
  local rel="$1" path="$SUITE/$1"
  local branch dirty ahead
  dirty=$(git -C "$path" status --porcelain | wc -l)
  if [ "$dirty" -ne 0 ]; then
    fail "tree not clean ($dirty entries) — commit or stash first"
    errors=$((errors + 1))
    return 1
  fi
  if [ -n "$PROMOTE_FROM" ]; then
    # a promotion never switches the checkout: the ref moves, the worktree does not.
    if ! promote_repo "$rel"; then errors=$((errors + 1)); return 1; fi
    return 0
  fi
  branch=$(git -C "$path" branch --show-current)
  if [ "$branch" != "$BRANCH" ]; then
    fail "NOT on $BRANCH (on '$branch') — checkout/ff $BRANCH first"
    errors=$((errors + 1))
    return 1
  fi
  ahead=$(git -C "$path" rev-list --count "origin/$BRANCH..$BRANCH" \
          2>/dev/null || echo '?')
  ok "on $BRANCH, clean, $ahead commit(s) ahead of origin/$BRANCH"
  if ! check_artifacts "$path"; then
    errors=$((errors + 1))
    return 1
  fi
  # pointer coherence: every submodule pointer must be contained
  # in that submodule's $BRANCH. (Process substitution, not a pipe —
  # a piped while runs in a subshell and its failure exit would
  # be silently lost.)
  local bad=0 sha sub _rest
  while read -r sha sub _rest; do
    [ -z "$sha" ] && continue
    sha="${sha#[+-]}"
    # uninitialized nested submodule: nothing local to verify against —
    # the pointer is whatever the repo already published (a clean-room
    # clone resolves it or fails loudly there); don't block the sweep.
    if [ ! -e "$path/$sub/.git" ]; then
      warn "pointer $sub@${sha:0:8} — submodule not initialized here; containment not verifiable (skipping)"
      continue
    fi
    if ! git -C "$path/$sub" merge-base --is-ancestor \
         "$sha" "$BRANCH" 2>/dev/null; then
      # historic pointers may live on OTHER published branches — that
      # is still public/resolvable, just not this repo's $BRANCH tip.
      if [ -n "$(git -C "$path/$sub" branch -r --contains "$sha" 2>/dev/null | head -1)" ]; then
        warn "pointer $sub@${sha:0:8} is on a non-$BRANCH origin branch (published — ok)"
      else
        fail "pointer $sub@${sha:0:8} NOT contained in $sub's $BRANCH or any origin branch"
        bad=1
      fi
    fi
  done < <(git -C "$path" submodule status 2>/dev/null)
  if [ "$bad" -ne 0 ]; then
    errors=$((errors + 1))
    return 1
  fi
  return 0
}

bold "== ${PROMOTE_FROM:+promotion $PROMOTE_FROM → }$BRANCH push sweep ($([ $DO_PUSH -eq 1 ] \
     && echo PUSHING || echo DRY RUN)) =="

# ---- Isle-Mesh FIRST (innermost-first now applies to it too) -----
# The suite carries an Isle-Mesh submodule pointer, so the isle-core
# repo must publish BEFORE the suite does — same rule as every other
# submodule, just pushed over SSH from its home box.
if [ $WITH_ISLE -eq 1 ]; then
  bold "Isle-Mesh @ $ISLE_HOST:~/$ISLE_REPO ($BRANCH) — pushes before the suite"
  isle_state=$(ssh "$ISLE_HOST" "cd \"$ISLE_REPO\" 2>/dev/null && \
    printf '%s|%s|%s' \
      \"\$(git branch --show-current)\" \
      \"\$(git status --porcelain | wc -l | tr -d ' ')\" \
      \"\$(git rev-list --count origin/$BRANCH..$BRANCH 2>/dev/null || echo new)\"" \
    2>/dev/null)
  ibranch="${isle_state%%|*}"; irest="${isle_state#*|}"
  idirty="${irest%%|*}"; iahead="${irest#*|}"
  if [ -z "$isle_state" ]; then
    fail "could not reach $ISLE_HOST or ~/$ISLE_REPO"
    exit 1
  elif [ "$ibranch" != "$BRANCH" ]; then
    fail "isle-core NOT on $BRANCH (on '$ibranch') — fix there first"
    exit 1
  elif [ "$idirty" != "0" ]; then
    fail "isle-core tree not clean ($idirty entries) — commit there first"
    exit 1
  fi
  ok "on $BRANCH, clean, $iahead ahead of origin/$BRANCH (new = branch not yet on origin)"
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
    if ssh "$ISLE_HOST" "cd \"$ISLE_REPO\" && git push -u origin $BRANCH"; then
      ok "pushed (isle-core)"
      git -C "$SUITE/Isle-Mesh" fetch -q origin "$BRANCH" 2>/dev/null || true
    else
      fail "isle-core push FAILED"
      exit 1
    fi
  fi
fi

for rel in "${REPOS[@]}"; do
  bold "$rel"
  if ! check_repo "$rel"; then
    # ci-12: a PROMOTION stops at the first repo that will not fast-forward.
    # Innermost-first means nothing outside it has moved yet, so stopping here
    # leaves the forest coherent; carrying on would publish a superproject
    # pointer at a submodule branch that never got the commit.
    [ -z "$PROMOTE_FROM" ] || { fail "promotion STOPPED at $rel — nothing after it was touched"; exit 1; }
    continue
  fi
  # the suite's Isle-Mesh pointer must be PUBLIC before the suite is.
  # Isle-Mesh sits first in REPOS, so by the time "." pushes its
  # origin/$BRANCH already carries the pointer — this check catches a
  # sweep that skipped it (or a dry run against a stale origin).
  if [ "$rel" = "." ] && [ -e "$SUITE/Isle-Mesh/.git" ]; then
    isle_ptr=$(git -C "$SUITE" submodule status Isle-Mesh 2>/dev/null \
               | awk '{print $1}' | tr -d '+-')
    if ! git -C "$SUITE/Isle-Mesh" merge-base --is-ancestor \
         "$isle_ptr" "origin/$BRANCH" 2>/dev/null; then
      if [ $DO_PUSH -eq 0 ]; then
        warn "suite Isle-Mesh pointer ${isle_ptr:0:8} not on its origin/$BRANCH yet — the sweep pushes Isle-Mesh first, so this resolves during --push"
      else
        fail "suite Isle-Mesh pointer ${isle_ptr:0:8} is NOT on its origin/$BRANCH — did the Isle-Mesh push fail above?"
        errors=$((errors + 1))
        continue
      fi
    fi
  fi
  if [ $DO_PUSH -eq 0 ] && [ "$rel" = "polari-rf-node/polari-framework" ] && [ $SKIP_MODULES -eq 0 ]; then
    publish_module_subtrees
  fi
  if [ $DO_PUSH -eq 1 ]; then
    if git -C "$SUITE/$rel" push origin "$BRANCH"; then
      ok "pushed"
      if [ "$rel" = "polari-rf-node/polari-framework" ] && [ $SKIP_MODULES -eq 0 ]; then
        publish_module_subtrees || { fail "module subtree publish failed — stopping"; exit 1; }
      fi
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

# ci-12 — THE PROMOTION MARKER. The superproject is pushed LAST, so the sha set
# below is the complete, coherent forest state of <branch>. polari-jenkins reads
# it (pool/promotions/<branch>/<sha>.json) and treats a matching marker as
# "the promotion is finished" — which is what lets a poller start its quiet
# window immediately instead of waiting to see whether more commits are coming.
if [ -n "$SUMMARY_JSON" ]; then
  mkdir -p "$(dirname "$SUMMARY_JSON")"
  {
    printf '{\n  "branch": "%s",\n  "from": "%s",\n  "pushed": %s,\n' \
           "$BRANCH" "$PROMOTE_FROM" "$([ $DO_PUSH -eq 1 ] && echo true || echo false)"
    printf '  "at": "%s",\n  "repos": {' "$(date -Is)"
    sep=""
    for rel in "${REPOS[@]}"; do
      sha="${PROMOTED_SHA[$rel]:-$(git -C "$SUITE/$rel" rev-parse "$BRANCH" 2>/dev/null || true)}"
      [ -n "$sha" ] || continue
      printf '%s\n    "%s": "%s"' "$sep" "$rel" "$sha"; sep=","
    done
    printf '\n  },\n  "superproject": "%s"\n}\n' \
           "${PROMOTED_SHA[.]:-$(git -C "$SUITE" rev-parse "$BRANCH" 2>/dev/null || true)}"
  } > "$SUMMARY_JSON"
  ok "marker: $SUMMARY_JSON"
fi

[ $DO_PUSH -eq 0 ] \
  && bold "dry run clean — rerun with --push to publish"
exit 0
