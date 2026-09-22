#!/bin/bash
# polari-cli/scripts/prod-agent.sh — THE DEPLOY AGENT ON A PRODUCTION TARGET (dep-1, his ruling 2026-09-22).
#
# "The prod is a docker swarm deployment; the ssh used by jenkins does not touch any of the secrets for
#  production and CANNOT; it is only doing a smooth replacement of the images while ensuring the data
#  stored in volumes is safely stashed, so the deployment goes smoothly and safely without interruption."
#
# So this is the ONLY thing the pipeline's key may run on a target. `pol jenkins deploy authorize` installs
# that key as   restrict,command="<this file's absolute path>"   in authorized_keys: no shell, no forwarding,
# no other command — sshd hands every connection to this script, whatever was asked for, and the verb
# arrives in SSH_ORIGINAL_COMMAND. The script reads NO answers file, NO vault, NO certificate: what it knows
# it reads from the running swarm, and `docker service update --image` keeps every secret and config
# attached exactly as they are. It never runs `pol prod apply`.
#
#   current             what runs here: release · stack · per-service image tags · free disk · last update
#   stash <version>     tar EVERY named volume of the stack to ~/.polari-stash/<ts>-<version>/ BEFORE an update
#   update <version>    for each service whose image is <registry>/<name>:<tag>: docker service update --image
#                       <registry>/<name>:<version>, start-first, one at a time, waiting for convergence,
#                       swarm's own rollback on failure. The previous tags are recorded for `rollback`.
#   rollback <version>  the same, back to <version> (releases are immutable — back is a re-pin)
#   verify              every service converged (replicas n/n) and the local /api/health answers
#   stash-list          the stashes kept here (a person restores one: pol prod restore <id>)
#   --path              print this file's absolute path (what authorize writes into the forced command)
# Anything else is REFUSED and logged. Exit 0 = done; 1 = failed; 2 = refused.
set -uo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
STASH_ROOT="${POLARI_STASH_DIR:-$HOME/.polari-stash}"; KEEP_STASHES="${POLARI_STASH_KEEP:-3}"
LOG="$STASH_ROOT/agent.log"
DOCKER="${POLARI_DOCKER:-docker}"
say() { printf '[agent] %s\n' "$*"; }
log() { mkdir -p "$STASH_ROOT"; printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG" 2>/dev/null || true; }

# the verb: from the forced command's SSH_ORIGINAL_COMMAND (with or without a "pol prod agent" prefix), else argv
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    # shellcheck disable=SC2206
    ARGV=(${SSH_ORIGINAL_COMMAND#pol prod agent}); ARGV=("${ARGV[@]}")
else ARGV=("$@"); fi
VERB="${ARGV[0]:-}"; ARG="${ARGV[1]:-}"
case "$VERB" in current|stash|update|rollback|verify|stash-list|--path) ;;
    *) log "REFUSED: ${SSH_ORIGINAL_COMMAND:-$*}"; say "REFUSED: '${VERB:-}' is not a deploy verb (current|stash|update|rollback|verify|stash-list). This key runs nothing else."; exit 2 ;;
esac
case "$ARG" in ''|[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]|[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9].[0-9]*) ;;
    *) log "REFUSED: bad version '$ARG'"; say "REFUSED: '$ARG' is not a version (YYYY.MM.DD[.N])"; exit 2 ;; esac

stack_name() {  # the pol prod stack on this swarm (lean or full); empty = none
    $DOCKER stack ls --format '{{.Name}}' 2>/dev/null | grep -E -m1 '^polari-(lean|prod)$' || true
}
services() {  # services <stack> → name<TAB>image (repo:tag, digest stripped)<TAB>replicas
    $DOCKER service ls --filter "label=com.docker.stack.namespace=$1" --format '{{.Name}}	{{.Image}}	{{.Replicas}}' 2>/dev/null | sed 's/@sha256:[0-9a-f]*//'
}
our_image() {  # our_image <repo:tag> → 0 when it is a registry image of ours (has a namespace and a version-shaped tag)
    case "$1" in */*:[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*|*/*:lean|*/*:prod|*/*:staging) return 0 ;; *) return 1 ;; esac
}
backend_tag() { services "$1" | awk -F'\t' '$1 ~ /prf-backend$/ {split($2, a, ":"); print a[length(a)]; exit}'; }

case "$VERB" in
    --path) printf '%s\n' "$SELF" ;;
    current)
        S="$(stack_name)"; TAG="$([ -n "$S" ] && backend_tag "$S")"
        echo "release=$(case "$TAG" in [0-9][0-9][0-9][0-9].*) echo "polari-v$TAG" ;; *) echo "" ;; esac)"
        echo "image_tag=${TAG:-}"; echo "stack=${S:-none}"
        [ -n "$S" ] && services "$S" | awk -F'\t' '{print "service=" $1 "|" $2 "|" $3}'
        echo "updated_at=$([ -n "$S" ] && $DOCKER service inspect "$(services "$S" | awk -F'\t' '$1 ~ /prf-backend$/{print $1; exit}')" --format '{{.UpdatedAt}}' 2>/dev/null | cut -c1-19)"
        echo "free_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc 0-9)"
        echo "swarm=$($DOCKER info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo none)"
        echo "stashes=$(ls -1d "$STASH_ROOT"/*-* 2>/dev/null | wc -l | tr -d ' ')"
        echo "agent=$SELF" ;;
    stash)
        [ -n "$ARG" ] || { say "stash needs the version being deployed"; exit 2; }
        S="$(stack_name)"; [ -n "$S" ] || { say "no pol prod stack on this swarm — nothing to stash"; echo "stash=none"; exit 0; }
        D="$STASH_ROOT/$(date +%Y%m%d-%H%M%S)-before-$ARG"; mkdir -p "$D"
        VOLS="$($DOCKER volume ls --filter "label=com.docker.stack.namespace=$S" --format '{{.Name}}' 2>/dev/null)"
        [ -n "$VOLS" ] || { say "the stack has no named volumes — nothing to stash"; echo "stash=$D (empty)"; exit 0; }
        log "stash → $D: $VOLS"
        FAIL=0
        for v in $VOLS; do
            # a tiny helper container reads the volume read-only and writes ONE archive into the stash
            if $DOCKER run --rm -v "$v:/v:ro" -v "$D:/s" busybox:stable tar czf "/s/$v.tgz" -C /v . 2>>"$LOG"; then
                say "stashed $v → $(du -h "$D/$v.tgz" | cut -f1)"
            else say "FAILED to stash $v"; FAIL=1; fi
        done
        printf '{"stack": "%s", "before": "%s", "volumes": %s, "at": "%s", "complete": %s}\n' "$S" "$ARG" \
               "$(printf '%s\n' $VOLS | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))')" "$(date -Is)" "$([ "$FAIL" = 0 ] && echo true || echo false)" > "$D/stash.json"
        # keep the newest KEEP_STASHES
        ls -1dt "$STASH_ROOT"/*-before-* 2>/dev/null | tail -n +"$((KEEP_STASHES + 1))" | while read -r old; do rm -rf "$old"; say "pruned old stash $(basename "$old")"; done
        echo "stash=$D"; [ "$FAIL" = 0 ] || { say "the stash is INCOMPLETE — the update must not proceed"; exit 1; } ;;
    update|rollback)
        [ -n "$ARG" ] || { say "$VERB needs a version"; exit 2; }
        S="$(stack_name)"; [ -n "$S" ] || { say "no pol prod stack on this swarm — nothing to $VERB (the first deploy is a person's pol prod apply)"; exit 1; }
        PREV="$STASH_ROOT/last-update.json"; mkdir -p "$STASH_ROOT"; ROWS=""; FAIL=0; N=0
        log "$VERB → $ARG on $S"
        while IFS=$'\t' read -r name image reps; do
            [ -n "$name" ] || continue
            our_image "$image" || { say "leave  $name ($image — not a versioned image of ours)"; continue; }
            repo="${image%:*}"; oldtag="${image##*:}"; new="$repo:$ARG"
            [ "$oldtag" = "$ARG" ] && { say "same   $name already runs $new"; continue; }
            N=$((N + 1)); say "update $name: $image → $new (start-first, waiting for convergence)"
            if $DOCKER service update --image "$new" --update-order start-first --update-parallelism 1 --update-delay 5s \
                    --update-failure-action rollback --rollback-order start-first --detach=false "$name" >>"$LOG" 2>&1; then
                say "  ✓ $name converged on $new"; ROWS="$ROWS{\"service\": \"$name\", \"from\": \"$image\", \"to\": \"$new\", \"ok\": true},"
            else
                say "  ✗ $name did NOT converge on $new — swarm rolled that service back (docker service ps $name)"; FAIL=1
                ROWS="$ROWS{\"service\": \"$name\", \"from\": \"$image\", \"to\": \"$new\", \"ok\": false},"
                break   # one at a time, and the first failure stops the rest
            fi
        done < <(services "$S")
        printf '{"verb": "%s", "version": "%s", "stack": "%s", "at": "%s", "services": [%s], "ok": %s}\n' "$VERB" "$ARG" "$S" "$(date -Is)" "${ROWS%,}" "$([ "$FAIL" = 0 ] && echo true || echo false)" > "$PREV"
        [ "$N" -gt 0 ] || say "nothing to $VERB: no service runs a different version"
        [ "$FAIL" = 0 ] && { say "$VERB to $ARG: done ($N service(s))"; exit 0; } || { say "$VERB to $ARG: FAILED"; exit 1; } ;;
    verify)
        S="$(stack_name)"; [ -n "$S" ] || { say "no pol prod stack"; exit 1; }
        BAD=0
        while IFS=$'\t' read -r name image reps; do
            [ -n "$name" ] || continue
            case "$reps" in *"/"*) have="${reps%%/*}"; want="${reps##*/}"; want="${want%% *}" ;; *) have=?; want=? ;; esac
            if [ "$have" = "$want" ] && [ "$have" != 0 ]; then say "ok   $name $reps $image"; else say "BAD  $name $reps $image"; BAD=1; fi
        done < <(services "$S")
        H="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://127.0.0.1/api/health 2>/dev/null || echo 000)"
        case "$H" in 2*) say "ok   local /api/health → $H" ;; *) say "BAD  local /api/health → $H"; BAD=1 ;; esac
        [ "$BAD" = 0 ] && { echo "verify=ok"; exit 0; } || { echo "verify=failed"; exit 1; } ;;
    stash-list)
        for d in $(ls -1dt "$STASH_ROOT"/*-before-* 2>/dev/null); do echo "$(basename "$d")	$(du -sh "$d" 2>/dev/null | cut -f1)	$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(d.get("volumes",[])), "complete" if d.get("complete") else "INCOMPLETE")' "$d/stash.json" 2>/dev/null)"; done
        [ -n "$(ls -1d "$STASH_ROOT"/*-before-* 2>/dev/null)" ] || echo "(no stashes)" ;;
esac
