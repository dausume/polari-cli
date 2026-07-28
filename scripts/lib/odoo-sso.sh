# pol odoo sso-setup — Keycloak OIDC for HUMANS (ODOO_INTEGRATION_PLAN
# od-2). Sourced by odoo.sh; uses its compose_cmd/odoo_exec/base_domain.
#
# Idempotent, never hand-clicked: ensures the confidential client
# 'odoo' in realm Polari (redirect = https://odoo.<domain>/auth_oauth/
# signin — the OCA auth_oidc addon reuses the auth_oauth route), then
# installs auth_oidc and upserts the auth.oauth.provider row in each
# existing odoo_% database. The client secret flows KC -> odoo DB in
# one pass and is never written to a file.

# Ensure the KC client and print "SECRET=<value>" as the last line.
# Runs INSIDE the pol-keycloak container (admin API is in-network only;
# curl+jq exist there — configure_clients.sh precedent).
_odoo_kc_ensure_client() {
    local base_domain="$1"
    # -i: the script arrives on stdin — without it bash -s gets EOF
    docker exec -i -e ODOO_BASE_DOMAIN="$base_domain" pol-keycloak bash -s <<'KCEOF'
set -e
KC="http://localhost:8080"
TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${KEYCLOAK_ADMIN:-admin}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD:-admin}" \
    -d "grant_type=password" -d "client_id=admin-cli" | jq -r '.access_token')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "ERROR: no admin token" >&2; exit 1; }
AUTH="Authorization: Bearer $TOKEN"

curl -sf -H "$AUTH" "$KC/admin/realms/Polari" >/dev/null \
    || { echo "ERROR: realm Polari not found" >&2; exit 1; }

DESIRED=$(cat <<JSON
{
  "clientId": "odoo",
  "name": "Odoo ERP (business sims + real ops)",
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": true,
  "redirectUris": ["https://odoo.${ODOO_BASE_DOMAIN}/auth_oauth/signin"],
  "webOrigins": ["https://odoo.${ODOO_BASE_DOMAIN}"],
  "attributes": {"post.logout.redirect.uris": "https://odoo.${ODOO_BASE_DOMAIN}/*"}
}
JSON
)
UUID=$(curl -s -H "$AUTH" "$KC/admin/realms/Polari/clients?clientId=odoo" | jq -r '.[0].id // empty')
if [ -z "$UUID" ]; then
    curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
        -d "$DESIRED" "$KC/admin/realms/Polari/clients"
    UUID=$(curl -s -H "$AUTH" "$KC/admin/realms/Polari/clients?clientId=odoo" | jq -r '.[0].id')
    echo "created KC client 'odoo' ($UUID)" >&2
else
    curl -sf -X PUT -H "$AUTH" -H "Content-Type: application/json" \
        -d "$DESIRED" "$KC/admin/realms/Polari/clients/$UUID"
    echo "updated KC client 'odoo' ($UUID)" >&2
fi
SECRET=$(curl -s -H "$AUTH" "$KC/admin/realms/Polari/clients/$UUID/client-secret" | jq -r '.value // empty')
if [ -z "$SECRET" ]; then
    curl -sf -X POST -H "$AUTH" "$KC/admin/realms/Polari/clients/$UUID/client-secret" >/dev/null
    SECRET=$(curl -s -H "$AUTH" "$KC/admin/realms/Polari/clients/$UUID/client-secret" | jq -r '.value')
fi
echo "SECRET=$SECRET"
KCEOF
}

# Upsert the auth.oauth.provider row in one database. Endpoints follow
# the PRF-backend pattern: browser-facing = public https URL, server-
# to-server (token/jwks/userinfo) = in-network http://pol-keycloak:8080
# (the odoo container has neither the /etc/hosts names nor the CA).
_odoo_provider_upsert() {
    # odoo shell exits 0 even when the python raises — grep the
    # UPSERT-OK marker instead of trusting the exit code.
    local db="$1" base_domain="$2" secret="$3" out
    out=$($(compose_cmd) exec -T \
        -e SSO_DB="$db" -e SSO_BASE="$base_domain" -e SSO_SECRET="$secret" \
        odoo sh -c 'odoo shell --no-http -d "$SSO_DB" --db_host "$HOST" --db_port "$PORT" --db_user "$USER" --db_password "$PASSWORD"' <<'PYEOF' 2>&1
import os
base = os.environ['SSO_BASE']
pub = f'https://auth.{base}/realms/Polari/protocol/openid-connect'
internal = 'http://pol-keycloak:8080/realms/Polari/protocol/openid-connect'
vals = {
    'name': 'Keycloak (Polari)',
    'flow': 'id_token_code',
    'client_id': 'odoo',
    'client_secret': os.environ['SSO_SECRET'],
    'auth_endpoint': f'{pub}/auth',
    'token_endpoint': f'{internal}/token',
    'jwks_uri': f'{internal}/certs',
    'validation_endpoint': f'{internal}/userinfo',
    'end_session_endpoint': f'{pub}/logout',
    'scope': 'openid email profile',
    'body': 'Log in with Polari SSO',
    'enabled': True,
}
Provider = env['auth.oauth.provider'].sudo()
row = Provider.search([('name', '=', 'Keycloak (Polari)')], limit=1)
if row:
    row.write(vals)
else:
    row = Provider.create(vals)
env.cr.commit()
print('UPSERT-OK', row.id)
PYEOF
)
    printf '%s\n' "$out" | grep -q 'UPSERT-OK' \
        || { printf '%s\n' "$out" | tail -15 >&2; return 1; }
}

odoo_sso_setup() {
    local base_domain="$1"
    docker ps --format '{{.Names}}' | grep -qx pol-keycloak \
        || die "pol-keycloak is not running — SSO setup needs the suite Keycloak (e.g. 'pol suite up', or bring up pol-mariadb + pol-keycloak)"

    log_info "Ensuring KC client 'odoo' in realm Polari (redirect: https://odoo.$base_domain/auth_oauth/signin)"
    local kc_out secret
    kc_out=$(_odoo_kc_ensure_client "$base_domain") || die "Keycloak client setup failed"
    secret=$(printf '%s\n' "$kc_out" | grep '^SECRET=' | cut -d= -f2-)
    [ -n "$secret" ] || die "no client secret returned from Keycloak"

    local dbs db
    dbs=$(odoo_exec odoo-postgres 'psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT datname FROM pg_database WHERE datname LIKE '"'"'odoo_%'"'"' ORDER BY datname"')
    [ -n "$dbs" ] || die "no odoo_% databases yet — run 'pol odoo init-db sim' first"
    for db in $dbs; do
        log_info "[$db] installing auth_oidc (idempotent)"
        odoo_exec odoo 'odoo --no-http --stop-after-init -d '"$db"' -i auth_oidc --db_host "$HOST" --db_port "$PORT" --db_user "$USER" --db_password "$PASSWORD"' >/dev/null 2>&1 \
            || die "[$db] auth_oidc install failed"
        log_info "[$db] upserting auth.oauth.provider 'Keycloak (Polari)'"
        _odoo_provider_upsert "$db" "$base_domain" "$secret" \
            || die "[$db] provider upsert failed"
    done
    log_success "SSO configured for: $(echo $dbs | tr '\n' ' ')"
    echo "  login buttons: https://odoo.$base_domain/web/login?db=<db> -> 'Log in with Polari SSO'"
    log_warn "v1 honest gaps: KC-role -> Odoo-group mapping is MANUAL (new SSO logins follow Odoo signup rules); browser round-trip needs pol-proxy serving odoo.$base_domain"
}
