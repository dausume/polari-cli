#!/usr/bin/env bash
# pol shell — the Polari App Store's native shell (appstore-1 /
# shell-1). Builds the polari-app-shell Gradle repo (suite-level
# project, sibling of prf/psc), publishes artifacts into the store
# (MinIO + ShellArtifact row), and mints enrollment deep links.
# Deploying/serving stays the store module's job — this is the
# developer/operator seam only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

SHELL_REPO="$POL_SUITE_ROOT/polari-app-shell"
API_BASE="${POLARI_CORE_URL:-https://api.prf.$(lan_ip).nip.io}"
KC_ENV="$POL_SUITE_ROOT/polari-rf-node/prf-keycloak/prf-keycloak-admin.env"

usage() {
    pol_box "pol shell — native app shells (App Store)"
    echo -e "
  ${CYAN}catalog${NC}               what the store on this instance offers
  ${CYAN}identity${NC}              the instance's shell-probe identity payload
  ${CYAN}build${NC}                 ./gradlew build + srcDistTar (the archive
                        gradle-project downloads overlay)
  ${CYAN}dist${NC}                  installDist + jpackage .deb (linux x64)
  ${CYAN}publish <platform> <version>${NC}
                        upload the built artifact for gradle-project |
                        desktop-linux-x64 and commit its ShellArtifact
                        row (uses the backend service account)
  ${CYAN}enroll <shell> [ttl-s]${NC} mint a one-time enrollment token; prints
                        the polari:// deep link (QR payload = same string)

Backend: \$POLARI_CORE_URL (default: this host's nip.io API).
The shell repo is expected at $SHELL_REPO."
}

require_repo() {
    [ -d "$SHELL_REPO" ] || die "polari-app-shell not found at $SHELL_REPO"
}

# Service-account bearer (the machine path; a browser user can do all
# of this from the store page instead).
bearer() {
    [ -f "$KC_ENV" ] || die "no $KC_ENV — run pol security setup / staging-setup first"
    local secret kc_host
    secret=$(grep '^KEYCLOAK_POLARI_BACKEND_CLIENT_SECRET' "$KC_ENV" | cut -d= -f2)
    kc_host="${API_BASE/api.prf./auth.prf.}"
    # The auth vhost lives beside the api vhost on the same proxy.
    kc_host="${kc_host/api./auth.}"
    curl -sk -X POST "$kc_host/realms/Polari/protocol/openid-connect/token" \
        -d "grant_type=client_credentials&client_id=polari-backend&client_secret=$secret" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("access_token") or exit("no token: " + json.dumps(d)))'
}

pretty() {
    python3 -c "
import json, sys
d = json.load(sys.stdin)
$1"
}

CMD=${1:-help}; shift || true
case "$CMD" in
    catalog)
        curl -sk "$API_BASE/api/appstore" | pretty "
if not d.get('ok'): exit(json.dumps(d))
for s in d['shells']:
    plats = ', '.join(f\"{k}{'' if v['available'] else ' (unavailable)'}\" for k, v in s['platforms'].items())
    print(f\"{s['name']} [{s['scope']}] — {plats}\")
print(f\"apps covered: {sum(1 for a in d['apps'] if a['installable'])}/{len(d['apps'])}\")" ;;
    identity)
        curl -sk "$API_BASE/api/appstore/identity" | python3 -m json.tool ;;
    build)
        require_repo
        (cd "$SHELL_REPO" && ./gradlew build srcDistTar)
        log_success "archive: $SHELL_REPO/build/dist/polari-app-shell-src.tar.gz" ;;
    dist)
        require_repo
        (cd "$SHELL_REPO" && ./gradlew :desktop:installDist)
        (cd "$SHELL_REPO" && jpackage --type deb --name polari-shell \
            --app-version "${POLARI_SHELL_VERSION:-0.1.0}" --vendor Polari \
            --description "Polari app shell" \
            --input desktop/build/install/desktop/lib \
            --main-jar desktop.jar \
            --main-class org.polari.shell.desktop.DesktopMain \
            --java-options "-DGDK_BACKEND=x11" --dest build/dist)
        log_success "deb: $(ls "$SHELL_REPO"/build/dist/*.deb | tail -1)" ;;
    publish)
        require_repo
        PLATFORM=${1:?platform required (gradle-project|desktop-linux-x64)}
        VERSION=${2:?version required}
        case "$PLATFORM" in
            gradle-project)
                FILE="$SHELL_REPO/build/dist/polari-app-shell-src.tar.gz"
                KEY="polari-instance-shell/gradle-project/$VERSION.tar.gz" ;;
            desktop-linux-x64)
                FILE=$(ls "$SHELL_REPO"/build/dist/*.deb 2>/dev/null | tail -1)
                KEY="polari-instance-shell/desktop-linux-x64/$(basename "$FILE")" ;;
            android)
                FILE="$SHELL_REPO/android/build/outputs/apk/phone/debug/android-phone-debug.apk"
                KEY="polari-instance-shell/android/polari-shell_${VERSION}_phone.apk" ;;
            android-vr)
                # Quest 2 / Vive: same APK family; renders through
                # Wolvic (required) — sideload with adb install.
                FILE="$SHELL_REPO/android/build/outputs/apk/vr/debug/android-vr-debug.apk"
                KEY="polari-instance-shell/android-vr/polari-shell_${VERSION}_vr.apk" ;;
            *) die "unknown platform '$PLATFORM'" ;;
        esac
        [ -f "$FILE" ] || die "no artifact at $FILE — run pol shell build/dist first"
        FC=$(docker ps --filter name=prf-file-store --format '{{.Names}}' | head -1)
        [ -n "$FC" ] || die "prf-file-store container not running"
        # mc inside the container: presigned host-rewrites break SigV4.
        docker cp "$FILE" "$FC":/tmp/pol-shell-artifact
        docker exec "$FC" sh -c 'U=$(cat "$MINIO_ROOT_USER_FILE" 2>/dev/null || printenv MINIO_ROOT_USER); P=$(cat "$MINIO_ROOT_PASSWORD_FILE" 2>/dev/null || printenv MINIO_ROOT_PASSWORD); mc alias set local http://localhost:9000 "$U" "$P" >/dev/null 2>&1; mc mb --ignore-existing local/shell-artifacts >/dev/null; mc cp -q /tmp/pol-shell-artifact "local/shell-artifacts/'"$KEY"'" >/dev/null && rm /tmp/pol-shell-artifact'
        SHA=$(sha256sum "$FILE" | cut -d' ' -f1)
        TOK=$(bearer)
        curl -sk -X POST "$API_BASE/api/appstore/artifacts" \
            -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
            -d "{\"action\":\"commit\",\"shellName\":\"polari-instance-shell\",\"platform\":\"$PLATFORM\",\"version\":\"$VERSION\",\"objectKey\":\"$KEY\",\"sha256\":\"$SHA\"}" \
            | pretty "
if not d.get('ok'): exit(json.dumps(d))
print(f\"published {d['artifact']} ({d['sizeBytes']} bytes)\")" ;;
    enroll)
        SHELL_NAME=${1:?shell name required (see pol shell catalog)}
        TTL=${2:-900}
        TOK=$(bearer)
        curl -sk -X POST "$API_BASE/api/appstore/$SHELL_NAME/enroll" \
            -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
            -d "{\"ttlSeconds\": $TTL, \"deviceLabel\": \"pol-cli\"}" \
            | pretty "
if not d.get('ok'): exit(json.dumps(d))
print('token (single-use, shown ONCE):', d['token'])
print('expires:', d['expiresAt'])
print('deep link / QR payload:')
print(' ', d['deepLink'])" ;;
    help|*) usage ;;
esac
