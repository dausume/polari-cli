#!/bin/bash
# prod-sources.sh — THE REGISTERED LOCATIONS a production device updates from (dep-3, his ruling 2026-09-27:
# "a list, not a hard-coded host"). Sourced by prod-update.sh (`pol prod sources`, `pol prod update`).
#
#   .generated/prod-sources.env    one   SOURCE=<kind>:<where>   line per location, in the order they are asked
#       SOURCE=github:dausume/polari-suite                 GitHub Releases (api.github.com)
#       SOURCE=forge:https://forge.example/dausume/polari-suite   a self-hosted Forgejo/Gitea (its /api/v1)
#   absent = the official list (providers.sh official_release_locations): THE FORGE FIRST (production's default,
#   self-sustaining; POL_FORGE_URL), GitHub second (online availability) — so a fresh device needs no setup, and a
#   forge that does not answer falls through to GitHub with a "no answer … (next location)" line.
#
#   prod_sources                       → kind<TAB>api-base<TAB>owner/repo   one per registered location
#   pu_release_newest <k> <b> <r>      → tag<TAB>release.json-url  of the newest polari-v release carrying release.json
#   pu_release_at <k> <b> <r> <tag>    → the same for one tag ('' when that location has no such release)
# Every read is unauthenticated (public releases). Needs providers.sh sourced first.

PU_SOURCES_FILE="${PU_SOURCES_FILE:-$POL_SUITE_ROOT/.generated/prod-sources.env}"

pu_source_row() {  # SOURCE value → kind<TAB>base<TAB>owner/repo
    local u repo
    case "$1" in
        github:*) printf 'github\thttps://api.github.com\t%s\n' "${1#github:}" ;;
        forge:*)  u="${1#forge:}"; u="${u%/}"; repo="$(printf '%s' "$u" | awk -F/ '{print $(NF-1) "/" $NF}')"
                  printf 'forge\t%s\t%s\n' "${u%/"$repo"}" "$repo" ;;
    esac
}
pu_source_entries() {  # the SOURCE values, registered or default
    if [ -s "$PU_SOURCES_FILE" ]; then sed -n 's/^SOURCE=//p' "$PU_SOURCES_FILE"
    else official_release_locations; fi
}
prod_sources() { pu_source_entries | while read -r s; do [ -n "$s" ] && pu_source_row "$s"; done; }

pu_source_value() {  # what a person typed → a SOURCE value ('' = not a location)
    case "$1" in
        http://*/*/*|https://*/*/*) printf 'forge:%s\n' "${1%/}" ;;
        github:*|forge:*) printf '%s\n' "$1" ;;
        *) printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' && printf 'github:%s\n' "$1" ;;
    esac
}

pu_sources() {  # pol prod sources [list|add <x>|remove <x>]
    set +e
    local verb="${1:-list}" v cur n=0
    case "$verb" in
        list)
            [ -s "$PU_SOURCES_FILE" ] && echo "registered locations ($PU_SOURCES_FILE), asked in this order:" \
                                      || echo "registered locations: the official default (nothing registered in $PU_SOURCES_FILE yet):"
            prod_sources | while IFS=$'\t' read -r k b r; do n=$((n + 1)); printf '  %d. %-6s %-40s %s\n' "$n" "$k" "$r" "$b"; done ;;
        add)
            v="$(pu_source_value "${2:-}")"; [ -n "$v" ] || { echo "usage: pol prod sources add <owner/repo> | <https://forge-host/owner/repo>"; return 2; }
            cur="$(pu_source_entries)"
            printf '%s\n' "$cur" | grep -qxF "$v" && { echo "already registered: $v"; return 0; }
            mkdir -p "$(dirname "$PU_SOURCES_FILE")"
            { echo "# pol prod sources — the locations pol prod update reads releases from, in order"; printf '%s\n' "$cur" "$v" | sed '/^$/d; s/^/SOURCE=/'; } > "$PU_SOURCES_FILE"
            echo "registered: $v"; pu_sources list ;;
        remove|rm)
            v="$(pu_source_value "${2:-}")"; [ -n "$v" ] || { echo "usage: pol prod sources remove <owner/repo> | <https://forge-host/owner/repo>"; return 2; }
            cur="$(pu_source_entries)"
            printf '%s\n' "$cur" | grep -qxF "$v" || { echo "not registered: $v"; pu_sources list; return 1; }
            [ "$(printf '%s\n' "$cur" | grep -vxF "$v" | grep -c .)" -gt 0 ] || { echo "refused: $v is the only registered location — add another first (a device must know where releases come from)"; return 1; }
            { echo "# pol prod sources — the locations pol prod update reads releases from, in order"; printf '%s\n' "$cur" | grep -vxF "$v" | sed 's/^/SOURCE=/'; } > "$PU_SOURCES_FILE"
            echo "removed: $v"; pu_sources list ;;
        *) echo "usage: pol prod sources [list|add <owner/repo>|remove <owner/repo>]"; return 2 ;;
    esac
}

# ---- reading releases (GitHub and Forgejo/Gitea return the same shape: tag_name, draft, assets[].browser_download_url)
pu_api_url() {  # kind base repo path → URL
    case "$1" in github) echo "$2/repos/$3/$4" ;; forge) echo "$2/api/v1/repos/$3/$4" ;; esac
}
pu_release_pick() {  # stdin: a release or a list of releases → tag<TAB>url of the newest polari-v release with release.json
    python3 -c '
import sys, json, re
try: d = json.load(sys.stdin)
except Exception: d = []
rels = d if isinstance(d, list) else [d]
def key(t):
    m = re.match(r"^polari-v(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?$", t or "")
    return tuple(int(x or 0) for x in m.groups()) if m else None
best = None
for r in rels:
    if not isinstance(r, dict) or r.get("draft"): continue
    k = key(r.get("tag_name"))
    url = next((a.get("browser_download_url") for a in r.get("assets") or [] if a.get("name") == "release.json"), None)
    if k and url and (best is None or k > best[0]): best = (k, r["tag_name"], url)
if best: print("%s\t%s" % (best[1], best[2]))'
}
pu_release_newest() {
    local lim; [ "$1" = forge ] && lim="releases?limit=15" || lim="releases?per_page=15"
    curl -fsSL --max-time 15 -H 'Accept: application/json' "$(pu_api_url "$1" "$2" "$3" "$lim")" 2>/dev/null | pu_release_pick
}
pu_release_at() {
    curl -fsSL --max-time 15 -H 'Accept: application/json' "$(pu_api_url "$1" "$2" "$3" "releases/tags/$4")" 2>/dev/null | pu_release_pick
}
