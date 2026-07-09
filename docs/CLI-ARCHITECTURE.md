# pol CLI architecture

Two-tier dispatch, copied deliberately from the Isle-Mesh `isle` CLI (the
reference implementation lives on isle-core at
`/home/detts/Isle-Mesh/isle-cli/`).

## Tier 1 — `index.js` (Node dispatcher)

- Installed as `pol` via the `/usr/local/bin/pol` symlink
  (`shells/cli-paths.sh` is the single source of truth for that path;
  every install/uninstall route goes through it, so a machine can never
  end up with two competing `pol` binaries).
- **The command table is the single source of truth**: one declarative
  object maps `name → { script, desc, aliases?, docker?, deprecated? }`.
  Routing, alias resolution, `pol help` output, script validation, and
  preconditions are all DERIVED from the table — there is no switch-case
  to keep in sync.
- Dispatch is uniform: `bash scripts/<script> <subcommand> <args...>`
  with `stdio: inherit` and the child's exit code propagated. The Node
  layer never prints stack traces for script failures — the script is
  responsible for its own error message.
- `namespacelessCommands` guards bare verbs (`pol up` → "needs a
  namespace: pol node up / pol suite up").
- `docker: true` entries get a docker-daemon reachability check before
  dispatch (precondition hook pattern).
- Suite-root resolution: polari-cli normally sits inside the polari-suite
  checkout, so the root is `dirname(CLI_DIR)`; `POLARI_SUITE_ROOT`
  overrides for out-of-tree installs. The resolved root is exported to
  tier-2 scripts as `POL_SUITE_ROOT` (plus `POL_CLI_DIR`), and scripts
  run with `cwd = suite root`.

## Tier 2 — `scripts/<module>.sh` (bash namespace dispatchers)

Each module script:

- sources `scripts/lib/log.sh` (shared colors + `log_info/success/warn/
  error`, `die`, `pol_box` — deliberately factored out instead of the
  per-script duplication the isle CLI has);
- defines a boxed `show_help()` reached by `pol <module> help` or a bare
  `pol <module>`;
- routes with `case "$COMMAND" in ... esac`, `exec bash`-ing leaf scripts
  or the suite's existing setup/compose machinery;
- REFUSES not-yet-built capabilities by naming the phase that adds them
  (knobs-and-suggestions: honest absence over silent no-ops) — e.g.
  `pol build render --topology swarm` explains swarm arrives in bld-5.

## Conventions

- Leaf work lives in the suite's own scripts wherever they exist
  (setup-polari-security.sh, nip-staging-setup.sh, staging-setup.sh,
  jinja-gen/, ca/) — the CLI orchestrates, it does not fork logic.
- Every stateful default is overridable: `--env`, `LOCAL_IP`,
  `POLARI_*` credential knobs pass straight through.
- Self-healing setup: `pol suite up` / `pol node up` detect missing
  generated files and run the right setup script first (the credential
  substrate is skip-if-exists, so this is always safe).
