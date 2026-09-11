#!/bin/bash
# providers.sh — the external providers a Polari deployment can lean on, one
# block each: what it is used for, and the pages an operator has to visit.
# Sourced by prod.sh (`pol prod providers`). Adding a provider = one block
# here. Nothing here is a credential; credentials are the vault's business
# (PRODUCTION_DEPLOY_PLAN §16) and are stashed there only by the operator's
# choice (all / some / none).
#
#   provider_title <id>          → human name
#   provider_links <id>          → lines "label<TAB>url"
#   provider_roles <id>          → the roles it can fill (hosting dns certificate registry registrar)
#   provider_credential <id>     → what credential it involves, if any (for the stash question)

provider_title() {
    case "$1" in
        digitalocean) echo "DigitalOcean" ;;
        letsencrypt)  echo "Let's Encrypt" ;;
        suite-ca)     echo "the suite's own certificate authority (local, no provider)" ;;
        github)       echo "GitHub (repositories + container registry ghcr.io)" ;;
        cloudflare)   echo "Cloudflare (DNS)" ;;
        registrar)    echo "your domain registrar" ;;
        local-build)  echo "this machine (images built from the checkout, no registry)" ;;
        *) echo "$1" ;;
    esac
}
provider_roles() {
    case "$1" in
        digitalocean) echo "hosting dns" ;;
        letsencrypt)  echo "certificate" ;;
        suite-ca)     echo "certificate" ;;
        github)       echo "registry code" ;;
        cloudflare)   echo "dns" ;;
        registrar)    echo "registrar dns" ;;
        local-build)  echo "registry" ;;
    esac
}
provider_credential() {
    case "$1" in
        digitalocean) echo "API token (only for the DNS challenge; the console login is yours, never asked for)" ;;
        letsencrypt)  echo "none — the ACME account key is generated on the server (ca/ or /etc/letsencrypt); the contact e-mail is not a secret" ;;
        github)       echo "a token with read:packages to PULL private images; nothing for public images" ;;
        cloudflare)   echo "API token scoped to the zone (only if the DNS challenge is moved to Cloudflare)" ;;
        registrar)    echo "your registrar login — set the DNS records yourself; never give it to the server" ;;
        *) echo "none" ;;
    esac
}
provider_links() {
    case "$1" in
        digitalocean)
            printf 'console\thttps://cloud.digitalocean.com/\n'
            printf 'droplets (rebuild / resize / console access)\thttps://cloud.digitalocean.com/droplets\n'
            printf 'reserved IPs (attach one BEFORE setting DNS so a rebuilt droplet keeps its address)\thttps://cloud.digitalocean.com/networking/reserved_ips\n'
            printf 'DNS (only if the domain is delegated to DigitalOcean nameservers)\thttps://cloud.digitalocean.com/networking/domains\n'
            printf 'cloud firewalls (allow inbound 22, 80, 443)\thttps://cloud.digitalocean.com/networking/firewalls\n'
            printf 'API tokens (a token with DNS write scope, only for the DNS challenge)\thttps://cloud.digitalocean.com/account/api/tokens\n'
            printf 'droplet metadata service (how pol prod addresses reads the assigned IPs)\thttps://docs.digitalocean.com/products/droplets/how-to/retrieve-droplet-metadata/\n' ;;
        letsencrypt)
            printf 'how it works (free, automatic, publicly trusted)\thttps://letsencrypt.org/how-it-works/\n'
            printf 'rate limits (5 duplicate certificates per week — do not loop apply while DNS is wrong)\thttps://letsencrypt.org/docs/rate-limits/\n'
            printf 'service status\thttps://letsencrypt.status.io/\n'
            printf 'see the issued certificates for your domain (public log)\thttps://crt.sh/?q=%s\n' "${POL_PROD_DOMAIN:-yourdomain}"
            printf 'certbot documentation (the client the suite runs)\thttps://eff-certbot.readthedocs.io/\n' ;;
        github)
            printf 'your packages (published images)\thttps://github.com/dausume?tab=packages\n'
            printf 'personal access tokens (read:packages for private pulls)\thttps://github.com/settings/tokens\n'
            printf 'container registry documentation\thttps://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry\n' ;;
        cloudflare)
            printf 'dashboard\thttps://dash.cloudflare.com/\n'
            printf 'API tokens\thttps://dash.cloudflare.com/profile/api-tokens\n' ;;
        registrar)
            printf 'your registrar'"'"'s DNS page — add an A record for each name to the exposure address\t(the registrar where the domain was bought)\n'
            printf 'check what the world sees for a name\thttps://dnschecker.org/#A/%s\n' "${POL_PROD_DOMAIN:-yourdomain}" ;;
        suite-ca)
            printf 'the CA lives in ca/ (root_ca.crt); import it in a browser to stop the warning on a self-signed edge\t(local)\n' ;;
        local-build)
            printf 'images are built on this machine from the checkout — publish them to a registry to make a small server only pull\t(local)\n' ;;
    esac
}

# ---- official image sources: where release images are pulled from ------------
# One line per source: prefix<TAB>title. The FIRST is the default official source.
official_image_sources() {
    printf 'ghcr.io/dausume/\tGitHub Container Registry — the official Polari images (built and published by the release job)\n'
}
image_source_title() {  # prefix → title, or "manual: <prefix>"
    local t; t=$(official_image_sources | awk -F'\t' -v p="$1" '$1==p{print $2}'); [ -n "$t" ] && echo "official — $t" || echo "manual entry — $1"
}

# ---- official release sources: where published installers (debs) come from ------
# GitHub Releases of the suite: free for a public repository; assets are the platform debs.
official_release_sources() {
    printf 'dausume/polari-suite\tGitHub Releases of the Polari suite — the official installers (built and published by the release job)\n'
}
release_tags_with_debs() {  # owner/repo → tags whose release carries .deb assets (newest first, ≤ 8); unauthenticated API, 60 calls/h
    curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$1/releases?per_page=15" 2>/dev/null | python3 -c '
import sys, json
try: rels = json.load(sys.stdin)
except Exception: rels = []
n = 0
for r in rels if isinstance(rels, list) else []:
    if r.get("draft"): continue
    debs = [a for a in r.get("assets", []) if a.get("name", "").endswith(".deb")]
    if debs:
        print("%s\t%d deb(s), %s" % (r.get("tag_name"), len(debs), (r.get("published_at") or "")[:10])); n += 1
    if n >= 8: break'
}
release_deb_urls() {  # owner/repo tag → download URLs of the .deb assets
    curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$1/releases/tags/$2" 2>/dev/null | python3 -c '
import sys, json
try: r = json.load(sys.stdin)
except Exception: r = {}
for a in r.get("assets", []):
    if a.get("name", "").endswith(".deb"): print(a["browser_download_url"])'
}
