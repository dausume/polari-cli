# Adding a command to pol

Three steps; the table does the rest.

## 1. Add a row to the command table (`index.js`)

```js
const commands = {
  ...
  deploy: { script: 'deploy.sh', desc: 'ssh deploy to a configured node', docker: true },
};
```

Fields: `script` (tier-2 dispatcher under `scripts/`), `desc` (feeds
`pol help`), optional `aliases: ['d']`, `docker: true` (daemon
precondition), `deprecated: 'use X instead'`.

## 2. Create the namespace script (`scripts/deploy.sh`)

Skeleton every module follows:

```bash
#!/bin/bash
# pol deploy — one-line purpose.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"     # colors, log_*, die, pol_box, POL_SUITE_ROOT

show_help() {
    pol_box "pol deploy — <purpose>"
    echo -e "
${BOLD}COMMANDS${NC}
  ${CYAN}<sub>${NC} <args>    what it does
"
}

COMMAND=$1; shift || true
case "$COMMAND" in
    <sub>)  ... ;;
    help|-h|--help|"") show_help ;;
    *) log_error "Unknown deploy command: $COMMAND"; show_help; exit 1 ;;
esac
```

Rules:
- source `lib/log.sh`; never redefine colors/loggers locally.
- `show_help()` is mandatory and must list EVERY subcommand + option.
- A capability that exists but has unmet preconditions REFUSES with the
  exact fix (`die "swarm not initialized — run: docker swarm init"`), it
  never silently degrades.
- Delegate to existing suite scripts instead of duplicating their logic.

## 3. Document it

- `docs/QUICK-REFERENCE.md`: add the command lines.
- If it fronts new machinery, add/extend the relevant section in
  `BUILD_SYSTEM_PLAN.md` at the suite root.

No install step is needed — the dev install symlinks the live checkout,
and `index.js` chmod +x's tier-2 scripts on the fly.
