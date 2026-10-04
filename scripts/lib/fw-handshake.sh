#!/bin/bash
# lib/fw-handshake.sh — turn CLOSED ports into CONSENTED, SOURCE-SCOPED ufw
# rules, and hand them back on request. His security rule: ingress is
# closed by default, and every rule is `allow from <peer-ip> to any port
# <p> proto <tcp|udp>` — never a blanket `allow <port>`. His uninstall
# rule: anything pol opens is appended to a hand-back journal and can be
# replayed in reverse (`pol net handback --apply`).
#
# Nothing here EVER touches a firewall without the person's consent:
# sudo prompting for a password, or a typed y/N — never in a pipeline/CI,
# never without a TTY. Source AFTER lib/log.sh.
#
# Functions:
#   fw_detect <alias>                        → ufw-active|ufw-inactive|firewalld|nftables|none
#   fw_rule_present <alias> <peer> <port> <proto>   (0 = already there)
#   fw_print_equivalent <firewalld|nftables> <peer> <port> <proto>
#   fw_can_prompt                            (0 = ok to ask; never in CI/no-TTY/POL_ASSUME_NO=1)
#   fw_journal_append <alias> <host> <binding> <peer> <rule> <undo> <comment>
#   fw_handshake_apply <alias> <binding> <peer_label> <peer_ip> <yes:0|1>
#                                              (reads global SWARM_PORTS_CLOSED)
#   fw_handback_list <alias> [<peer-filter>]
#   fw_handback_apply <alias> [<peer-filter>] <yes:0|1>

POL_HANDBACK_DIR="${POL_HANDBACK_DIR:-$HOME/.polari/handback}"
POL_HANDBACK_FILE="$POL_HANDBACK_DIR/firewall.jsonl"

# run a command foregrounded, inheriting stdio — this is where a real sudo
# password prompt (local) or `ssh -t … sudo …` prompt (remote) happens.
_fw_run() {  # _fw_run <alias> <cmd-string>
    local alias=$1; shift
    if [ -z "$alias" ]; then bash -c "$*"; else ssh -t -o ConnectTimeout=8 "$alias" "$*"; fi
}
# quiet, non-interactive probe (status reads only — never a mutation)
_fw_run_q() {  # _fw_run_q <alias> <cmd-string>
    local alias=$1; shift
    if [ -z "$alias" ]; then bash -c "$*" 2>/dev/null; else ssh -o ConnectTimeout=8 "$alias" "$*" 2>/dev/null; fi
}

fw_detect() {  # fw_detect <alias> → ufw-active|ufw-inactive|firewalld|nftables|none
    local alias=$1
    _fw_run_q "$alias" '
        if command -v ufw >/dev/null 2>&1; then
            ufw status 2>/dev/null | grep -q "^Status: active" && echo ufw-active || echo ufw-inactive
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
            echo firewalld
        elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q .; then
            echo nftables
        else
            echo none
        fi'
}

fw_rule_present() {  # fw_rule_present <alias> <peer_ip> <port> <proto> — idempotency check
    local alias=$1 peer=$2 port=$3 proto=$4 status
    status=$(_fw_run_q "$alias" "ufw status 2>/dev/null")
    printf '%s\n' "$status" | grep -E "^${port}/${proto}[[:space:]]" | grep -q "$peer"
}

fw_print_equivalent() {  # fw_print_equivalent <firewalld|nftables> <peer> <port> <proto>
    local kind=$1 peer=$2 port=$3 proto=$4
    case "$kind" in
        firewalld)
            echo "  sudo firewall-cmd --permanent --add-rich-rule='rule family=\"ipv4\" source address=\"$peer\" port port=\"$port\" protocol=\"$proto\" accept'"
            echo "  sudo firewall-cmd --reload" ;;
        nftables)
            echo "  sudo nft add rule inet filter input ip saddr $peer $proto dport $port accept" ;;
    esac
}

# fw_can_prompt — may pol ask a y/N question right now? POL_FORCE_TTY is a
# selftest-only override (no real pty available under the fake harness);
# real usage falls through to the actual [ -t 0 ].
fw_can_prompt() {
    [ "${POL_ASSUME_NO:-0}" = 1 ] && return 1
    [ -n "${CI:-}" ] && return 1
    if [ -n "${POL_FORCE_TTY:-}" ]; then
        [ "$POL_FORCE_TTY" = 1 ]; return $?
    fi
    [ -t 0 ]
}

fw_journal_append() {  # fw_journal_append <alias> <host> <binding> <peer> <rule> <undo> <comment>
    local alias=$1 host=$2 binding=$3 peer=$4 rule=$5 undo=$6 comment=$7 json
    json=$(python3 -c '
import json, sys
ts, host, binding, peer, rule, undo, comment = sys.argv[1:8]
print(json.dumps({"ts": ts, "host": host, "binding": binding, "peer": peer,
                   "rule": rule, "undo": undo, "comment": comment}))
' "$(date -Iseconds)" "$host" "$binding" "$peer" "$rule" "$undo" "$comment")
    if [ -z "$alias" ]; then
        mkdir -p "$POL_HANDBACK_DIR"
        printf '%s\n' "$json" >> "$POL_HANDBACK_FILE"
    else
        printf '%s\n' "$json" | ssh -o ConnectTimeout=8 "$alias" 'mkdir -p ~/.polari/handback && cat >> ~/.polari/handback/firewall.jsonl'
    fi
}

fw_handback_read() {  # fw_handback_read <alias> → raw jsonl ("" if none)
    local alias=$1
    if [ -z "$alias" ]; then
        [ -f "$POL_HANDBACK_FILE" ] && cat "$POL_HANDBACK_FILE" || true
    else
        ssh -o ConnectTimeout=8 "$alias" "cat ~/.polari/handback/firewall.jsonl 2>/dev/null" || true
    fi
}

fw_handback_write() {  # fw_handback_write <alias>   (new content on stdin)
    local alias=$1
    if [ -z "$alias" ]; then
        mkdir -p "$POL_HANDBACK_DIR"
        cat > "$POL_HANDBACK_FILE"
    else
        ssh -o ConnectTimeout=8 "$alias" 'mkdir -p ~/.polari/handback && cat > ~/.polari/handback/firewall.jsonl'
    fi
}

# fw_handshake_apply — turn the globally-set SWARM_PORTS_CLOSED rows
# ("port/proto" entries left by check_swarm_ports) into consented,
# source-scoped ufw rules on <alias> (empty = this host), and journal
# every one actually applied. Returns 0 when it is worth re-checking the
# ports (applied something, or everything was already present), 1
# otherwise (declined / non-interactive / no ufw / another firewall).
fw_handshake_apply() {  # fw_handshake_apply <alias> <binding> <peer_label> <peer_ip> <yes:0|1>
    local alias=$1 binding=$2 peer_label=$3 peer_ip=$4 yes=$5
    [ "${#SWARM_PORTS_CLOSED[@]}" -gt 0 ] || return 0
    [ -n "$peer_ip" ] || { log_warn "peer IP unknown — cannot build source-scoped rules for consent; apply the lines above by hand"; return 1; }

    local fw; fw=$(fw_detect "$alias")
    case "$fw" in
        ufw-inactive)
            log_info "ufw is inactive on ${alias:-this host} — nothing pol can open there (the lines above are for whichever firewall is used)"
            return 1 ;;
        none)
            log_info "no firewall detected on ${alias:-this host} — nothing pol can open there"
            return 1 ;;
        firewalld|nftables)
            log_warn "$fw detected on ${alias:-this host} — pol only automates ufw; equivalent rules (NOT applied):"
            local cp port proto
            for cp in "${SWARM_PORTS_CLOSED[@]}"; do
                port=${cp%%/*}; proto=${cp##*/}
                fw_print_equivalent "$fw" "$peer_ip" "$port" "$proto"
            done
            return 1 ;;
    esac

    # ufw-active: skip whatever is already there (idempotent)
    local -a todo=()
    local cp port proto
    for cp in "${SWARM_PORTS_CLOSED[@]}"; do
        port=${cp%%/*}; proto=${cp##*/}
        if fw_rule_present "$alias" "$peer_ip" "$port" "$proto"; then
            log_info "already present: allow from $peer_ip port $port/$proto — skipping"
        else
            todo+=("$port/$proto")
        fi
    done
    [ "${#todo[@]}" -gt 0 ] || { log_success "all needed rules already present on ${alias:-this host}"; return 0; }

    if ! fw_can_prompt; then
        log_warn "non-interactive — not applying (the ufw lines above are ready to run by hand, or re-run at a terminal with --yes)"
        return 1
    fi

    echo
    pol_box "firewall consent: ${peer_label} ($peer_ip) -> ${alias:-this host}"
    local t comment="polari $binding $peer_label"
    for t in "${todo[@]}"; do
        port=${t%%/*}; proto=${t##*/}
        echo "  sudo ufw allow from $peer_ip to any port $port proto $proto comment '$comment'"
    done
    if [ "$yes" != 1 ]; then
        local ans
        read -r -p "apply these ${#todo[@]} rule(s) on ${alias:-this host}? [y/N] " ans
        case "$ans" in y|Y|yes|YES) ;; *) log_info "declined — nothing applied"; return 1 ;; esac
    fi
    if _fw_run_q "$alias" "sudo -n true"; then
        log_info "sudo: no password needed on ${alias:-this host}"
    else
        log_info "sudo will prompt for a password on ${alias:-this host} — that is the handshake"
    fi

    local applied=0
    for t in "${todo[@]}"; do
        port=${t%%/*}; proto=${t##*/}
        if _fw_run "$alias" "sudo ufw allow from $peer_ip to any port $port proto $proto comment '$comment'"; then
            fw_journal_append "$alias" "${alias:-$(hostname 2>/dev/null || echo localhost)}" "$binding" "$peer_label" \
                "sudo ufw allow from $peer_ip to any port $port proto $proto comment '$comment'" \
                "ufw delete allow from $peer_ip to any port $port proto $proto" "$comment"
            applied=$((applied+1))
        else
            log_warn "failed to apply the rule for $port/$proto"
        fi
    done
    log_success "$applied/${#todo[@]} rule(s) applied on ${alias:-this host}"
    [ "$applied" -gt 0 ]
}

fw_handback_list() {  # fw_handback_list <alias> [<peer-filter>]
    local alias=$1 peer=${2:-} content
    content=$(fw_handback_read "$alias")
    [ -n "$content" ] || { log_info "handback journal empty on ${alias:-this host}"; return 0; }
    pol_box "firewall handback: ${alias:-this host}${peer:+ (peer $peer)}"
    printf '%s\n' "$content" | python3 -c '
import json, sys
peer = sys.argv[1] if len(sys.argv) > 1 else ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if peer and d.get("peer") != peer:
        continue
    print("  %-20s %-14s peer=%-10s %s" % (d.get("ts","?"), d.get("binding","?"), d.get("peer","?"), d.get("rule","")))
' "$peer"
}

# fw_handback_apply — replay the undo commands in REVERSE (most recent
# first), same consent rules as fw_handshake_apply, then shrink the
# journal to whatever failed to hand back (kept for a retry).
fw_handback_apply() {  # fw_handback_apply <alias> [<peer-filter>] <yes:0|1>
    local alias=$1 peer=${2:-} yes=$3 content
    content=$(fw_handback_read "$alias")
    [ -n "$content" ] || { log_info "nothing to hand back on ${alias:-this host}"; return 0; }

    local plan
    plan=$(printf '%s' "$content" | python3 -c '
import json, sys
peer = sys.argv[1]
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
matched = []
for i, l in enumerate(lines):
    d = json.loads(l)
    if not peer or d.get("peer") == peer:
        matched.append((i, d))
for i, d in reversed(matched):
    print("%d\t%s\t%s" % (i, d.get("undo",""), d.get("rule","")))
' "$peer")
    [ -n "$plan" ] || { log_info "nothing matching on ${alias:-this host}${peer:+ for peer $peer}"; return 0; }
    local n; n=$(printf '%s\n' "$plan" | grep -c .)

    echo
    pol_box "firewall hand-back: ${alias:-this host}${peer:+ (peer $peer)}"
    local idx undo rule
    while IFS=$'\t' read -r idx undo rule; do echo "  sudo $undo"; done <<< "$plan"

    if ! fw_can_prompt; then
        log_warn "non-interactive — not applying (the undo lines above are ready to run by hand)"
        return 1
    fi
    if [ "$yes" != 1 ]; then
        local ans
        read -r -p "hand back these $n rule(s) on ${alias:-this host}? [y/N] " ans
        case "$ans" in y|Y|yes|YES) ;; *) log_info "declined — nothing handed back"; return 1 ;; esac
    fi

    local done_idx="" applied=0
    while IFS=$'\t' read -r idx undo rule; do
        [ -n "$idx" ] || continue
        if _fw_run "$alias" "sudo $undo"; then
            done_idx="$done_idx $idx"
            applied=$((applied+1))
        else
            log_warn "hand-back failed for: $undo (kept in the journal)"
        fi
    done <<< "$plan"

    printf '%s' "$content" | python3 -c '
import json, sys
done = set(int(x) for x in sys.argv[1].split()) if sys.argv[1].strip() else set()
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
for i, l in enumerate(lines):
    if i not in done:
        print(l)
' "$done_idx" | fw_handback_write "$alias"

    local kept; kept=$(fw_handback_read "$alias" | grep -c . || true); kept=${kept:-0}
    log_success "$applied/$n rule(s) handed back on ${alias:-this host}; journal now has $kept entr$([ "$kept" = 1 ] && echo y || echo ies)"
}
