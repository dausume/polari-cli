#!/bin/bash
# prod-update.sh — `pol prod update` + `pol prod sources`: THE DEVICE-SIDE UPDATE (dep-3, his ruling 2026-09-27).
#
# His ruling: the pipeline handles nothing beyond "the assets being generated and made available" (the release
# and its publish). DEPLOYMENT is a person going into the device and running ONE command that updates from the
# REGISTERED locations — GitHub today, a self-hosted forge later: a list (`pol prod sources`), never a
# hard-coded host — WITHOUT interrupting services. No pipeline-driven deploys; no pipeline ssh into production.
#
#   pol prod update [<version>|latest] [--source <owner/repo>|github|forge] [--dry-run] [--yes]
#                   [--no-stash] [--no-checkout] [--history]
#   pol prod sources [list|add <owner/repo>|remove <owner/repo>]
#
# In order, every step printing its evidence:
#   1 resolve   the release on the first registered location that answers (latest = its newest polari-v tag
#               carrying release.json); release.json fetched unauthenticated
#   2 rule      the release rule ON THE DEVICE TOO: tested_against.verdict == passed AND publishedTo.ghcr.dryRun
#               == false (the images really exist). No override flag — exit 3.
#   3 plan      prod-agent.sh current → per service old image → new image; "already at" = exit 0; a downgrade
#               only with an explicit version AND --yes; disk floor (3 × image sizes, else POL_PROD_UPDATE_MIN_GB=5)
#   4 --dry-run stops here, printing the exact agent verbs
#   5 stash     prod-agent.sh stash <v> (every stack volume, read-only) — the person's undo: pol prod restore <id>
#   6 update    prod-agent.sh update <v>: start-first, one service at a time — non-interrupting by construction
#   7 verify    prod-agent.sh verify + /api/health through the proxy (cert fingerprint reported); failure →
#               rollback to the previous version automatically, exit 4
#   8 checkout  the suite checkout moves to the release tag AFTER the images are live, from a temp helper that is
#               exec'd as the very last action (it replaces prod.sh and this file under the running bash)
#   9 record    .generated/updates/<ts>-<version>.json; `--history` lists them; `pol prod status` shows the last
#
# What it NEVER touches: secrets, the answers, configs, the stack file. `docker service update --image` keeps
# every secret and config attached as they are; changing any of those is `pol prod apply` — another verb, on
# purpose. The image swap itself is prod-agent.sh, called directly: ONE implementation of "replace images without
# interruption". Idempotent: a second run finds "already at" (or finishes the services a failed run left behind).
# Docker access as pol prod has it today (the docker group; no sudo).
#
# The isle twin — NOT built here: `isle update` (the deb route: apt from the registered apt source + image load +
# a rolling container restart) is the isle-side twin of this verb, owned by Isle-Mesh.
#
# Exit: 0 done / already at / dry run · 1 failed (rolled back where it could) · 2 usage · 3 refused · 4 verify failed, rolled back.
PU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(type -t log_info)" = function ] || source "$PU_DIR/lib/log.sh"
[ "$(type -t official_release_sources)" = function ] || source "$PU_DIR/lib/providers.sh"
source "$PU_DIR/lib/prod-sources.sh"
PU_GEN="$POL_SUITE_ROOT/.generated"; PU_UPDATES="$PU_GEN/updates"; PU_AGENT="$PU_DIR/prod-agent.sh"

pu_say()   { printf '  %-10s %s\n' "$1" "$2"; }     # step · evidence
pu_indent(){ sed 's/^/             /'; }
pu_agent() { bash "$PU_AGENT" "$@"; }
pu_version() {  # 2026.09.27 | polari-v2026.09.27 → 2026.09.27 ('' when not a release version)
    local v="${1#polari-v}"
    case "$v" in [0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]|[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9]|[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9][0-9]) echo "$v" ;; esac
}
pu_vkey() {  # release/tag → sortable number ('' when not a release); polari-v2026.09.12-core reads as 2026.09.12
    local v="${1#polari-v}" y m d n; v="${v%%-*}"; [ -n "$(pu_version "$v")" ] || return 0
    IFS=. read -r y m d n <<<"$v"; printf '%04d%02d%02d%04d\n' "$((10#$y))" "$((10#$m))" "$((10#$d))" "$((10#${n:-0}))"
}
pu_versioned() {  # the preview's copy of prod-agent.sh our_image — THE AGENT decides; this only shows what it will do
    case "$1" in */*:[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*|*/*:polari-v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*|*/*:lean|*/*:prod|*/*:staging) return 0 ;; *) return 1 ;; esac
}
pu_image_bytes() {  # registry/path:tag → compressed size in bytes of this machine's platform ('' when the registry says nothing)
    local ref="$1" host path tag tok acc m arch
    host="${ref%%/*}"; path="${ref#*/}"; tag="${path##*:}"; path="${path%:*}"
    [ "$host" = ghcr.io ] && tok="$(curl -fsSL --max-time 10 "https://ghcr.io/token?scope=repository:$path:pull" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
    acc='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
    case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
    m="$(curl -fsSL --max-time 10 ${tok:+-H "Authorization: Bearer $tok"} -H "Accept: $acc" "https://$host/v2/$path/manifests/$tag" 2>/dev/null)" || return 0
    local pick='import sys,json
d = json.loads(sys.stdin.read() or "{}")
if "manifests" in d: print("digest", next((x["digest"] for x in d["manifests"] if (x.get("platform") or {}).get("architecture") == sys.argv[1]), ""))
elif "layers" in d: print("bytes", sum(int(l.get("size", 0)) for l in d["layers"]) + int((d.get("config") or {}).get("size", 0)))'
    set -- $(printf '%s' "$m" | python3 -c "$pick" "$arch" 2>/dev/null)
    if [ "${1:-}" = digest ] && [ -n "${2:-}" ]; then
        m="$(curl -fsSL --max-time 10 ${tok:+-H "Authorization: Bearer $tok"} -H "Accept: $acc" "https://$host/v2/$path/manifests/$2" 2>/dev/null)" || return 0
        set -- $(printf '%s' "$m" | python3 -c "$pick" "$arch" 2>/dev/null)
    fi
    [ "${1:-}" = bytes ] && echo "${2:-}"
}
pu_cert_fp() { [ -s "$PU_GEN/certs/edge/fullchain.pem" ] && sha256sum "$PU_GEN/certs/edge/fullchain.pem" | cut -c1-16 || echo none; }
pu_health() {  # the pol prod status reading: /api/health through the proxy, with the answered domain's API name
    local dom; dom="$(sed -n 's/^POL_PROD_DOMAIN=//p' "$PU_GEN/prod-answers.env" 2>/dev/null | tail -1)"   # read-only, one key
    curl -sk --max-time 10 ${dom:+-H "Host: api.prf.$dom"} https://127.0.0.1/api/health 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('phase'), '—', d.get('onlineCount'), '/', d.get('moduleCount'), 'modules online')" 2>/dev/null
}

pu_history() {
    ls "$PU_UPDATES"/*.json >/dev/null 2>&1 || { echo "no updates recorded yet ($PU_UPDATES)"; return 0; }
    printf '  %-20s %-22s %-12s %-22s %s\n' when from to result elapsed
    for f in "$PU_UPDATES"/*.json; do python3 -c '
import json,sys; d=json.load(open(sys.argv[1]))
print("  %-20s %-22s %-12s %-22s %ss  stash=%s" % (d.get("at","")[:19], d.get("from") or "-", d.get("to",""), d.get("result",""), d.get("elapsed",""), (d.get("stash") or "-")))' "$f"; done
}
prod_update_last() {  # one line for pol prod status
    local f; f="$(ls -1 "$PU_UPDATES"/*.json 2>/dev/null | tail -1)"
    [ -n "$f" ] || { echo "none recorded (pol prod update)"; return 0; }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("to",""), d.get("at","")[:19], d.get("result",""))' "$f" 2>/dev/null || echo "unreadable: $f"
}
pu_record() {  # result verify → writes the record, prints its path
    mkdir -p "$PU_UPDATES"; local f; f="$PU_UPDATES/$(date -u +%Y%m%dT%H%M%SZ)-$VERSION.json"
    PU_RESULT="$1" PU_VERIFY="$2" PU_ELAPSED="$SECONDS" PU_FROM="$FROM" PU_TO="$VERSION" PU_SRC="$SRC" PU_SHA="$SHA" \
    PU_VERDICT="$VERDICT" PU_STASH="$STASH_ID" PU_ROWS="$MOVES" PU_CHECKOUT="${CHECKOUT_STATE:-}" python3 -c '
import json, os, sys, datetime
e = os.environ
rows = [dict(zip(("service", "from", "to"), r.split("|"))) for r in e["PU_ROWS"].splitlines() if r]
json.dump({"from": e["PU_FROM"], "to": e["PU_TO"], "source": e["PU_SRC"], "sha": e["PU_SHA"], "verdict": e["PU_VERDICT"],
           "stash": e["PU_STASH"], "services": rows, "verify": e["PU_VERIFY"], "result": e["PU_RESULT"],
           "elapsed": int(e["PU_ELAPSED"]), "checkout": e["PU_CHECKOUT"],
           "at": datetime.datetime.now().isoformat(timespec="seconds")}, open(sys.argv[1], "w"), indent=1)' "$f"
    echo "$f"
}
pu_rollback() {  # back to the version that ran before — re-pin through the agent, else swarm's own per-service rollback
    if [ -n "$(pu_version "$PREV_TAG")" ] && [ "$PREV_TAG" = "$(pu_version "$PREV_TAG")" ]; then
        pu_say rollback "prod-agent.sh rollback $PREV_TAG"; pu_agent rollback "$PREV_TAG" 2>&1 | pu_indent
    else   # the previous tag (polari-v…-core, lean, …) is not a version the agent can re-pin: swarm keeps the previous spec
        pu_say rollback "previous tag '$PREV_TAG' is not a release version — docker service rollback per moved service"
        printf '%s\n' "$MOVES" | while IFS='|' read -r name _ _; do [ -n "$name" ] || continue
            ${POLARI_DOCKER:-docker} service rollback --detach=false "$name" >/dev/null 2>&1 && echo "  ✓ $name rolled back" || echo "  ✗ $name: rollback failed (docker service ps $name)"; done | pu_indent
    fi
}

pu_checkout_prepare() {  # sets CHECKOUT_STATE and, when the move is possible, PU_HELPER (exec'd last)
    local suite="$POL_SUITE_ROOT"
    git -C "$suite" rev-parse --git-dir >/dev/null 2>&1 || { CHECKOUT_STATE="skipped: $suite is not a git checkout"; return; }
    [ -z "$(git -C "$suite" status --porcelain --untracked-files=no 2>/dev/null)" ] || { CHECKOUT_STATE="skipped: local changes in $suite — nothing discarded; move it by hand"; return; }
    git -C "$suite" fetch -q --tags origin 2>/dev/null || true
    git -C "$suite" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { CHECKOUT_STATE="skipped: tag $TAG is not on the checkout's origin — the images ARE updated; the CLI stays at its version"; return; }
    [ "$(git -C "$suite" rev-parse HEAD)" = "$(git -C "$suite" rev-parse "$TAG^{commit}")" ] && { CHECKOUT_STATE="already at $TAG"; return; }
    PU_HELPER="$(mktemp "${TMPDIR:-/tmp}/pol-prod-checkout.XXXXXX")"; CHECKOUT_STATE="scheduled: $TAG"
    cat > "$PU_HELPER" <<EOF
#!/bin/bash
# pol prod update, step 8 — runs from a temp copy because it replaces prod.sh/prod-update.sh themselves
if git -C '$suite' checkout -q '$TAG' && git -C '$suite' submodule update --init -q; then
    printf '  %-10s %s\n' checkout "$suite now at $TAG (detached) — the CLI is this release's"; r="ok: $TAG"
else printf '  %-10s %s\n' checkout "FAILED to move $suite to $TAG — the images are live; the CLI stays at its version"; r="failed: $TAG"; fi
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["checkout"]=sys.argv[2]; json.dump(d, open(p,"w"), indent=1)' '@@RECORD@@' "\$r" 2>/dev/null
rm -f "\$0"
EOF
}

pu_update() {
    set +e
    local want="" filter="" dry=0 yes=0 do_stash=1 do_checkout=1 explicit=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --source) filter="${2:-}"; shift ;;
            --source=*) filter="${1#--source=}" ;;
            --dry-run) dry=1 ;; --yes|-y) yes=1 ;; --no-stash) do_stash=0 ;; --no-checkout) do_checkout=0 ;;
            --history) pu_history; return 0 ;;
            latest) want=latest ;;
            -*) echo "unknown option $1 — pol prod help"; exit 2 ;;
            *) want="$(pu_version "$1")"; explicit=1; [ -n "$want" ] || { echo "'$1' is not a release version (2026.09.27 or polari-v2026.09.27)"; exit 2; } ;;
        esac; shift
    done
    : "${want:=latest}"
    pol_box "pol prod update — $want"

    # 1 — resolve on the registered locations, in order
    local rows kind base repo line="" f
    rows="$(prod_sources)"
    case "$filter" in
        '') ;; github|forge) rows="$(printf '%s\n' "$rows" | awk -F'\t' -v k="$filter" '$1 == k')" ;;
        *) rows="$(printf '%s\n' "$rows" | awk -F'\t' -v r="$filter" '$3 == r')" ;;
    esac
    [ -n "$rows" ] || { echo "no registered location matches '$filter' — pol prod sources list / pol prod sources add <owner/repo>"; exit 2; }
    while IFS=$'\t' read -r kind base repo; do
        [ "$want" = latest ] && line="$(pu_release_newest "$kind" "$base" "$repo")" || line="$(pu_release_at "$kind" "$base" "$repo" "polari-v$want")"
        [ -n "$line" ] && break
        pu_say source "$kind $repo — no answer, or no $([ "$want" = latest ] && echo release || echo "polari-v$want") carrying release.json (next location)"
    done <<<"$rows"
    [ -n "$line" ] || { echo "no registered location answered with a release — nothing changed"; exit 1; }
    TAG="${line%%$'\t'*}"; VERSION="${TAG#polari-v}"; SRC="$kind:$repo"
    PU_TMP="$(mktemp -d)"; trap 'rm -rf "$PU_TMP"' EXIT
    curl -fsSL --max-time 30 "${line#*$'\t'}" -o "$PU_TMP/release.json" 2>/dev/null || { echo "could not fetch ${line#*$'\t'} — nothing changed"; exit 1; }
    local R; R="$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1])); t = d.get("tested_against") or {}; g = (d.get("publishedTo") or {}).get("ghcr")
print("polari=%s" % d.get("polari", "")); print("sha=%s" % t.get("sha", "")); print("verdict=%s" % t.get("verdict", ""))
print("why=%s" % (t.get("why") or "").replace("\n", " ")); print("report=%s" % t.get("report", ""))
print("ghcr=%s" % ("absent" if not isinstance(g, dict) else ("dry" if g.get("dryRun", True) else "published")))
print("ghcr_url=%s" % ((g or {}).get("url", "") if isinstance(g, dict) else ""))
for k, v in sorted((t.get("images") or {}).items()): print("image=%s %s" % (k, v))' "$PU_TMP/release.json" 2>/dev/null)"
    [ -n "$R" ] || { echo "release.json of $TAG is not readable JSON — nothing changed"; exit 1; }
    SHA="$(sed -n 's/^sha=//p' <<<"$R")"; VERDICT="$(sed -n 's/^verdict=//p' <<<"$R")"
    pu_say resolve "$TAG from $SRC  (sha ${SHA:-unknown})"

    # 2 — the release rule, on the device too. No override.
    pu_say verdict "${VERDICT:-none}$(sed -n 's/^why=\(..*\)/ — \1/p' <<<"$R")"
    sed -n 's/^image=/tested image  /p' <<<"$R" | pu_indent
    sed -n 's/^report=\(..*\)/report  \1/p' <<<"$R" | pu_indent
    pu_say images "ghcr: $(sed -n 's/^ghcr=//p' <<<"$R") $(sed -n 's/^ghcr_url=//p' <<<"$R")"
    local pol; pol="$(sed -n 's/^polari=//p' <<<"$R")"
    [ -z "$pol" ] || [ "$pol" = "$VERSION" ] || { echo "REFUSED: $TAG's release.json describes version $pol — not this release. Nothing changed."; exit 3; }
    [ "$VERDICT" = passed ] || { echo "REFUSED: $TAG was not tested and passed (verdict '${VERDICT:-none}'). Only what was tested is deployed — nothing changed."; exit 3; }
    [ "$(sed -n 's/^ghcr=//p' <<<"$R")" = published ] || { echo "REFUSED: $TAG's images were never really pushed (publishedTo.ghcr is $(sed -n 's/^ghcr=//p' <<<"$R")) — there is nothing to pull. Nothing changed."; exit 3; }

    # 3 — what runs here vs the target (the agent's own reading)
    local cur; cur="$(pu_agent current 2>&1)"
    local stack; stack="$(sed -n 's/^stack=//p' <<<"$cur")"; FROM="$(sed -n 's/^release=//p' <<<"$cur")"; PREV_TAG="$(sed -n 's/^image_tag=//p' <<<"$cur")"
    local free; free="$(sed -n 's/^free_gb=//p' <<<"$cur")"
    [ -n "$stack" ] && [ "$stack" != none ] || { echo "no pol prod stack runs here — the first deploy is a person's pol prod apply. Nothing changed."; exit 1; }
    pu_say current "${FROM:-a local build} (backend tag ${PREV_TAG:-?}) · stack $stack"
    MOVES=""; local nver=0 name image reps refs=""
    while IFS='|' read -r name image reps; do
        [ -n "$name" ] || continue
        if ! pu_versioned "$image"; then pu_say service "$name  $image  (left alone — not a versioned image of ours)"; continue; fi
        nver=$((nver + 1))
        if [ "${image##*:}" = "$VERSION" ]; then pu_say service "$name  already $image"
        else pu_say service "$name  $image → ${image%:*}:$VERSION"; MOVES="$MOVES$name|$image|${image%:*}:$VERSION"$'\n'; refs="$refs ${image%:*}:$VERSION"; fi
    done < <(sed -n 's/^service=//p' <<<"$cur")
    [ "$nver" -gt 0 ] || { echo "this stack runs no release images (locally built) — move it to release images once with pol prod apply (POL_PROD_IMAGE_REPO=$(official_image_sources | head -1 | cut -f1)). Nothing changed."; exit 1; }
    [ -n "$MOVES" ] || { echo "already at $TAG — nothing to do"; exit 0; }
    local ck tk; ck="$(pu_vkey "$FROM")"; tk="$(pu_vkey "$TAG")"
    if [ -n "$ck" ] && [ "$ck" \> "$tk" ]; then
        pu_say downgrade "$FROM → $TAG is a DOWNGRADE"
        [ "$yes" = 1 ] && [ "$explicit" = 1 ] || { echo "REFUSED: a downgrade needs the version named explicitly AND --yes (pol prod update $VERSION --yes). Nothing changed."; exit 3; }
    fi
    local sum=0 b floor sized=1
    for f in $refs; do b="$(pu_image_bytes "$f")"; [ -n "$b" ] && sum=$((sum + b)) || sized=0; done
    if [ "$sized" = 1 ] && [ "$sum" -gt 0 ]; then floor=$(( (3 * sum + 1073741823) / 1073741824 )); pu_say disk "free ${free:-?} GB · images $((sum / 1048576)) MB → need more than $floor GB (3 × size)"
        [ "${free:-0}" -gt "$floor" ] || { echo "REFUSED: ${free:-?} GB free is not more than $floor GB — prune (docker system prune) first. Nothing changed."; exit 3; }
    else floor="${POL_PROD_UPDATE_MIN_GB:-5}"; pu_say disk "free ${free:-?} GB · the registry gave no size → need at least $floor GB"
        [ "${free:-0}" -ge "$floor" ] || { echo "REFUSED: ${free:-?} GB free is less than $floor GB — prune (docker system prune) first. Nothing changed."; exit 3; }
    fi

    # 4 — dry run: the exact verbs, nothing touched
    if [ "$dry" = 1 ]; then
        [ "$do_stash" = 1 ] && pu_say "would run" "$PU_AGENT stash $VERSION"
        pu_say "would run" "$PU_AGENT update $VERSION"
        pu_say "would run" "$PU_AGENT verify   (+ /api/health through the proxy)"
        [ -n "$(pu_version "$PREV_TAG")" ] && [ "$PREV_TAG" = "$(pu_version "$PREV_TAG")" ] && pu_say "on failure" "$PU_AGENT rollback $PREV_TAG" || pu_say "on failure" "docker service rollback <each moved service>   (previous tag '$PREV_TAG' is not a release version)"
        [ "$do_checkout" = 1 ] && pu_say "then" "git -C $POL_SUITE_ROOT fetch --tags origin && git checkout $TAG && git submodule update --init"
        echo "dry run — nothing changed"; exit 0
    fi
    if [ "$yes" != 1 ]; then
        [ -t 0 ] || { echo "running unattended: add --yes (or --dry-run first). Nothing changed."; exit 2; }
        local ans; read -r -p "  update $(printf '%s' "$MOVES" | grep -c .) service(s) to $TAG now, without stopping them? [y/N] " ans
        case "$ans" in y|Y|yes) ;; *) echo "nothing changed"; exit 0 ;; esac
    fi
    SECONDS=0; local fp0; fp0="$(pu_cert_fp)"; STASH_ID=""

    # 5 — stash
    if [ "$do_stash" = 1 ]; then
        local so; so="$(pu_agent stash "$VERSION" 2>&1)"; local src=$?
        printf '%s\n' "$so" | grep -v '^stash=' | pu_indent
        STASH_ID="$(sed -n 's/^stash=//p' <<<"$so" | sed 's/ (empty)$//')"; [ "$STASH_ID" = none ] || STASH_ID="$(basename "$STASH_ID")"
        [ "$src" = 0 ] || { pu_say stash "FAILED — the update does not proceed"; pu_record stash-failed "-" >/dev/null; exit 1; }
        pu_say stash "$STASH_ID   (undo, if ever needed: pol prod restore $STASH_ID)"
    else pu_say stash "skipped (--no-stash)"; fi

    # 6 — the rolling update
    pu_say update "prod-agent.sh update $VERSION (start-first, one service at a time)"
    pu_agent update "$VERSION" > "$PU_TMP/update.out" 2>&1; local urc=$?
    pu_indent < "$PU_TMP/update.out"
    if [ "$urc" != 0 ]; then
        pu_rollback; f="$(pu_record update-failed-rolled-back "-")"
        pu_say record "$f"; echo "update FAILED and was rolled back to ${PREV_TAG:-the previous images} — the services kept running"; exit 1
    fi

    # 7 — verify (converged + healthy through the proxy); failure → back to the previous version
    local v1 vrc=1 try=0 h
    while [ "$try" -lt "${POL_PROD_UPDATE_VERIFY_TRIES:-6}" ]; do
        try=$((try + 1)); v1="$(pu_agent verify 2>&1)"; vrc=$?; h="$(pu_health)"
        [ "$vrc" = 0 ] && [ -n "$h" ] && break
        [ "$try" -lt "${POL_PROD_UPDATE_VERIFY_TRIES:-6}" ] && sleep "${POL_PROD_UPDATE_VERIFY_WAIT:-10}"
    done
    printf '%s\n' "$v1" | pu_indent
    pu_say health "${h:-not answering through the proxy}"
    local fp1; fp1="$(pu_cert_fp)"
    pu_say cert "$([ "$fp0" = "$fp1" ] && echo "unchanged ($fp1)" || echo "CHANGED $fp0 → $fp1 (a renewal? pol prod status)")"
    if [ "$vrc" != 0 ] || [ -z "$h" ]; then
        pu_say verify "FAILED — rolling back to ${PREV_TAG:-the previous images}"
        pu_rollback; local v2; v2="$(pu_agent verify 2>&1)"
        echo "  verify after the update:"; printf '%s\n' "$v1" | pu_indent
        echo "  verify after the rollback:"; printf '%s\n' "$v2" | pu_indent
        f="$(pu_record verify-failed-rolled-back failed)"; pu_say record "$f"
        [ -n "$STASH_ID" ] && [ "$STASH_ID" != none ] && echo "  the data stash is kept: pol prod restore $STASH_ID (only if the data itself needs it)"
        exit 4
    fi
    pu_say verify "ok"

    # 8 + 9 — record, then the checkout (the helper is exec'd LAST: it replaces the scripts under this bash)
    PU_HELPER=""; if [ "$do_checkout" = 1 ]; then pu_checkout_prepare; else CHECKOUT_STATE="off (--no-checkout)"; fi
    f="$(pu_record ok ok)"; pu_say record "$f"
    pu_say checkout "$CHECKOUT_STATE"
    echo "updated to $TAG in ${SECONDS}s — no service was stopped"
    if [ -n "$PU_HELPER" ]; then
        sed -i "s|@@RECORD@@|$f|" "$PU_HELPER"; rm -rf "$PU_TMP"; trap - EXIT
        exec bash "$PU_HELPER"
    fi
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then   # run directly (the selftest; `pol prod` sources this file and calls pu_*)
    case "${1:-}" in
        update)  shift; pu_update "$@" ;;
        sources) shift; pu_sources "$@" ;;
        *) echo "usage: prod-update.sh update [...] | sources [list|add|remove]   (pol prod help)"; exit 2 ;;
    esac
fi
