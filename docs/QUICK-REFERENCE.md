# pol — quick reference

```
pol help                                overview (from the command table)
pol <module> help                       per-module help

# Security substrate (everything self-generating; skip-if-exists)
pol security setup [dev|prod] [--env-only|--certs-only|--skip-subs]
pol security node-setup [staging|prod]  PRF standalone env + .generated
pol security status                     which credential files exist / legacy
pol security cleanup                    remove all generated certs+creds

# Compose orchestration (the existing compose family)  [alias: c]
# Env tiers per project: rf-node has dev|test|staging|prod(+stateless);
# suite root has dev|staging|prod (test exists only at rf-node level).
pol compose suite|node <action> [--env E]     full roles
pol compose engines|dask up|down|ps|logs      independent service deploys
pol compose twin <args>                       via twin-polari-build.sh
pol compose node up backend                   any single service by name
pol suite … / pol node …                      shortcuts for the two main roles
pol suite urls                                staging nip.io URLs

# Swarm orchestration (the isle-mesh STAND-IN) — LIVE
pol swarm init|status|join-token              cluster management
pol swarm render|deploy|rm|ps|services <role> stacks (roles: engines|suite|node)
#   engines proven E2E; suite/node conflict with their compose twins (refuse)
#   v1 inlines generated env values via compose-config; secrets = refinement

# Bridging devices OPENS the ports it needs — with your consent
pol swarm ports <node> [--apply] [--yes]   check (default) or open CLOSED
                                            ports: a single y/N (or sudo
                                            itself) per host, never a
                                            blanket 'allow <port>'
pol swarm join <node> [--no-apply] [--yes] does the handshake by default
pol swarm leave <node>                     hands back what join opened,
                                            then leaves (no duplicate logic)
pol net needs <binding> [port]             the port-needs TABLE (data, not
                                            prose): swarm-manager|swarm-worker|
                                            engine-worker <port>
pol net handback [<node>] [--peer p] [--apply]   the hand-back journal
                                            (~/.polari/handback/firewall.jsonl);
                                            --apply replays the undo in
                                            reverse, same consent rules
#   never prompts/applies in a pipeline or CI (POL_ASSUME_NO=1 forces that
#   refusal on purpose); firewalld/nftables hosts get the equivalent
#   command printed, never applied (ufw-only automation)

# Generated nginx proxies (replaces the sed .template path)
pol proxy render|check|promote|status         check = nginx -t in a container
#   rf prod render needs POLARI_PROD_DOMAIN exported

# ssh deploys to configured nodes (pol-build/manifests/nodes.yml)
pol deploy nodes|preflight <node>
pol deploy run <node> --role engines|remote-worker|node [--dry-run]
#   push branches first — targets pull the PUBLIC github repos

# Isle-mesh mode (future) — refuses; swarm stands in
pol isle

# Service accountability                                [alias: reg, services]
pol registry list|show <kind>|interconnects|check

# Topology as core-instance data (top-1..8)              [alias: top, topo]
pol topology status|graph|validate|diff        read views (drift + findings)
pol topology pull|push [file]                  rows <-> topologies/*.topology.yml
pol topology report [--node <n>]               observe what actually runs
pol topology render|apply [--plan]             rows -> manifests -> running (parity-gated)
pol topology deploy <package> [--plan]         portable-package flow (push+render+apply)
pol topology assign <module> <instance>        move a module (rows only)
pol allocate <module|instance> <instance|machine>   targeted deploy (swarm placement)
pol swarm join <node>                          drive a nodes.yml machine into the swarm

# Effective configuration (read-only; nested per-service) [alias: cfg]
pol config show|knobs|env|generated
pol config service <kind> [show|files|knobs|connects]

# Database backend per PRF instance
pol db show|options
pol db use combo|sqlite --role twin        primary switching = honest refusal

# PRF feature modules                                     [alias: mod]
pol modules list|deps|selftest <module>    enable/disable -> pol topology assign

# Certificates per env tier                               [alias: certs, ca]
pol cert setup|issue|verify|walkthrough|renew
pol cert prod self-signed | pol cert prod letsencrypt [--dry-run]
pol cert auto-renew install|status|remove  (open-source cron + certbot)

# Build pipeline (jinja-script)                        [alias: b]
pol build render [--topology single|swarm]   swarm = bld-5, refuses today
pol build parity                             semantic compose-config diff
pol build detect [dir]                       list jinja-annotated files
pol build clean                              rm rendered jinja-build/

# CA toolkit                                           [alias: certs, ca]
pol cert setup|issue|renew|verify|walkthrough
```

## Bridging devices opens ports with consent

`pol swarm join <node>` bridges two devices (this manager and a worker) —
that needs ports open between them. Instead of only printing `sudo ufw
allow …` lines for a person to run by hand, the join/ports handshake can
run that line itself, with consent, every time:

1. **check** — `check_swarm_ports` (unchanged) probes node→manager on
   2377/tcp, 7946/tcp+udp, 4789/udp and reports which are CLOSED.
2. **detect** — is `ufw` active on this host? Inactive/absent ⇒ nothing to
   do. `firewalld`/`nftables` ⇒ the equivalent command is PRINTED, never
   applied (pol only automates ufw).
3. **skip** — a rule already present in `ufw status` is left alone
   (idempotent; pol never re-adds what's already there).
4. **ask** — one prompt lists every rule for that host:
   `apply these N rules on <host>? [y/N]`. No TTY, `POL_ASSUME_NO=1`, or a
   CI environment ⇒ never prompts, never applies, only prints the lines —
   a pipeline can never open a port. `--yes` skips the prompt for a person
   who already decided; `sudo` is still the real gate (it asks for a
   password unless it's already passwordless on that host).
5. **apply** — every rule is SOURCE-SCOPED: `sudo ufw allow from <peer ip>
   to any port <p> proto <tcp|udp> comment 'polari <binding> <peer>'`.
   Never a blanket `allow <port>`.
6. **journal** — every rule actually applied is appended as one JSON line
   to `~/.polari/handback/firewall.jsonl` **on the host it touched**
   (`{ts, host, binding, peer, rule, undo, comment}`), and the ports are
   re-checked so the transcript shows the before/after.

`pol swarm ports <node> --apply` does this check-only; `pol swarm join
<node>` does it by default (`--no-apply` for the old print-only
behaviour). `pol net needs <binding> [port]` prints the port-needs table
a binding draws its rules from (`swarm-manager`, `swarm-worker`,
`engine-worker <port>` — data, not prose). `pol net handback [<node>]
[--peer <label>] [--apply]` lists — or, with `--apply`, REPLAYS IN
REVERSE and shrinks — the hand-back journal, under the same consent
rules. `pol swarm leave <node>` calls that hand-back on both hosts before
delegating the actual leave to the existing `pol deploy uninstall --route
swarm-worker` route (no duplicated `docker swarm leave` logic).

Knobs honored everywhere: `LOCAL_IP`, `POLARI_SUITE_ROOT`, and the
credential knobs (`POLARI_KC_ADMIN_PASS`, `POLARI_MYSQL_ROOT_PASS`,
`POLARI_KC_DB_PASS`, `POLARI_PSC_DB_PASS`, `POLARI_MINIO_ROOT_USER/_PASS`,
`POLARI_MARIADB_ROOT_PASS`, `POLARI_OBJECTS_DB_PASS`, `POLARI_KEYDB_PASS`).

Gotchas:
- Standalone node and combined suite share container names — run one.
- Combined staging first `up`: prf-backend healthcheck can flap on a cold
  seed and block pol-proxy — re-run `pol suite up` once it's healthy.
