#!/bin/bash
# lib/prod-forge.sh — frg-2: the self-hosted forge (polari-forge/, Forgejo) as a `pol prod`
# stack service. Sourced by prod.sh (never run); every function expects load_answers to have
# run and SUITE / GEN / SCRIPT_DIR / the vault functions to exist.
#
# His rulings (CICD_PIPELINE_PLAN §12.3): the forge lives ON PRODUCTION as the default
# distribution point (GitHub secondary) and replaces the reprepro apt route; 512 MiB limit
# (measured: idle 94 MiB, peak 455 MiB while signing), repo indexer off; public posture
# (registration off, anonymous read, scoped tokens, hardening warn-only first);
# capability-not-content (the forge's data lives in the named volume polari_forge_data,
# nothing of it in any repo); re-measured on the droplet before it faces the web.
#
#   POL_PROD_FORGE=on|off        the answer (off for answer files written before it existed)
#   POL_PROD_FORGE_OWNER=<org>   the forge-side owner of the Debian registry apt.<D> maps onto
#                                (default dausume — the owner the pipeline's forgejo-* routes
#                                publish under: polari-jenkins/routes/destinations.sh dest_forge_owner)
#
# What it adds: names forge.<D> + apt.<D> (proxy blocks + certificate SANs); the stack service
# `forge` (compose profile "forge" in docker-compose.{lean,prod}.yml, image = THE pin read from
# polari-forge/compose/forge.yml, no published ports); the forge's five secrets generated ONCE
# into the vault section [forge]; app.ini rendered by polari-forge/scripts/render.sh into
# .generated/forge/ and seeded into the volume before `docker stack deploy`; the admin user and
# the admin token (→ vault forge ADMIN_TOKEN) after it; the re-measure gate; status + verify rows.

FORGE_VOL=polari_forge_data
FORGE_KEYS="SECRET_KEY INTERNAL_TOKEN JWT_SECRET LFS_JWT_SECRET ADMIN_PASSWORD"
FORGE_LIMIT_MIB=512

forge_on()        { [ "${POL_PROD_FORGE:-off}" = on ]; }
forge_owner()     { printf '%s' "${POL_PROD_FORGE_OWNER:-dausume}"; }
forge_dir()       { printf '%s' "$SUITE/polari-forge"; }
forge_gen()       { printf '%s' "$GEN/forge"; }
forge_image_pin() { awk '/^[[:space:]]*image:[[:space:]]*/{print $2; exit}' "$(forge_dir)/compose/forge.yml" 2>/dev/null; }
forge_service()   { printf '%s_forge' "$(stack_name)"; }

# name rows (prod.sh name_rows): the forge's two names, only when it is on
forge_name_rows() {
    forge_on || return 0
    printf 'forge.%s\tsubdomain\tthe forge (UI, API, git over https)\tforge = on\n' "$1"
    printf 'apt.%s\tsubdomain\tthe apt repository — served BY the forge\tforge = on\n' "$1"
}
forge_proxy_args() { forge_on && printf -- '--forge on --forge-owner %s' "$(forge_owner)"; return 0; }

# the env the polari-forge scripts need to act on THIS stack's forge (no secret in it)
forge_env() {
    local D="$POL_PROD_DOMAIN"
    printf '%s\n' "FORGE_DIR=$(forge_dir)" "FORGE_GEN=$(forge_gen)" "FORGE_STACK=$(stack_name)" "FORGE_VOLUME=$FORGE_VOL" \
        "FORGE_OWNER=$(forge_owner)" "FORGE_ROOT_URL=https://forge.$D/" "FORGE_DOMAIN=forge.$D" "FORGE_PROD=on" \
        "FORGE_STACK_FILES=$GEN/stack-$(role).yml"
}
forge_run() {  # forge_run <script> [args] — a polari-forge script against the stack service
    local s="$1"; shift; local e=(); mapfile -t e < <(forge_env)
    env "${e[@]}" bash "$(forge_dir)/scripts/$s.sh" "$@"
}

# ---------------------------------------------------------------- secrets → vault, app.ini
# The vault is the home of the five secrets ([forge] section). .generated/forge/forge.env (600)
# is re-assembled from it on every apply because render.sh reads that file — app.ini (600) holds
# the same values anyway. Generation is render.sh's (one generator): a first apply with an
# empty vault and no forge.env lets render.sh make all five, then they go to the vault ONCE.
declare -A _FORGE_V=()
forge_vault_read() {  # fills _FORGE_V from the vault (one read per key; '' when absent)
    local k; for k in $FORGE_KEYS ADMIN_TOKEN; do _FORGE_V[$k]="$(vault_get forge "$k" 2>/dev/null || true)"; done
}
forge_secrets_assemble() {  # file
    local f="$1" k v any=0 out=""
    for k in $FORGE_KEYS; do [ -n "${_FORGE_V[$k]:-}" ] && any=1; done
    [ "$any" = 0 ] && [ ! -s "$f" ] && return 0   # nothing anywhere: render.sh generates all five
    for k in $FORGE_KEYS; do
        v="${_FORGE_V[$k]:-}"
        [ -n "$v" ] || v="$(grep -s "^$k=" "$f" | tail -n1 | cut -d= -f2-)"
        # a hex secret missing from both (a partial vault): render.sh's own generator, repeated here —
        # its JWT pair needs no copy, render.sh regenerates an absent JWT line in the right shape
        case "$k" in SECRET_KEY|INTERNAL_TOKEN|ADMIN_PASSWORD) [ -n "$v" ] || v="$(openssl rand -hex 32)" ;; esac
        [ -n "$v" ] && out+="$k=$v"$'\n'
    done
    ( umask 077; printf '# polari-forge secrets — assembled from the vault [forge] by pol prod %s. NEVER commit, NEVER print.\n%s' "$(date -Is)" "$out" > "$f" )
    chmod 600 "$f"
}
forge_secrets_to_vault() {  # file → vault_put for every key the vault lacks or holds differently; prints the count
    local f="$1" k v n=0
    for k in $FORGE_KEYS; do
        v="$(grep -s "^$k=" "$f" | tail -n1 | cut -d= -f2-)"; [ -n "$v" ] || continue
        [ "$v" = "${_FORGE_V[$k]:-}" ] && continue
        if vault_put forge "$k" "$v" "the forge (forge.$POL_PROD_DOMAIN): $k" >/dev/null 2>&1; then n=$((n+1)); _FORGE_V[$k]="$v"
        else log_warn "forge: the vault refused $k — it stays in $f (mode 600) only"; fi
    done
    echo "$n"
}
write_configs_forge() {  # envfile — called by write_configs / write_configs_full after the env file is written
    forge_on || return 0
    local envf="$1" D="$POL_PROD_DOMAIN" fd fg pin n
    fd="$(forge_dir)"; fg="$(forge_gen)"
    [ -f "$fd/scripts/render.sh" ] || die "POL_PROD_FORGE=on but polari-forge is not checked out at $fd — git -C $SUITE submodule update --init polari-forge"
    pin="$(forge_image_pin)"; [ -n "$pin" ] || die "no image pin in $fd/compose/forge.yml"
    ( umask 077; mkdir -p "$fg" ); chmod 700 "$fg" 2>/dev/null || true
    forge_vault_read
    forge_secrets_assemble "$fg/forge.env"
    # app.ini for the production home: https://forge.<D>/ behind pol-proxy (PROTOCOL http on :3000 — the template's),
    # ssh not exposed this slice (DISABLE_SSH=true: no ssh clone URL advertised), the overlay as the trusted proxy range
    FORGE_DIR="$fd" FORGE_GEN="$fg" FORGE_ROOT_URL="https://forge.$D/" FORGE_DOMAIN="forge.$D" FORGE_SSH_DOMAIN="forge.$D" \
        FORGE_SSH_PORT=22 FORGE_DISABLE_SSH=true FORGE_TRUSTED_PROXIES=10.0.0.0/8 \
        bash "$fd/scripts/render.sh" >"$fg/render.log" 2>&1 || { cat "$fg/render.log" >&2; die "forge: app.ini render failed"; }
    n="$(forge_secrets_to_vault "$fg/forge.env")"
    [ "$n" -gt 0 ] && log_success "forge: $n secret(s) generated into the vault [forge] (sudo pol security vault show)" || log_info "forge: secrets kept (vault [forge])"
    printf '# ---- the forge (POL_PROD_FORGE=on, frg-2): THE pin, read from polari-forge/compose/forge.yml at render time ----\nPOLARI_FORGE_IMAGE=%s\n' "$pin" >> "$envf"
    log_success "forge: app.ini rendered for https://forge.$D/ (ssh off, behind pol-proxy) → $fg/app.ini (600)"
}

# ---------------------------------------------------------------- the volume seed (before docker stack deploy)
# app.ini is NOT mounted (polari-forge/compose/forge.yml explains why): it is COPIED into the volume,
# owned by USER_UID, mode 600 — here by a one-shot container of the pinned image. Idempotent: an
# unchanged file is not copied. FORGE_SEEDED=1 tells deploy_stack to roll a running task onto it.
FORGE_SEEDED=0
forge_seed_volume() {
    forge_on || return 0
    local fg pin want have uid gid
    fg="$(forge_gen)"; pin="$(forge_image_pin)"
    [ -s "$fg/app.ini" ] && [ -s "$fg/container.env" ] || die "forge on but nothing rendered in $fg — pol prod render"
    uid="$(sed -n 's/^USER_UID=//p' "$fg/container.env")"; gid="$(sed -n 's/^USER_GID=//p' "$fg/container.env")"
    docker image inspect "$pin" >/dev/null 2>&1 || { log_info "forge: pulling $pin"; docker pull -q "$pin" >/dev/null || die "forge: could not pull $pin"; }
    want="$(sha256sum "$fg/app.ini" | cut -d' ' -f1)"
    have="$(docker run --rm -v "$FORGE_VOL:/data" --entrypoint sh "$pin" -c 'sha256sum /data/gitea/conf/app.ini 2>/dev/null' 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
        FORGE_SEEDED=0; log_info "forge: app.ini in $FORGE_VOL is the rendered one — no copy"
        return 0
    fi
    # the file travels on stdin (it carries the secrets) — never argv
    docker run --rm -i -v "$FORGE_VOL:/data" --entrypoint sh "$pin" -c \
        'set -e; mkdir -p /data/gitea/conf; cat > /data/gitea/conf/app.ini; chown "$1:$2" /data/gitea /data/gitea/conf /data/gitea/conf/app.ini; chmod 600 /data/gitea/conf/app.ini' \
        sh "${uid:-1000}" "${gid:-1000}" < "$fg/app.ini" >/dev/null || die "forge: could not seed app.ini into $FORGE_VOL"
    FORGE_SEEDED=1; log_success "forge: app.ini seeded into $FORGE_VOL (owner $uid, mode 600)"
}

# ---------------------------------------------------------------- after deploy: admin, token, re-measure
forge_after_deploy() {
    forge_on || return 0
    local fg tok; fg="$(forge_gen)"
    log_info "forge: waiting for the task to answer (first start: the image pulls, the database is made)…"
    if ! FORGE_WAIT_S="${FORGE_WAIT_S:-240}" FORGE_PASSWORD_WHERE="the vault (forge ADMIN_PASSWORD)" forge_run ready; then
        log_warn "forge: not answering yet — the admin user, the token and the re-measure follow on the next pol prod apply (pol prod status)"
        return 0
    fi
    # the admin token: the vault's, kept while valid; else minted (into the file) and moved to the vault
    [ -n "${_FORGE_V[ADMIN_TOKEN]+x}" ] || forge_vault_read
    tok="${_FORGE_V[ADMIN_TOKEN]:-}"
    FORGE_TOKEN="$tok" forge_run token --quiet >/dev/null || log_warn "forge: no admin token (pol forge token)"
    if [ -s "$fg/token" ]; then
        if vault_put forge ADMIN_TOKEN "$(cat "$fg/token")" "the forge's admin API token (forge.$POL_PROD_DOMAIN)" >/dev/null 2>&1; then
            _FORGE_V[ADMIN_TOKEN]="$(cat "$fg/token")"; shred -u "$fg/token" 2>/dev/null || rm -f "$fg/token"
            log_success "forge: admin token minted into the vault (forge ADMIN_TOKEN)"
        else log_warn "forge: the vault refused the admin token — it stays in $fg/token (mode 600)"; fi
    else
        log_success "forge: admin token in the vault is valid — kept"
    fi
    forge_regate
}
# THE RE-MEASURE GATE (his ruling: re-measure on the droplet before it faces the web): the meter's
# line (appended to .generated/forge/meter.jsonl by the meter itself) + one verdict against the VM's
# available memory (free -m): WARN below 2 × the forge's 512 MiB limit.
forge_regate() {
    local line avail
    line="$(FORGE_TOKEN="${_FORGE_V[ADMIN_TOKEN]:-}" forge_run meter --json 2>/dev/null | tail -n1)"
    [ -n "$line" ] && echo "  forge meter  $line" || log_warn "forge: the meter gave no reading (pol forge meter)"
    avail="$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')"
    forge_verdict "${avail:-0}" "$line"
}
forge_verdict() {  # avail_mib meter_line → one line, WARN|OK (exit 0 always: a gate that informs, warn-only first)
    local avail="$1" line="${2:-}" need=$((2 * FORGE_LIMIT_MIB)) rss peak
    rss="$(printf '%s' "$line" | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(d.get("rss_mib") if d.get("rss_mib") is not None else "?", d.get("peak_mib") if d.get("peak_mib") is not None else "?")
except Exception: print("? ?")' 2>/dev/null)"; peak="${rss#* }"; rss="${rss%% *}"
    if [ "${avail:-0}" -lt "$need" ]; then
        log_warn "re-measure: WARN — ${avail} MiB available (free -m) < 2 × the forge's ${FORGE_LIMIT_MIB} MiB limit (${need} MiB); forge rss ${rss:-?} MiB, peak ${peak:-?} MiB — keep it off the web until there is headroom (a bigger VM, or POL_PROD_FORGE=off)"
    else
        log_success "re-measure: OK — ${avail} MiB available (free -m) ≥ 2 × the forge's ${FORGE_LIMIT_MIB} MiB limit; forge rss ${rss:-?} MiB, peak ${peak:-?} MiB"
    fi
    return 0
}

# ---------------------------------------------------------------- status + verify
forge_status_rows() {
    forge_on || return 0
    local D="$POL_PROD_DOMAIN" reps info key
    reps="$(docker service ls --filter "name=$(forge_service)" --format '{{.Replicas}}' 2>/dev/null | head -n1)"
    [ -n "${_FORGE_V[ADMIN_TOKEN]+x}" ] || _FORGE_V[ADMIN_TOKEN]="$(vault_get forge ADMIN_TOKEN 2>/dev/null || true)"
    # version + held repos through the task (no published port): the API's cheap path, not the meter's du
    info="$(FORGE_TOKEN="${_FORGE_V[ADMIN_TOKEN]:-}" forge_run_inline 'api GET /api/v1/version; v="$(printf "%s" "$API_BODY" | jget version)"; h=0; p=1
        while [ "$p" -le 50 ]; do api GET "/api/v1/orgs/$FORGE_OWNER/repos?limit=50&page=$p"; [ "$API_CODE" = 200 ] || break
            read -r c m <<<"$(printf "%s" "$API_BODY" | python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(len(d), sum(1 for r in d if r.get(\"mirror\")))")"; [ "${c:-0}" -gt 0 ] || break; h=$((h+m)); p=$((p+1)); done
        echo "Forgejo ${v:-?} · held $h repos"' 2>/dev/null || true)"
    key="$(curl -sk --max-time 5 --resolve "apt.$D:443:127.0.0.1" "https://apt.$D/repository.key" 2>/dev/null | head -n1)"
    case "$key" in *"BEGIN PGP PUBLIC KEY BLOCK"*) key="repository.key answers (PGP block)" ;; "") key="repository.key: no answer" ;; *) key="repository.key: not a PGP block ($(printf '%s' "$key" | cut -c1-40))" ;; esac
    echo "  forge        ${reps:-not deployed}  ${info:-not answering}  ·  apt.$D: $key"
}
forge_run_inline() {  # forge_run_inline '<bash using _lib.sh>' — a few API calls against the stack service
    local e=(); mapfile -t e < <(forge_env)
    env "${e[@]}" bash -c "source '$(forge_dir)/scripts/_lib.sh'; $1"
}
# pol prod verify: two checks when the forge is on. An empty registry is not a failure: Release is 404
# until the first upload — reported as "empty — publish first". Uses do_verify's ok/bad and $k.
forge_verify_checks() {
    forge_on || return 0
    local D="$POL_PROD_DOMAIN" c v out
    out="$(curl -s ${k:-} -w '\n%{http_code}' --max-time 15 "https://forge.$D/api/v1/version" 2>/dev/null)" || true
    c="${out##*$'\n'}"; v="${out%$'\n'*}"
    [ "$c" = 200 ] && ok "forge: https://forge.$D/api/v1/version 200 ($(printf '%s' "$v" | python3 -c 'import json,sys
try: print("Forgejo", json.load(sys.stdin).get("version","?"))
except Exception: print("?")' 2>/dev/null))" || bad "forge: https://forge.$D/api/v1/version answered ${c:-nothing} (pol prod status; pol forge status)"
    c="$(curl -s ${k:-} -o /dev/null -w '%{http_code}' --max-time 15 "https://apt.$D/dists/stable/Release" 2>/dev/null)"
    case "$c" in
        200) ok "apt: https://apt.$D/dists/stable/Release 200 (the forge's Debian registry, owner $(forge_owner))" ;;
        404) log_warn "apt: https://apt.$D/dists/stable/Release 404 — empty — publish first (the forge's registry has no package for owner $(forge_owner) yet; not a failure)" ;;
        *)   bad "apt: https://apt.$D/dists/stable/Release answered ${c:-nothing}" ;;
    esac
}
forge_plan_line() {
    forge_on || { echo "  forge        off   (POL_PROD_FORGE=on hosts git mirrors, releases and the apt repository here)"; return 0; }
    local pin; pin="$(forge_image_pin)"
    echo "  forge        on — forge.$POL_PROD_DOMAIN + apt.$POL_PROD_DOMAIN (→ /api/packages/$(forge_owner)/debian) · service forge ($(printf '%s' "$pin" | sed -E 's/@sha256:(.{12}).*/@sha256:\1…/'))"
    echo "               volume $FORGE_VOL · limit ${FORGE_LIMIT_MIB}M · no published port (pol-proxy → forge:3000) · ssh NOT exposed (https only) · secrets in the vault [forge]"
}
