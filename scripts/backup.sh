#!/bin/bash
# backup.sh — `pol backup`: backup sets of this machine (AI-Notes/plans/BACKUP_PLAN.md).
#   pol backup plan [--target <mount point>] [--table]   read-only: what a set would hold, sizes, what is left out, the target
#   create | list | verify | restore                      not built yet; they answer so and change nothing
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-help}" in
    help|-h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) exec python3 "$SCRIPT_DIR/lib/backup_plan.py" "$@" ;;
esac
