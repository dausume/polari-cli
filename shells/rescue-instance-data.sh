#!/usr/bin/env bash
# rescue-instance-data.sh — copy a polari instance's sqlite databases out
# of the container's writable layer and into its mounted data volume,
# BEFORE the container is replaced.
#
#   ./rescue-instance-data.sh                 dry run: report every instance
#   ./rescue-instance-data.sh --apply         do the copy
#   ./rescue-instance-data.sh --apply NAME... only these containers
#   ISLE_HOST=isle-core ./rescue-instance-data.sh [--apply]   over SSH
#
# WHY THIS EXISTS
# DATABASE_PATH was never wired into the config loader, so every compose
# file's DATABASE_PATH=/data/polari.db was dead and the sqlite files went
# to ./data -> /app/data INSIDE THE CONTAINER, while the volume mounted at
# /data sat empty. Any container recreate — a redeploy, or `isle polari
# module move`, which recreates both backends — silently threw the
# instance's object data away.
#
# The fix makes the framework honor DATABASE_PATH. But a container
# recreate discards the old writable layer, so the fix alone cannot save
# data that is already sitting in /app/data: it has to be moved into the
# volume while the OLD container is still running. That is this script.
#
# It is additive and safe: it only writes into the volume, never deletes
# from the container, and refuses to overwrite databases already there.
# Copies use sqlite's online backup API, not `cp`, so a live database in
# mid-write yields a consistent snapshot rather than a torn file.

set -uo pipefail

APPLY=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) TARGETS+=("$arg") ;;
  esac
done

ISLE_HOST="${ISLE_HOST:-}"
# Requote every argument for the remote shell. Passing "$*" instead would
# flatten the arguments and let the remote shell word-split them, which
# silently mangles both the --format templates and the worker script.
D() {
  if [ -n "$ISLE_HOST" ]; then
    ssh "$ISLE_HOST" "$(printf '%q ' docker "$@")"
  else
    docker "$@"
  fi
}

G="\033[0;32m"; Y="\033[1;33m"; R="\033[0;31m"; C="\033[0;36m"; N="\033[0m"
ok(){   printf "  ${G}%s${N}\n" "$*"; }
warn(){ printf "  ${Y}%s${N}\n" "$*"; }
err(){  printf "  ${R}%s${N}\n" "$*"; }
step(){ printf "${C}==>${N} %s\n" "$*"; }

# The in-container worker. Reports what it finds, and with APPLY=1 copies
# each database into the volume via sqlite's online backup.
read -r -d '' WORKER <<'PY'
import glob, os, sqlite3, sys

apply_ = os.environ.get('RESCUE_APPLY') == '1'
dest = os.environ.get('RESCUE_DEST', '/data')
srcs = sorted(glob.glob('/app/data/*_DB.db'))

if not srcs:
    print('NONE no databases in /app/data')
    sys.exit(0)

if not os.path.isdir(dest):
    print(f'ERROR destination {dest} is not a directory (volume not mounted?)')
    sys.exit(1)

for src in srcs:
    name = os.path.basename(src)
    dst = os.path.join(dest, name)
    size = os.path.getsize(src)
    if os.path.exists(dst):
        print(f'SKIP {name} {size} destination already has it')
        continue
    if not apply_:
        print(f'WOULD {name} {size} -> {dst}')
        continue
    try:
        s = sqlite3.connect(f'file:{src}?mode=ro', uri=True)
        d = sqlite3.connect(dst)
        with d:
            s.backup(d)
        s.close(); d.close()
        print(f'COPIED {name} {size} -> {dst} ({os.path.getsize(dst)} bytes)')
    except Exception as e:
        try:
            os.remove(dst)
        except OSError:
            pass
        print(f'FAILED {name} {e}')
        sys.exit(1)
PY

# Discover polari backend containers if none were named.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  # Instance backends are named prf-<instance>-backend (isle: prf-isle-,
  # prf-polari-2-, ...; suite swarm: polari-node_backend.N).
  mapfile -t TARGETS < <(D ps --format '{{.Names}}' \
    | grep -E 'backend' | grep -vE 'frontend' || true)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  err "no running polari backend containers found${ISLE_HOST:+ on $ISLE_HOST}"
  exit 1
fi

printf "== instance data rescue (%s)%s ==\n" \
  "$([ $APPLY -eq 1 ] && echo APPLYING || echo 'DRY RUN')" \
  "${ISLE_HOST:+ @ $ISLE_HOST}"

rc=0
for c in "${TARGETS[@]}"; do
  step "$c"

  # Where is the data volume mounted? That is the rescue destination.
  # Listed and matched here rather than with a {{if eq}} in the template:
  # the nested quotes that needs do not survive the trip through ssh.
  mounts=$(D inspect "$c" --format '{{range .Mounts}}{{.Destination}} {{end}}' 2>/dev/null)
  dest=""
  case " $mounts " in
    *" /data "*)     dest=/data ;;
    *" /app/data "*) dest=/app/data ;;
  esac
  if [ "$dest" = "/app/data" ]; then
    ok "volume already mounted at /app/data — data is where the framework writes it; nothing to rescue"
    continue
  fi
  if [ -z "$dest" ]; then
    warn "no volume mounted at /data — nothing to rescue into; fix the compose first"
    rc=1
    continue
  fi

  out=$(D exec -e RESCUE_APPLY="$APPLY" -e RESCUE_DEST="$dest" -i "$c" \
        python3 -c "$WORKER" 2>&1)
  status=$?
  while IFS= read -r line; do
    case "$line" in
      COPIED*) ok "$line" ;;
      WOULD*)  warn "$line" ;;
      SKIP*)   ok "$line" ;;
      NONE*)   ok "$line" ;;
      FAILED*|ERROR*) err "$line"; rc=1 ;;
      *) [ -n "$line" ] && echo "  $line" ;;
    esac
  done <<< "$out"
  [ $status -ne 0 ] && rc=1
done

echo
if [ $APPLY -eq 0 ]; then
  echo "dry run — rerun with --apply to copy. Do this BEFORE redeploying"
  echo "instances onto a build that honors DATABASE_PATH, or the data in"
  echo "the container layer goes away with the old container."
else
  [ $rc -eq 0 ] && ok "rescue complete" || err "rescue finished with errors"
fi
exit $rc
