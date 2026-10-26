#!/bin/bash
# Shared by the desktop installer and its real apt transaction test.
# Caller supplies POOL, WORK and TARGETS. Sourcing this file changes nothing.
offline_apt_prepare() {
    mkdir -p "$WORK/lists/partial" "$WORK/archives/partial" "$WORK/sourceparts" "$WORK/log" "$WORK/cache" || return
    printf 'deb [trusted=yes] copy:%s/apt ./\n' "$POOL" > "$WORK/sources.list" || return
    chmod 755 "$WORK" "$WORK/lists" "$WORK/lists/partial" "$WORK/archives" "$WORK/archives/partial" || return
    cat > "$WORK/apt.conf" <<'APTCONF' || return
Dir::Etc::main "/dev/null";
Dir::Etc::parts "/dev/null";
APTCONF
    APT_OPTS=(-o "Dir::Etc::SourceList=$WORK/sources.list" -o "Dir::Etc::SourceParts=$WORK/sourceparts"
        -o "Dir::State::lists=$WORK/lists" -o "Dir::Cache::archives=$WORK/archives"
        -o "Dir::Log=$WORK/log" -o "Dir::Cache=$WORK/cache"
        -o "Dir::State::extended_states=$WORK/extended_states"
        -o Acquire::Retries=0 -o APT::Get::List-Cleanup=0)
    if [ "${#TARGETS[@]}" -gt 0 ]; then
        APT_CONFIG="$WORK/apt.conf" apt-get "${APT_OPTS[@]}" update -qq || return
        # Simulation performs no acquisition. --no-download here would reject
        # valid copy: packages before the temporary cache has been filled.
        APT_CONFIG="$WORK/apt.conf" apt-get "${APT_OPTS[@]}" --simulate --no-remove install --no-install-recommends "${TARGETS[@]}" || return
        # copy: materializes local archives; file: can leave the cache empty.
        APT_CONFIG="$WORK/apt.conf" apt-get "${APT_OPTS[@]}" --download-only --no-remove install -y --no-install-recommends "${TARGETS[@]}" || return
    fi
}

offline_apt_install() {
    if [ "${#TARGETS[@]}" -gt 0 ]; then
        APT_CONFIG="$WORK/apt.conf" DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" --no-download --no-remove install -y --no-install-recommends "${TARGETS[@]}"
    fi
}
