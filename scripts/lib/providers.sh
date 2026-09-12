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

# ---- tags a registry actually has for an image (public images, anonymous) ----------
# registry_image_tags <prefix> <image> → tags, newest-looking first (≤ 12), empty when unreachable/unpublished
registry_image_tags() {
    local prefix=${1%/} image=$2 host repo tok url
    host=${prefix%%/*}; repo="${prefix#*/}/$image"
    case "$host" in
        ghcr.io) tok=$(curl -fsSL --max-time 10 "https://ghcr.io/token?scope=repository:$repo:pull" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
                 url="https://ghcr.io/v2/$repo/tags/list?n=100" ;;
        docker.io|index.docker.io|"") tok=$(curl -fsSL --max-time 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
                 url="https://registry-1.docker.io/v2/$repo/tags/list?n=100" ;;
        *)       tok=""; url="https://$host/v2/${prefix#*/}/$image/tags/list?n=100" ;;
    esac
    curl -fsSL --max-time 10 ${tok:+-H "Authorization: Bearer $tok"} "$url" 2>/dev/null | python3 -c '
import sys, json, re
try: tags = json.load(sys.stdin).get("tags") or []
except Exception: tags = []
def key(t):  # releases newest first, -core before -all before the plain tag; then the tier tags; then the rest
    m = re.match(r"^polari-v(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?(?:-(core|all))?$", t)
    if m:
        return (0, -int(m.group(1)), -int(m.group(2)), -int(m.group(3)), -int(m.group(4) or 0), {"core": 0, "all": 1, None: 2}[m.group(5)])
    return (1, t) if t in ("staging", "prod", "latest") else (2, t)
for t in sorted(tags, key=key)[:12]: print(t)'
}
official_image_tags() { registry_image_tags "$(official_image_sources | head -1 | cut -f1)" prf-backend; }

# ---- where a domain's DNS actually lives (its nameservers), and how to add a record there ----
domain_nameservers() {  # domain → nameserver hostnames, one per line
    { resolvectl query -t NS "$1" 2>/dev/null | awk '/ IN NS /{print $4}'; } | sed 's/\.$//' | sort -u
    [ -n "$(resolvectl query -t NS "$1" 2>/dev/null | awk '/ IN NS /')" ] || nslookup -type=NS "$1" 2>/dev/null | awk '/nameserver =/{print $NF}' | sed 's/\.$//' | sort -u
}
dns_host_of() {  # domain → digitalocean | cloudflare | registrar (the provider id the records must be created at)
    local ns; ns=$(domain_nameservers "$1" | tr '\n' ' ')
    case "$ns" in *digitalocean.com*) echo digitalocean ;; *cloudflare.com*) echo cloudflare ;; *) echo registrar ;; esac
}
provider_dns_page() {  # provider domain → the page where records are added
    case "$1" in
        digitalocean) echo "https://cloud.digitalocean.com/networking/domains/$2" ;;
        cloudflare)   echo "https://dash.cloudflare.com/ (select the site $2 → DNS → Records)" ;;
        *)            echo "your registrar's DNS page for $2" ;;
    esac
}
provider_dns_howto() {  # provider → documentation on adding a record + the clicks
    case "$1" in
        digitalocean) printf 'https://docs.digitalocean.com/products/networking/dns/how-to/manage-records/\tNetworking → Domains → the domain → Create new record: type A, HOSTNAME = the subdomain (or * for the wildcard), WILL DIRECT TO = the droplet address\n' ;;
        cloudflare)   printf 'https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/\tDNS → Records → Add record: type A, Name = the subdomain (or *), IPv4 address = the server address\n' ;;
        *)            printf 'https://dnschecker.org/\tAt the registrar: DNS / Advanced DNS → add an A record: host = the subdomain (or *), value = the server address\n' ;;
    esac
}

# ---- authoritative DNS answer (bypasses every cache): ask the domain's own nameservers directly ----
# resolve_authoritative <name> <domain> → the A address the DNS host serves right now (pure python UDP query, no deps)
resolve_authoritative() {
    local name=$1 domain=$2 ns nsip
    for ns in $(domain_nameservers "$domain"); do
        nsip=$(getent ahostsv4 "$ns" 2>/dev/null | awk '{print $1; exit}'); [ -n "$nsip" ] || continue
        python3 - "$name" "$nsip" <<'PY' && return 0
import socket, struct, sys, random
name, server = sys.argv[1], sys.argv[2]
qid = random.randint(0, 65535)
q = struct.pack('>HHHHHH', qid, 0x0000, 1, 0, 0, 0)   # RD=0: authoritative answer only
for part in name.strip('.').split('.'):
    q += bytes([len(part)]) + part.encode()
q += b'\x00' + struct.pack('>HH', 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
try:
    s.sendto(q, (server, 53)); data, _ = s.recvfrom(2048)
except Exception:
    sys.exit(1)
if len(data) < 12 or struct.unpack('>H', data[:2])[0] != qid: sys.exit(1)
ancount = struct.unpack('>H', data[6:8])[0]
i = 12
def skip_name(i):
    while True:
        l = data[i]
        if l == 0: return i + 1
        if l & 0xC0: return i + 2
        i += 1 + l
i = skip_name(i) + 4
for _ in range(ancount):
    i = skip_name(i); typ, cls, ttl, rdlen = struct.unpack('>HHIH', data[i:i+10]); i += 10
    if typ == 1 and rdlen == 4: print('.'.join(str(b) for b in data[i:i+4])); sys.exit(0)
    i += rdlen
sys.exit(1)
PY
    done
    return 1
}

# ---- the DigitalOcean API token walk-through (DNS challenge only) ----------------
# do_token_walkthrough [droplet-name] → the exact clicks, a suggested token name, the scope, and how to hand it over
do_token_walkthrough() {
    local who=${1:-$(hostname)}
    cat <<EOT
The DNS challenge proves you own the names by writing a record through DigitalOcean's API, so it needs an API
token with DNS (domain) write scope. Nothing else needs one. Get it like this (2 minutes, once):

  1. Open  https://cloud.digitalocean.com/account/api/tokens   (API → Tokens, signed in as the account that owns the domain)
  2. Generate New Token
       Name:        polari-${who}-dns        (so you can see later what it is for and revoke it alone)
       Expiration:  90 days is fine — renewals only need it when a record must be re-proven
       Scopes:      Custom scopes → domain: read + write   (nothing else; not full access)
  3. Copy the token now — DigitalOcean shows it only once.
  4. Hand it to Polari for this run (it is never written into the answers):
       DO_API_TOKEN='paste-it-here' pol prod cert
     With the stash policy 'all' (or 'some' and a yes) it is kept in the root-only vault and never asked again:
       sudo pol security vault list

Or avoid the token entirely: choose the HTTP challenge (pol prod guide → HTTPS certificate). It needs only port 80
reachable and every name pointing here — no provider credential at all.
EOT
}
