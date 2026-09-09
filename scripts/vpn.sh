#!/bin/bash
# pol vpn — the isle-vpn family from the core (vpn-1, Polari side).
#
# Two product lines, one family: Isle Link (WireGuard-based: point to
# point, mesh, blind relays) and Isle Bridge (OpenVPN-based: certificate
# joins, L2 spans, TCP/443). THE AUTHORITY IS THE ISLE SIDE: the VPN app
# is configured on the isle only. Polari holds a MIRROR (what each isle's
# app pushed) and an INBOX (proposals). Every verb here READS the mirror
# or FILES a proposal — nothing changes until an operator on the isle
# runs `isle vpn apply <id>`. Private keys never enter Polari: a rendered
# conf carries the @@DEVICE_PRIVATE_KEY@@ placeholder the isle app fills.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/core-api.sh"

show_help() {
    pol_box "pol vpn — Isle Link / Isle Bridge (mirror + proposals)"
    echo -e "
  ${CYAN}status${NC}                       summary: per-isle app kind, label, networks, peers
  ${CYAN}kinds${NC}                        the ten app kinds (Link when both ends run ours;
                               Bridge when joining a network / an OpenVPN-only box)
  ${CYAN}networks|peers|links|exposures|rules${NC} [--device D] [--network N]
                               the mirror rows (peers: public keys only)
  ${CYAN}proposals${NC} [--device D] [--status proposed|applied|rejected]
  ${CYAN}propose <kind>${NC} --device D key=value ...
                               file a proposal (kind: network|peer|rule|link|
                               exposure|revoke). Validated against the mirror;
                               refused with the reason. Nothing changes until
                               an operator runs ${BOLD}isle vpn apply <id>${NC} on the isle.
  ${CYAN}render${NC} --device D --network N --peer P|self
                               the wg-quick text Polari would hand the isle
                               (PrivateKey = @@DEVICE_PRIVATE_KEY@@ — filled on
                               the device; not applyable as-is, by design)
  ${CYAN}rules-render${NC} --device D --network N     the nftables text
  ${CYAN}options${NC} --device D              exposure rungs (.vpn only with a gateway app)
  ${CYAN}matrix${NC}                       per-isle kind / Blind vs Sees-traffic / .vpn names
  ${CYAN}qr <conf-file>${NC}               QR of a conf the ISLE exported (refuses a placeholder)
  ${CYAN}demo${NC}                         run the two-isle mock acceptance flow on the core
  ${CYAN}join${NC} --device D --requester NAME --base-url URL --fingerprint FP key=value ...
                               (vpn-3) file a JOIN REQUEST: a PeerAgreement (never
                               auto-admitted) + a proposal that waits for consent.
                               kind=peer (default; needs network_name, peer_name,
                               public_key) or kind=link (remote_device, remote_network,
                               remote_gateway_public_key, remote_cidrs)
  ${CYAN}agreements${NC} [--status S]      the VPN agreements with their proposals; knobs =
                               POST /api/peers/agreements/<id>/approve|deny|revoke

${BOLD}EXAMPLES${NC}
  pol vpn propose peer --device isle-a network_name=arch-demo peer_name=phone \\
      kind=vpn-link-node public_key=<44-char base64>
  pol vpn propose link --device isle-a network_name=arch-demo remote_device=isle-b \\
      remote_network=arch-demo remote_gateway_public_key=<key> \\
      remote_cidrs=10.60.2.0/24,10.20.0.0/24 agreement_id=<PeerAgreement id>
"
}

need_core() {
    core_api GET /api/vpn/kinds >/dev/null 2>&1 \
        || die "no core reachable (or the vpn module is not deployed there) — set POLARI_CORE_URL or start the node"
}

# fmt_table LISTKEY col1,col2,...  — JSON on stdin -> aligned table.
# (the script rides -c, NOT a heredoc: a heredoc would replace the
# stdin the JSON arrives on — the first live run of every list verb
# died on exactly that)
FMT_PY='
import json, sys
key, cols = sys.argv[1], sys.argv[2].split(",")
d = json.load(sys.stdin)
if not d.get("ok", True) and d.get("error"):
    print("ERROR:", d["error"]); sys.exit(1)
if d.get("banner"):
    print("!! " + d["banner"])
rows = d.get(key, [])
if isinstance(rows, dict):
    rows = list(rows.values())
if not rows:
    print("(no rows)"); sys.exit(0)
def cell(v):
    if isinstance(v, bool): return "yes" if v else "no"
    if isinstance(v, list): return ", ".join(map(str, v)) or "-"
    if isinstance(v, dict): return json.dumps(v)
    return str(v) if v not in (None, "") else "-"
table = [[cell(r.get(c, "")) for c in cols] for r in rows]
widths = [min(60, max(len(c), *(len(t[i]) for t in table))) for i, c in enumerate(cols)]
fmt = "  ".join("%%-%ds" % w for w in widths)
print(fmt % tuple(cols))
for t in table:
    print(fmt % tuple(x[:60] for x in t))
'
fmt_table() {
    python3 -c "$FMT_PY" "$1" "$2"
}

parse_filters() {  # sets DEVICE NETWORK STATUS from --device/--network/--status
    DEVICE=""; NETWORK=""; STATUS=""; PEER=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --device) DEVICE="$2"; shift 2 ;;
            --network) NETWORK="$2"; shift 2 ;;
            --status) STATUS="$2"; shift 2 ;;
            --peer) PEER="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
}

query() {  # query PATH -> PATH?device=..&network=..&status=..
    local q="" p="$1"
    [ -n "$DEVICE" ] && q="${q}&device=$DEVICE"
    [ -n "$NETWORK" ] && q="${q}&network=$NETWORK"
    [ -n "$STATUS" ] && q="${q}&status=$STATUS"
    [ -n "$q" ] && p="$p?${q#&}"
    printf '%s' "$p"
}

do_status() {
    need_core
    core_api GET /api/vpn | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("banner"): print("!! " + d["banner"])
print("family:", d.get("family"), "|", d.get("authority"))
print("counts:", ", ".join("%s=%s" % kv for kv in sorted(d.get("counts", {}).items())))
print("proposals:", ", ".join("%s=%s" % kv for kv in sorted(d.get("proposals", {}).items())))
for i in d.get("isles", []):
    print("  %-10s %-20s %-12s networks=%s peers=%s last=%s" % (i["device"], i["app_kind"], i["label"], i["networks"], i["peers"], i.get("last_pushed", "")[:19]))'
}

do_placements() {
    need_core
    core_api GET /api/vpn/placements | python3 -c '
import json, sys
d = json.load(sys.stdin)
for place, rule in d.get("rules", {}).items(): print("%-18s %s" % (place, rule))
print()
print("%-20s %-18s %-9s %-13s %-8s %s" % ("kind", "placement", "tier", "extends", "label", "levels"))
for k in d.get("kinds", []):
    lab = "SEES" if k["sees_traffic"] else ("BLIND" if k["blind"] else "")
    print("%-20s %-18s %-9s %-13s %-8s %s" % (k["kind"], k["placement"], k["requires_tier"], k["extends"] or "-", lab, ",".join(json.loads(k["levels_json"]))))'
}

do_topology() {
    need_core
    lvl="${1:-isle}"
    core_api GET "/api/vpn/topology/$lvl" | python3 -c '
import json, sys, textwrap
d = json.load(sys.stdin)
if not d.get("ok"): sys.exit(print(d.get("error")) or 1)
print("%s (%s)" % (d["level"], d["rung"])); print(textwrap.fill(d["definition"], 96))
if d.get("floor"): print("floor:", d["floor"])
print("live:", d.get("live"))
print(); print("%-20s %-18s %-13s %s" % ("kind", "placement", "label", "role at this level"))
for p in d.get("placements", []): print("%-20s %-18s %-13s %s" % (p["kind"], p["placement"], p["label"], p["role"]))'
}

do_kinds() {
    need_core
    core_api GET /api/vpn/kinds | python3 -c '
import json, sys, textwrap
d = json.load(sys.stdin)
print(d.get("rule_of_thumb", ""))
for k in d.get("kinds", []):
    print("  %-18s %-14s %-12s %s" % (k["kind"], k["title"], k["line"], k["label"]))
    for ln in textwrap.wrap(k["description"], 70):
        print("      " + ln)'
}

do_list() {  # do_list <path-suffix> <listkey> <cols> [filters]
    local suffix=$1 key=$2 cols=$3; shift 3
    need_core; parse_filters "$@"
    core_api GET "$(query /api/vpn/$suffix)" | fmt_table "$key" "$cols"
}

do_propose() {
    local KIND="${1:-}"; shift || true
    [ -n "$KIND" ] || die "usage: pol vpn propose <network|peer|rule|link|exposure|revoke> --device D key=value ..."
    need_core
    local DEVICE="" pairs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --device) DEVICE="$2"; shift 2 ;;
            *=*) pairs+=("$1"); shift ;;
            *) die "unexpected argument '$1' (want key=value or --device D)" ;;
        esac
    done
    [ -n "$DEVICE" ] || die "--device D (the isle that will apply it) is required"
    local body
    body=$(python3 - "$KIND" "$DEVICE" "${pairs[@]}" <<'PY'
import json, sys
kind, device, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
d = {'kind': kind, 'device': device, 'proposed_by': 'pol vpn'}
for p in pairs:
    k, _, v = p.partition('=')
    if ',' in v and k.endswith(('cidrs',)):
        v = [x for x in v.split(',') if x]
    elif v.lower() in ('true', 'false'):
        v = v.lower() == 'true'
    d[k] = v
print(json.dumps(d))
PY
)
    printf '%s' "$body" | core_api POST /api/vpn/proposals | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    print("REFUSED:", d.get("error")); sys.exit(1)
p = d["proposal"]
print(d.get("message", ""))
print("proposal:", p["name"], "| kind:", p["kind"], "| device:", p["device_name"], "| status:", p["status"])'
}

do_render() {
    need_core; parse_filters "$@"
    [ -n "$DEVICE" ] && [ -n "$NETWORK" ] && [ -n "$PEER" ] || die "usage: pol vpn render --device D --network N --peer P|self"
    core_api GET "/api/vpn/render/$DEVICE/$NETWORK/$PEER" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    print("REFUSED:", d.get("reason") or d.get("error")); sys.exit(1)
sys.stdout.write(d["text"])
print("# " + d.get("note", ""))'
}

do_rules_render() {
    need_core; parse_filters "$@"
    [ -n "$DEVICE" ] && [ -n "$NETWORK" ] || die "usage: pol vpn rules-render --device D --network N"
    core_api GET "/api/vpn/rules/$DEVICE/$NETWORK/render" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    print("ERROR:", d.get("error")); sys.exit(1)
sys.stdout.write(d["text"])'
}

do_options() {
    need_core; parse_filters "$@"
    [ -n "$DEVICE" ] || die "usage: pol vpn options --device D"
    core_api GET "/api/vpn/exposure-options?device=$DEVICE" | fmt_table rungs rung,available,why
}

do_qr() {
    local f="${1:-}"
    [ -f "$f" ] || die "usage: pol vpn qr <conf-file the isle exported>"
    grep -q '@@DEVICE_PRIVATE_KEY@@' "$f" && die "$f still carries the @@DEVICE_PRIVATE_KEY@@ placeholder — not applyable; the isle app fills the key on the device (isle vpn export)"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ansiutf8 < "$f"
    else
        log_warn "qrencode not installed — import the file directly (apt install qrencode for a QR)"
    fi
}

do_join() {
    need_core
    local DEVICE="" REQ="" URL="" FP="" pairs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --device) DEVICE="$2"; shift 2 ;;
            --requester) REQ="$2"; shift 2 ;;
            --base-url) URL="$2"; shift 2 ;;
            --fingerprint) FP="$2"; shift 2 ;;
            *=*) pairs+=("$1"); shift ;;
            *) die "unexpected argument '$1'" ;;
        esac
    done
    [ -n "$DEVICE" ] && [ -n "$REQ" ] && [ -n "$URL" ] && [ -n "$FP" ] || die "usage: pol vpn join --device D --requester NAME --base-url URL --fingerprint FP [kind=peer|link] key=value ..."
    local body
    body=$(python3 - "$DEVICE" "$REQ" "$URL" "$FP" "${pairs[@]}" <<'PY'
import json, sys
device, req, url, fp, pairs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
d = {'device': device, 'kind': 'peer', 'requester_name': req, 'requester_base_url': url, 'fingerprint': fp}
for p in pairs:
    k, _, v = p.partition('=')
    d[k] = [x for x in v.split(',') if x] if (',' in v and k.endswith('cidrs')) else v
print(json.dumps(d))
PY
)
    printf '%s' "$body" | core_api POST /api/vpn/join-request | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    print("REFUSED:", d.get("error")); sys.exit(1)
print(d.get("message", ""))
print("agreement:", d.get("agreement_id"), "| proposal:", d.get("proposal"), "| status:", d.get("proposal_status", d.get("status")))'
}

do_demo() {
    need_core
    printf '{}' | core_api POST /api/vpn/demo | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("banner"): print("!! " + d["banner"])
for s in d.get("steps", []):
    print("  %s %s%s" % ("PASS" if s["pass"] else "FAIL", s["step"], ("  — " + str(s.get("detail"))) if (s.get("detail") and not s["pass"]) else ""))
print("all_pass:", d.get("all_pass"))
sys.exit(0 if d.get("all_pass") else 1)'
}

COMMAND="${1:-help}"; shift || true
case "$COMMAND" in
    status)        do_status ;;
    kinds)         do_kinds ;;
    placements)    do_placements ;;
    topology)      do_topology "$@" ;;
    networks)      do_list networks VpnNetwork network_name,device_name,kind,label,mode,cidr,listen_port,forward_allowed,masquerade,peer_count,status,is_mock "$@" ;;
    peers)         do_list peers VpnPeer peer_name,network_name,device_name,kind,label,public_key,address,endpoint,allowed_ips,status,last_handshake,remote_device "$@" ;;
    links)         do_list links VpnFederationLink name,remote_device,remote_network,gateway_peer,remote_cidrs,agreement_id,relay_kind,status "$@" ;;
    exposures)     do_list exposures AppVpnExposure vpn_name,app_name,network_name,device_name,label,role,status "$@" ;;
    rules)         do_list rules VpnAccessRule name,from_tag,to_target,action,ports,order "$@" ;;
    proposals)     do_list proposals proposals name,device_name,kind,status,proposed_at,applied_by,note "$@" ;;
    propose)       do_propose "$@" ;;
    render)        do_render "$@" ;;
    rules-render)  do_rules_render "$@" ;;
    options)       do_options "$@" ;;
    matrix)        need_core; core_api GET /api/vpn/matrix | fmt_table matrix isle,app_kind,title,label,vpn_rung,networks,peers,vpn_names,links_active ;;
    qr)            do_qr "$@" ;;
    demo)          do_demo ;;
    join)          do_join "$@" ;;
    agreements)    need_core; parse_filters "$@"; core_api GET "$(query /api/vpn/agreements)" | fmt_table agreements agreement_id,requester_name,requested_role,status,scope,approved_by,proposals ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown vpn command: $COMMAND"; show_help; exit 1 ;;
esac
