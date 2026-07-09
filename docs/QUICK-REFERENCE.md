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

Knobs honored everywhere: `LOCAL_IP`, `POLARI_SUITE_ROOT`, and the
credential knobs (`POLARI_KC_ADMIN_PASS`, `POLARI_MYSQL_ROOT_PASS`,
`POLARI_KC_DB_PASS`, `POLARI_PSC_DB_PASS`, `POLARI_MINIO_ROOT_USER/_PASS`,
`POLARI_MARIADB_ROOT_PASS`, `POLARI_OBJECTS_DB_PASS`, `POLARI_KEYDB_PASS`).

Gotchas:
- Standalone node and combined suite share container names — run one.
- Combined staging first `up`: prf-backend healthcheck can flap on a cold
  seed and block pol-proxy — re-run `pol suite up` once it's healthy.
