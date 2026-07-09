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
pol compose suite|node <action> [--env E]     full roles
pol compose engines|dask up|down|ps|logs      independent service deploys
pol compose twin <args>                       via twin-polari-build.sh
pol compose node up backend                   any single service by name
pol suite … / pol node …                      shortcuts for the two main roles
pol suite urls                                staging nip.io URLs

# Swarm orchestration (the isle-mesh STAND-IN)
pol swarm init|status|join-token              working today
pol swarm render|secrets|deploy|rm|ps         arrive with bld-5 (refuse now)

# Isle-mesh mode (future) — refuses; swarm stands in
pol isle

# Service accountability                                [alias: reg, services]
pol registry list|show <kind>|interconnects|check

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
