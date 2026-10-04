#!/bin/bash
# lib/net-needs.sh — pol net needs: what ports a BINDING needs open, and
# from whom. Data, not prose: one function emits the rows a caller turns
# into source-scoped ufw rules (never a blanket `allow <port>` — see
# lib/fw-handshake.sh, which is the only thing allowed to apply any of
# this). Source AFTER lib/log.sh.
#
#   net_needs <binding> [port]   → lines "side port proto purpose"
#     swarm-manager          accepts from a WORKER joining this manager:
#                             2377/tcp 7946/tcp 7946/udp 4789/udp
#     swarm-worker            accepts from the MANAGER it joined:
#                             7946/tcp 7946/udp 4789/udp
#     engine-worker <port>    accepts from whatever calls it DIRECTLY,
#                             not through the mesh — the hw/engine
#                             workers: 9830 (board) / 9840 (formal) /
#                             9850 (esp) / 9860

net_needs() {  # net_needs <binding> [port]
    local binding=$1 port=${2:-}
    case "$binding" in
        swarm-manager)
            printf 'manager %s %s %s\n' 2377 tcp "cluster management (join)"
            printf 'manager %s %s %s\n' 7946 tcp "gossip (control plane)"
            printf 'manager %s %s %s\n' 7946 udp "gossip (control plane)"
            printf 'manager %s %s %s\n' 4789 udp "VXLAN overlay data" ;;
        swarm-worker)
            printf 'worker %s %s %s\n' 7946 tcp "gossip (control plane)"
            printf 'worker %s %s %s\n' 7946 udp "gossip (control plane)"
            printf 'worker %s %s %s\n' 4789 udp "VXLAN overlay data" ;;
        engine-worker)
            case "$port" in 9830|9840|9850|9860) ;; *)
                [ -n "$port" ] || { log_error "engine-worker needs a port: 9830 (board) | 9840 (formal) | 9850 (esp) | 9860"; return 1; }
                log_warn "engine-worker $port is not one of the known hw/engine ports (9830|9840|9850|9860) — emitting it anyway" ;;
            esac
            printf 'worker %s %s %s\n' "$port" tcp "hw/engine worker API (direct call, not mesh)" ;;
        *) log_error "unknown binding '$binding' (swarm-manager|swarm-worker|engine-worker <port>)"; return 1 ;;
    esac
}

net_needs_print() {  # net_needs_print <binding> [port] — the `pol net needs` table
    local binding=$1 port=${2:-} rows
    rows=$(net_needs "$binding" "$port") || return 1
    pol_box "net needs: $binding${port:+ $port}"
    printf '  %-8s %-6s %-5s %s\n' SIDE PORT PROTO PURPOSE
    printf '%s\n' "$rows" | while read -r side p proto purpose; do
        printf '  %-8s %-6s %-5s %s\n' "$side" "$p" "$proto" "$purpose"
    done
}
