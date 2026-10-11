#!/usr/bin/env bash
# export-publish.sh — upload a built deb to the backend's firmware
# export store (ucd-app). Sourced by `pol apps shell --publish` and
# `pol shell dist --publish`.
#
#   export_publish <file> <form> [solution]
#     form: bridge-app-deb (the per-app launcher) | shell-core-deb
#           (the jpackage runtime). solution defaults to uno-light.
#
# CONTRACT: POST $POLARI_API/api/firmware/exports/upload, multipart
# fields solution, form, sha256 (of the file), file. Reply
# {ok, export:{name, form, download_url, tar_sha256}}. A 404 means the
# door is not deployed yet: say so and return 1. Only the file and
# those fields are sent — no hostname, user or path.
export_publish() {
    local file="${1:?file}" form="${2:?form}" solution="${3:-uno-light}"
    local api="${POLARI_API:-${POLARI_CORE_URL:-https://api.prf.$(lan_ip).nip.io}}"
    api="${api%/}"
    [ -f "$file" ] || { echo "publish: no such file: $file" >&2; return 1; }
    case "$form" in bridge-app-deb|shell-core-deb) ;; *)
        echo "publish: form must be bridge-app-deb|shell-core-deb" >&2; return 1 ;; esac
    local sha body code tok=""
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    if declare -F bearer >/dev/null 2>&1; then tok=$(bearer 2>/dev/null || true); fi
    body=$(mktemp)
    code=$(curl -sk -o "$body" -w '%{http_code}' -X POST \
        ${tok:+-H "Authorization: Bearer $tok"} \
        -F "solution=$solution" -F "form=$form" -F "sha256=$sha" \
        -F "file=@$file" "$api/api/firmware/exports/upload") || code=000
    if [ "$code" = "404" ]; then
        rm -f "$body"
        echo "publish: $api/api/firmware/exports/upload answered 404 - the upload door is not deployed on that backend yet. Nothing was sent." >&2
        return 1
    fi
    python3 - "$body" "$code" "$sha" <<'PYEOF' || { rm -f "$body"; return 1; }
import json, sys
path, code, sha = sys.argv[1:4]
try:
    d = json.load(open(path))
except Exception:
    sys.exit('publish: HTTP %s, reply was not JSON' % code)
if not d.get('ok'):
    sys.exit('publish: refused (HTTP %s): %s' % (code, d.get('error', d)))
e = d.get('export') or {}
print('published %s (%s) sha256 %s' % (e.get('name', '?'), e.get('form', '?'), sha))
print('download_url: %s' % e.get('download_url', '?'))
PYEOF
    rm -f "$body"
}
