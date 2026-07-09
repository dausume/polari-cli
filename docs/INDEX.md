# pol CLI — documentation index

`pol` is the Polari suite's command-line tool: one entry point for the
security substrate, the build pipeline (jinja-script), stack lifecycles,
and (in later phases) swarm output + ssh deploys. It is modeled on the
Isle-Mesh `isle` CLI (two-tier dispatch, declarative command table).

| Doc | What it covers |
|---|---|
| [QUICK-REFERENCE.md](QUICK-REFERENCE.md) | Every command on one page |
| [CLI-ARCHITECTURE.md](CLI-ARCHITECTURE.md) | How dispatch works (table → namespace script → leaf), suite-root resolution, conventions |
| [EXTENSION-GUIDE.md](EXTENSION-GUIDE.md) | Add a command in 3 steps |
| `../../BUILD_SYSTEM_PLAN.md` | The build revamp this CLI fronts: jinja-script, per-service files, swarm, proxy generation, ssh deploys (phases bld-1…bld-7) |

## Install

```bash
cd polari-suite/polari-cli
./shells/install-cli.sh        # symlinks the live checkout as /usr/local/bin/pol
pol help
```

Built-in help is always current: `pol help` (overview, generated from the
command table) and `pol <module> help` (per-module details).
