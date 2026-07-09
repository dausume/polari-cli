#!/usr/bin/env node
/**
 * pol — the Polari suite CLI.
 *
 * Two-tier dispatcher modeled on the Isle-Mesh CLI:
 *   Tier 1 (this file): a SINGLE DECLARATIVE COMMAND TABLE is the source of
 *     truth for routing, aliases, preconditions, deprecations and help.
 *   Tier 2 (scripts/*.sh): one bash namespace dispatcher per module, each
 *     with its own boxed show_help(); leaves do the real work.
 *
 * Dispatch is uniform: `bash scripts/<script> <subcommand> <args...>` with
 * inherited stdio and the child's exit code propagated (no Node stack
 * traces on script failure).
 *
 * Docs: docs/CLI-ARCHITECTURE.md (how this works), docs/EXTENSION-GUIDE.md
 * (how to add a command), docs/QUICK-REFERENCE.md (cheat sheet).
 */

const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

// Resolve the real location of this file even when invoked through the
// /usr/local/bin/pol symlink (see shells/cli-paths.sh).
const CLI_DIR = path.dirname(fs.realpathSync(__filename));
const scriptsDir = path.join(CLI_DIR, 'scripts');

// The polari-cli checkout normally lives INSIDE the polari-suite checkout;
// POLARI_SUITE_ROOT overrides for out-of-tree installs.
function resolveSuiteRoot() {
  const candidates = [
    process.env.POLARI_SUITE_ROOT,
    path.dirname(CLI_DIR),
  ].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(path.join(c, 'setup-polari-security.sh'))) return c;
  }
  return null;
}

// ============================================================================
// THE COMMAND TABLE — single source of truth.
// name → { script, desc, aliases?, docker?, deprecated? }
//   script     tier-2 dispatcher under scripts/
//   desc       one-liner; feeds help output AND docs
//   aliases    alternative names resolved to the canonical one
//   docker     true → verify the docker daemon is reachable before dispatch
//   deprecated string → print notice, still dispatch
// ============================================================================
// Orchestration modes are first-class namespaces: compose (defined by the
// existing compose family) | swarm (being defined now — the isle-mesh
// stand-in) | isle (future, refuses honestly). node/suite are shortcuts
// into compose's two main roles.
const commands = {
  security: { script: 'security.sh', desc: 'Credential + cert setup (self-generating)', aliases: ['sec'] },
  start:    { script: 'lifecycle.sh', injectArgs: ['start'],   desc: 'Bring the last configured build up',  docker: true },
  rebuild:  { script: 'lifecycle.sh', injectArgs: ['rebuild'], desc: 'Rebuild the last configured build from scratch', docker: true },
  stop:     { script: 'lifecycle.sh', injectArgs: ['stop'],    desc: 'Stop the last configured build',      docker: true },
  last:     { script: 'lifecycle.sh', injectArgs: ['last'],    desc: 'Show the recorded build approach' },
  config:   { script: 'config.sh',   desc: 'Effective config + nested per-service views', aliases: ['cfg'] },
  compose:  { script: 'compose.sh',  desc: 'Compose orchestration: suite|node|engines|dask|twin roles', aliases: ['c'], docker: true },
  swarm:    { script: 'swarm.sh',    desc: 'Swarm orchestration — the isle-mesh stand-in', docker: true },
  isle:     { script: 'isle.sh',     desc: 'Isle-mesh mode (future; swarm stands in today)' },
  node:     { script: 'node.sh',     desc: 'Shortcut for `pol compose node`',   docker: true },
  suite:    { script: 'suite.sh',    desc: 'Shortcut for `pol compose suite`',  docker: true },
  db:       { script: 'db.sh',       desc: 'Database backend per PRF instance (sqlite|combo)', docker: true },
  modules:  { script: 'modules.sh',  desc: 'PRF feature modules: list, deps, selftests', aliases: ['mod'] },
  build:    { script: 'build.sh',    desc: 'jinja-script build pipeline (render/parity)', aliases: ['b'] },
  proxy:    { script: 'proxy.sh',    desc: 'Generated nginx configs (render/check/promote)', docker: true },
  registry: { script: 'registry.sh', desc: 'Service-kind accountability + interconnect map', aliases: ['reg', 'services'] },
  cert:     { script: 'cert.sh',     desc: 'Certs per env tier; prod: self-signed OR Let\'s Encrypt + auto-renew', aliases: ['certs', 'ca'] },
};

// Bare verbs that people will guess; they need a namespace. Guard them with
// a helpful error instead of a silent unknown-command failure.
const namespacelessCommands = ['up', 'down', 'logs', 'ps', 'render', 'parity', 'setup', 'deploy'];
// (start/rebuild/stop are deliberately namespaceless — they replay the
// recorded last-build approach; see scripts/lifecycle.sh)

const aliasMap = {};
for (const [name, def] of Object.entries(commands)) {
  for (const a of def.aliases || []) aliasMap[a] = name;
}
const resolve = (name) => (commands[name] ? name : aliasMap[name]);

function validateScripts() {
  let ok = true;
  for (const def of Object.values(commands)) {
    const p = path.join(scriptsDir, def.script);
    try {
      const st = fs.statSync(p);
      if ((st.mode & fs.constants.S_IXUSR) === 0) fs.chmodSync(p, st.mode | 0o755);
    } catch {
      console.error(`pol: missing tier-2 script: ${p}`);
      ok = false;
    }
  }
  return ok;
}

function checkDocker() {
  const r = spawnSync('docker', ['info'], { stdio: 'ignore' });
  if (r.status !== 0) {
    console.error('pol: docker daemon not reachable. Is docker running, and is your user in the docker group?');
    process.exit(1);
  }
}

const C = { cyan: '\x1b[36m', yellow: '\x1b[33m', bold: '\x1b[1m', dim: '\x1b[2m', nc: '\x1b[0m' };

function showHelp() {
  const rows = Object.entries(commands)
    .map(([name, d]) => `  ${C.cyan}pol ${name.padEnd(9)}${C.nc} ${d.desc}${d.aliases ? C.dim + '  (alias: ' + d.aliases.join(', ') + ')' + C.nc : ''}`)
    .join('\n');
  console.log(`${C.bold}╔══════════════════════════════════════════════════════════╗
║  pol — Polari suite CLI                                  ║
╚══════════════════════════════════════════════════════════╝${C.nc}

${rows}

  ${C.cyan}pol help${C.nc}       this overview; ${C.cyan}pol <module> help${C.nc} for module details

${C.bold}Quick start${C.nc}
  pol security setup          generate ALL credentials (random, no prompts)
  pol suite up --env staging  bring up the combined prf+psc staging stack
  pol build parity            verify generated compose files match hand-written

Docs: polari-cli/docs/  (INDEX.md → architecture, extension, quick reference)`);
}

// ============================================================================
// Dispatch
// ============================================================================
const command = process.argv[2];
const rest = process.argv.slice(3);

if (!validateScripts()) process.exit(1);
if (command === undefined || command === 'help' || command === '--help' || command === '-h') {
  showHelp();
  process.exit(0);
}
if (namespacelessCommands.includes(command)) {
  console.error(`pol: '${command}' needs a namespace — try one of:`);
  for (const [name, d] of Object.entries(commands)) console.error(`  pol ${name} ${command}`);
  process.exit(1);
}

const canonical = resolve(command);
const def = canonical && commands[canonical];
if (!def) {
  console.error(`pol: unknown command '${command}'. Run 'pol help'.`);
  process.exit(1);
}
if (def.deprecated) console.error(`${C.yellow}pol: '${command}' is deprecated — ${def.deprecated}${C.nc}`);
if (def.docker) checkDocker();

const suiteRoot = resolveSuiteRoot();
if (!suiteRoot) {
  console.error('pol: cannot locate the polari-suite root (looked for setup-polari-security.sh).');
  console.error('     Set POLARI_SUITE_ROOT=/path/to/polari-suite and retry.');
  process.exit(1);
}

const scriptPath = path.join(scriptsDir, def.script);
const allArgs = [...(def.injectArgs || []), ...rest];
try {
  execSync(`bash ${JSON.stringify(scriptPath)} ${allArgs.map((a) => JSON.stringify(a)).join(' ')}`, {
    stdio: 'inherit',
    cwd: suiteRoot,
    env: { ...process.env, POL_SUITE_ROOT: suiteRoot, POL_CLI_DIR: CLI_DIR },
  });
} catch (error) {
  process.exit(error.status || 1); // the script printed its own error
}
