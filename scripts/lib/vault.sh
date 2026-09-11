#!/bin/bash
# vault.sh — the credential vault (PRODUCTION_DEPLOY_PLAN §16, prd-9).
#
# ONE encrypted, root-only, clearly labelled file that holds the credentials a
# deployment generated (Keycloak admin, DB, MinIO …) and the provider
# credentials the operator CHOSE to stash (all / some / none). Its purpose is
# protection against anyone EXTERNAL — a copied disk, a backup, another local
# user, a tarball of the checkout: the file is useless without the identity
# that lives next to it as root, and the identity never leaves the machine.
# It is NOT a barrier against the operator account (his ruling 2026-09-11:
# fast iteration first); the off-machine-key mode is the knob for later.
#
#   POL_VAULT_DIR      /etc/polari/vault (default) — tests may point it elsewhere
#   POL_VAULT_MODE     local (default: identity kept in the vault dir, root-only)
#                      offline-key: encrypt ONLY to the recipients in $POL_VAULT_DIR/recipients
#                      (age ssh/age public keys); nothing on this machine can decrypt
#   backend            age when installed (age-keygen), else openssl aes-256-cbc/pbkdf2 with
#                      a 256-bit random key file — same guarantee, no new dependency
#
# Layout (dir 0700 root):  identity (0600)  identity.pub  vault.enc (0600)  vault.meta
#                          vault.enc.superseded-<stamp> (rotation keeps the old one)
# Document (plaintext, only ever in memory / on the terminal): a banner, then
#   [polari <domain>]          generated credentials, KEY = value   # <purpose> (stashed <date>)
#   [provider <name>]          stashed provider credentials, by the operator's choice
#
# Verbs (pol security vault …): init | put <section> <key> <value> [note] | get <section> <key> |
#   list | show | forget <section> [key] | export <path> | import <file> | shred | status
# Every write is decrypt → edit in memory → re-encrypt; the file is replaced atomically.

VAULT_DIR="${POL_VAULT_DIR:-/etc/polari/vault}"
VAULT_MODE="${POL_VAULT_MODE:-local}"
VAULT_FILE="$VAULT_DIR/vault.enc"
VAULT_META="$VAULT_DIR/vault.meta"
VAULT_ID="$VAULT_DIR/identity"

_vsudo() {  # run as root only when the vault dir (or, before it exists, its parent) is not ours
    local d="$VAULT_DIR"; [ -d "$d" ] || d=$(dirname "$d")
    if [ "$(id -u)" = 0 ] || [ -w "$d" ]; then "$@"; else sudo "$@"; fi
}
vault_backend() { command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 && echo age || echo openssl; }
vault_exists() { _vsudo test -s "$VAULT_FILE" 2>/dev/null; }
vault_ready() { _vsudo test -s "$VAULT_ID" 2>/dev/null || [ "$VAULT_MODE" = offline-key ]; }

vault_init() {  # idempotent: the dir, the identity, an empty document
    local parent; parent=$(dirname "$VAULT_DIR")
    _vsudo mkdir -p "$VAULT_DIR"; _vsudo chmod 700 "$VAULT_DIR"
    [ "$(stat -c %u "$parent" 2>/dev/null)" = 0 ] && _vsudo chown root:root "$VAULT_DIR" 2>/dev/null || true
    if [ "$VAULT_MODE" = local ] && ! _vsudo test -s "$VAULT_ID"; then
        if [ "$(vault_backend)" = age ]; then
            _vsudo sh -c "umask 077; age-keygen -o '$VAULT_ID' 2>/dev/null; age-keygen -y '$VAULT_ID' > '$VAULT_ID.pub'"
        else
            _vsudo sh -c "umask 077; openssl rand -hex 32 > '$VAULT_ID'; echo 'openssl-local-key' > '$VAULT_ID.pub'"
        fi
        _vsudo chmod 600 "$VAULT_ID"
    fi
    if [ "$VAULT_MODE" = offline-key ] && ! _vsudo test -s "$VAULT_DIR/recipients"; then
        echo "vault: mode offline-key needs $VAULT_DIR/recipients (one age or ssh public key per line)" >&2; return 1
    fi
    if ! vault_exists; then
        _vault_write_doc <<EOF
$(_vault_banner)
EOF
    fi
    _vsudo sh -c "printf 'backend=%s\nmode=%s\ncreated=%s\nhost=%s\n' '$(vault_backend)' '$VAULT_MODE' '$(date -u +%FT%TZ)' '$(hostname)' > '$VAULT_META'"
}

_vault_banner() {
    cat <<EOF
# ======================================================================
# POLARI CREDENTIALS — generated on $(hostname), vault created $(date -u +%F)
# Root-only and encrypted (${VAULT_MODE} mode, $(vault_backend)). Read with:
#     sudo pol security vault show
# Every value below may be the ONLY copy. Provider credentials appear here
# only because the operator chose to stash them — record them in your own
# password manager and remove them:  sudo pol security vault forget <section>
# ======================================================================
EOF
}

_vault_encrypt() {  # stdin → stdout
    if [ "$VAULT_MODE" = offline-key ]; then
        local args=(); while read -r r; do [ -n "$r" ] && args+=(-r "$r"); done < <(_vsudo cat "$VAULT_DIR/recipients"); age "${args[@]}"
    elif [ "$(vault_backend)" = age ]; then
        age -R <(_vsudo cat "$VAULT_ID.pub")
    else
        openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass file:<(_vsudo cat "$VAULT_ID")
    fi
}
_vault_decrypt() {  # file → stdout
    [ "$VAULT_MODE" = offline-key ] && { echo "vault: offline-key mode — this machine cannot decrypt; export the file and open it where the private key is" >&2; return 2; }
    if [ "$(vault_backend)" = age ]; then
        _vsudo cat "$VAULT_FILE" | age -d -i <(_vsudo cat "$VAULT_ID")
    else
        _vsudo cat "$VAULT_FILE" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass file:<(_vsudo cat "$VAULT_ID")
    fi
}
_vault_write_doc() {  # stdin (plaintext) → vault.enc, atomically, 0600
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/vault.XXXXXX")
    _vault_encrypt > "$tmp" || { rm -f "$tmp"; return 1; }
    _vsudo sh -c "umask 077; cat '$tmp' > '$VAULT_FILE.new' && chmod 600 '$VAULT_FILE.new' && mv -f '$VAULT_FILE.new' '$VAULT_FILE'"
    rm -f "$tmp"
}
_vault_doc() { vault_exists && _vault_decrypt || _vault_banner; }

# ---- edits (decrypt → python edit in memory → encrypt) ------------------
vault_put() {  # section key value [note]
    local section=$1 key=$2 value=$3 note=${4:-}
    vault_init || return 1
    _vault_doc | python3 -c '
import sys, datetime
section, key, value, note = sys.argv[1:5]
stamp = datetime.datetime.utcnow().strftime("%Y-%m-%d")
lines = sys.stdin.read().split("\n")
hdr = "[" + section + "]"
line = "%s = %s   # %s(stashed %s)" % (key, value, (note + " ") if note else "", stamp)
out, i, done = [], 0, False
while i < len(lines):
    l = lines[i]
    if l.strip() == hdr:
        out.append(l); i += 1
        while i < len(lines) and not lines[i].startswith("["):
            if lines[i].split("=")[0].strip() == key and not done:
                out.append(line); done = True
            else:
                out.append(lines[i])
            i += 1
        if not done:
            # insert before trailing blank lines of the section
            while out and out[-1].strip() == "": out.pop()
            out.append(line); out.append(""); done = True
        continue
    out.append(l); i += 1
if not done:
    while out and out[-1].strip() == "": out.pop()
    out += ["", hdr, line, ""]
sys.stdout.write("\n".join(out))
' "$section" "$key" "$value" "$note" | _vault_write_doc
}
vault_get() {  # section key → value (exit 1 if absent)
    local section=$1 key=$2
    vault_exists || return 1
    _vault_decrypt | python3 -c '
import sys
section, key = sys.argv[1:3]
cur = None
for l in sys.stdin.read().split("\n"):
    if l.startswith("["): cur = l.strip()[1:-1]; continue
    if cur == section and "=" in l and l.split("=")[0].strip() == key:
        v = l.split("=", 1)[1]
        if "   #" in v: v = v.split("   #", 1)[0]
        print(v.strip()); sys.exit(0)
sys.exit(1)' "$section" "$key"
}
vault_forget() {  # section [key]
    local section=$1
    vault_exists || return 0
    _vault_decrypt | python3 -c '
import sys
section = sys.argv[1]; key = sys.argv[2] if len(sys.argv) > 2 else None
out, cur = [], None
for l in sys.stdin.read().split("\n"):
    if l.startswith("["):
        cur = l.strip()[1:-1]
        if cur == section and key is None: continue
    elif cur == section:
        if key is None: continue
        if "=" in l and l.split("=")[0].strip() == key: continue
    out.append(l)
sys.stdout.write("\n".join(out))' "$section" ${2:+"$2"} | _vault_write_doc
}
vault_list() {  # sections, keys, stamps — never values
    vault_exists || { echo "  (no vault yet: $VAULT_FILE)"; return 0; }
    _vault_decrypt | python3 -c '
import sys, re
cur = None; n = 0
for l in sys.stdin.read().split("\n"):
    if l.startswith("["): cur = l.strip()[1:-1]; print("  " + cur); continue
    if cur and "=" in l and not l.startswith("#"):
        k = l.split("=")[0].strip(); m = re.search(r"#\s*(.*)$", l); n += 1
        print("    %-40s %s" % (k, (m.group(1) if m else "")))
if n == 0: print("  (empty)")'
}
vault_show() { vault_exists || { echo "no vault at $VAULT_FILE"; return 1; }; _vault_decrypt; }
vault_export() { local dst=${1:?path}; vault_exists || return 1; _vsudo cat "$VAULT_FILE" > "$dst" && chmod 600 "$dst" && { [ "$VAULT_MODE" = offline-key ] || cp <(_vsudo cat "$VAULT_ID") "$dst.identity" 2>/dev/null && chmod 600 "$dst.identity"; }; echo "exported $dst$([ -f "$dst.identity" ] && echo " + $dst.identity (the key — keep them apart)")"; }
vault_import() { local src=${1:?file}; vault_init; _vsudo sh -c "umask 077; cat '$src' > '$VAULT_FILE'"; [ -f "$src.identity" ] && _vsudo sh -c "umask 077; cat '$src.identity' > '$VAULT_ID'"; echo "imported into $VAULT_FILE"; }
vault_shred() { vault_exists || return 0; _vsudo sh -c "command -v shred >/dev/null && shred -u '$VAULT_FILE' || rm -f '$VAULT_FILE'"; echo "vault shredded ($VAULT_FILE); the identity stays for the next generation"; }
vault_rotate_file() { vault_exists && _vsudo mv "$VAULT_FILE" "$VAULT_FILE.superseded-$(date -u +%Y%m%dT%H%M%SZ)"; }
vault_status() {  # one paragraph for pol security status / pol prod status
    if vault_exists; then
        local n; n=$(vault_list 2>/dev/null | grep -c '^    ' || true)
        echo "vault: $VAULT_FILE ($(vault_backend), $VAULT_MODE mode, $n item(s), $(( ( $(date +%s) - $(_vsudo stat -c %Y "$VAULT_FILE") ) / 86400 ))d old) — sudo pol security vault show"
        if vault_list 2>/dev/null | grep -q '^  provider '; then echo "vault: provider credentials are STASHED by your choice — move them to your password manager and: sudo pol security vault forget 'provider <name>'"; fi
    else
        echo "vault: none at $VAULT_FILE (created by the first pol prod apply that generates credentials, or: pol security vault init)"
    fi
    return 0
}

vault_cmd() {  # pol security vault <verb> …
    local v=${1:-status}; shift || true
    case "$v" in
        init)   vault_init && echo "vault ready: $VAULT_DIR ($(vault_backend), $VAULT_MODE)" ;;
        put)    vault_put "${1:?section}" "${2:?key}" "${3:?value}" "${4:-}" && echo "stored [$1] $2" ;;
        get)    vault_get "${1:?section}" "${2:?key}" ;;
        list)   vault_list ;;
        show)   vault_show ;;
        forget) vault_forget "${1:?section}" ${2:+"$2"} && echo "forgot [$1]${2:+ $2}" ;;
        export) vault_export "${1:?path}" ;;
        import) vault_import "${1:?file}" ;;
        shred)  vault_shred ;;
        status) vault_status ;;
        *) echo "pol security vault init|put <section> <key> <value> [note]|get <section> <key>|list|show|forget <section> [key]|export <path>|import <file>|shred|status   (POL_VAULT_DIR=$VAULT_DIR, mode $VAULT_MODE, backend $(vault_backend))"; return 1 ;;
    esac
}
