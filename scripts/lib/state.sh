#!/bin/bash
# pol build-approach state — remembers the most recent configured build so
# `pol start` / `pol rebuild` / `pol stop` can shorthand it.
# Source AFTER lib/log.sh. State lives in the checkout's .generated/
# (machine-local, gitignored).

POL_STATE_FILE="$POL_SUITE_ROOT/.generated/pol-last-build"

record_build() {   # record_build <mode> <role> <env>
    mkdir -p "$POL_SUITE_ROOT/.generated"
    cat > "$POL_STATE_FILE" <<EOF
# most recent configured build approach (written by pol; read by
# pol start / rebuild / stop)
POL_LAST_MODE=$1
POL_LAST_ROLE=$2
POL_LAST_ENV=$3
POL_LAST_WHEN=$(date -Iseconds)
EOF
}

read_build() {     # sets POL_LAST_MODE/ROLE/ENV/WHEN; returns 1 + guidance if none
    if [ ! -f "$POL_STATE_FILE" ]; then
        log_warn "No build approach recorded yet — nothing to shorthand."
        echo "  pol remembers the most recent 'up'-style command you run, e.g.:"
        echo "    pol suite up --env staging      (combined stack)"
        echo "    pol node up --env dev           (standalone PRF)"
        echo "    pol compose engines up          (single service kind)"
        echo "  After one of those, 'pol start' restarts it if down, 'pol rebuild'"
        echo "  rebuilds images + recreates it, 'pol stop' takes it down."
        return 1
    fi
    # shellcheck disable=SC1090
    source "$POL_STATE_FILE"
}
