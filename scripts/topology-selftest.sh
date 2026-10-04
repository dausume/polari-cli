#!/bin/bash
# topology-selftest.sh — topo-closure-1 (mod-env-4): `pol topology modules-env`
# (and the swarm render path that reads it, lib/core-api.sh's
# resolve_polari_modules) asked a RUNNING backend to resolve the
# requires-closure of an instance's assigned modules; the backend answers
# from the manifests baked into ITS OWN (possibly old) image, so a module
# assigned on a newer checkout but absent from that image contributed NO
# requires at all — found live: `pol topology modules-env prf-a` missed
# `grpcbridge`, required by `hwnocode`, because the deployed image predated
# both. The fix (scripts/lib/checkout_module_closure.py +
# core-api.sh's checkout_closure_union) recomputes the SAME closure from the
# checkout's own manifests and unions it in, WARNing by name for every module
# only the checkout knows about.
#
# No real docker/core/network touched: `core_api` is overridden in-process
# with a canned FAKE backend answer (a real transport is lib/core-api.sh's
# own concern, already exercised elsewhere); this file only proves the
# checkout-closure math and its wiring into resolve_polari_modules /
# `pol topology modules-env`.
#
#   topology-selftest.sh [-v] [--help]   → prints N/N and exits non-zero on a miss
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
case "${1:-}" in -v) VERBOSE=1 ;; --help|-h) sed -n '2,19p' "$0"; exit 0 ;; esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1" || true; }
bad()  { FAIL=$((FAIL+1)); printf '  MISS %s\n     expected: %s\n     got: %s\n' "$1" "$2" "${3//$'\n'/ | }"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "NOT …$2…" "$3" ;; *) ok "$1" ;; esac; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# ---------------------------------------------------------------- a scratch checkout (fake manifests)
MODS="$T/modules"
mkdir -p "$MODS/alpha" "$MODS/beta" "$MODS/gamma"
cat > "$MODS/polari-modules.json" <<'JSON'
{"schema_version": 1, "modules": {
  "alpha": {"requires": []},
  "beta": {"requires": ["alpha"]},
  "gamma": {"requires": ["beta", "delta"]}
}}
JSON
# gamma's OWN polari-app.json (per-module manifest) is more precise than the
# mirror above and must WIN — it also names 'epsilon', which polari-modules.json
# does not know about at all (a module split into its own repo after that
# mirror was last regenerated).
cat > "$MODS/gamma/polari-app.json" <<'JSON'
{"requires": {"modules": ["beta", "delta", "epsilon"]}}
JSON
# delta/epsilon have no code checked out at all (module_code_dir would say
# "not downloaded") — the closure must still NAME them (never a KeyError).

# ---------------------------------------------------------------- the checkout closure script, standalone
CLOSURE="$HERE/lib/checkout_module_closure.py"
out=$(python3 "$CLOSURE" "$MODS" "gamma" "gamma")
has  "closure script: gamma's own polari-app.json wins over polari-modules.json's mirror (names epsilon too)" '"epsilon"' "$out"
has  "closure script: beta pulled in transitively" '"beta"' "$out"
has  "closure script: delta pulled in (named even with no code on disk)" '"delta"' "$out"
has  "closure script: added_by_checkout names gamma as the reason for delta" '"delta": ["gamma"]' "$out"

out2=$(python3 "$CLOSURE" "$MODS" "alpha" "alpha,beta")
has  "closure script: nothing added when the backend env already covers the closure" '"added_by_checkout": {}' "$out2"

badmods=$(python3 "$CLOSURE" "$T/does-not-exist" "alpha" "alpha" 2>&1)
rc=$?
eq  "closure script: a missing modules dir is a clean empty closure, never a crash" 0 "$rc"

# ---------------------------------------------------------------- wired into core-api.sh (resolve_polari_modules)
export SCRIPT_DIR="$HERE"
export POL_SUITE_ROOT="$T/suite"
export POL_RF_NODE="$POL_SUITE_ROOT/polari-rf-node"
mkdir -p "$POL_RF_NODE/polari-framework"
touch "$POL_SUITE_ROOT/setup-polari-security.sh"   # log.sh's "is this the suite" probe
ln -sfn "$MODS" "$POL_RF_NODE/polari-framework/modules"
# shellcheck source=lib/log.sh
source "$HERE/lib/log.sh"
# shellcheck source=lib/core-api.sh
source "$HERE/lib/core-api.sh"

# unit: checkout_closure_union directly (the backend "forgot" delta+epsilon)
union_out=$(checkout_closure_union "gamma,beta" "gamma" 2>"$T/warn.log")
eq  "checkout_closure_union: unioned csv carries every module (sorted)" "alpha,beta,delta,epsilon,gamma" "$union_out"
has "checkout_closure_union: WARNs name delta, required by gamma" "closure from the checkout: +delta (required by gamma" "$(cat "$T/warn.log")"
has "checkout_closure_union: WARNs name epsilon too" "+epsilon (required by gamma" "$(cat "$T/warn.log")"
hasnt "checkout_closure_union: never WARNs about a module the backend already had" "+gamma " "$(cat "$T/warn.log")"

# unit: nothing missing -> no warn at all, csv unchanged (just re-sorted)
quiet_out=$(checkout_closure_union "alpha,beta" "alpha" 2>"$T/warn2.log")
eq  "checkout_closure_union: a closure the backend already covers warns about nothing" "" "$(cat "$T/warn2.log")"
eq  "checkout_closure_union: …and still returns the full (sorted) set" "alpha,beta" "$quiet_out"

# integration: resolve_polari_modules with a FAKE core_api (the backend's OWN
# answer is missing delta/epsilon — exactly the live finding's shape)
core_api() {  # override: a canned backend answer naming only gamma+beta
    case "$1 $2" in
        "GET /api/topology/modules-env/prf-a")
            printf '{"ok": true, "instance": "prf-a", "topology": "fake", "count": 2, "env": "beta,gamma", "assigned": ["gamma"], "addedByRequires": {"beta": ["gamma"]}}' ;;
        *) return 1 ;;
    esac
}
unset POLARI_MODULES
resolve_out=$( { resolve_polari_modules prf-a >/dev/null; echo "$POLARI_MODULES"; } 2>"$T/warn3.log")
eq  "resolve_polari_modules: POLARI_MODULES is the UNIONED closure, not just the backend's env" "alpha,beta,delta,epsilon,gamma" "$resolve_out"
has "resolve_polari_modules: WARNs naming the module the running image never resolved" "closure from the checkout: +delta (required by gamma" "$(cat "$T/warn3.log")"

# a hand-set POLARI_MODULES still wins outright (loudly, no closure math run)
export POLARI_MODULES="just-this-one"
resolve_polari_modules prf-a >"$T/override.log" 2>&1
eq  "resolve_polari_modules: a hand-set POLARI_MODULES is kept verbatim (an OVERRIDE, warned)" "just-this-one" "$POLARI_MODULES"
has "resolve_polari_modules: …and says so" "OVERRIDING the topology rows" "$(cat "$T/override.log")"
unset POLARI_MODULES

# ---------------------------------------------------------------- integration: `pol topology modules-env`
# topology.sh re-sources the REAL lib/core-api.sh itself, so an exported
# `core_api` shell function would just be clobbered — fake the transport one
# layer down instead (docker ps / docker exec), the same way the rest of the
# suite's selftests fake docker.
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<DOCKER
#!/bin/bash
case "\$1 \$2" in
    "ps --format")
        echo "prf-backend" ;;
    "exec -i")
        printf '{"ok": true, "instance": "prf-a", "topology": "fake", "count": 2, "env": "beta,gamma", "assigned": ["gamma"], "addedByRequires": {"beta": ["gamma"]}}' ;;
    *) exit 1 ;;
esac
DOCKER
chmod +x "$BIN/docker"
out_cli=$(cd "$T" && env PATH="$BIN:$PATH" POL_SUITE_ROOT="$POL_SUITE_ROOT" POL_RF_NODE="$POL_RF_NODE" \
    bash "$HERE/topology.sh" modules-env prf-a 2>&1)
has "pol topology modules-env: still prints the backend's own assigned/addedByRequires lines" "assigned: gamma" "$out_cli"
has "pol topology modules-env: the printed POLARI_MODULES is the UNIONED closure" "POLARI_MODULES=alpha,beta,delta,epsilon,gamma" "$out_cli"
has "pol topology modules-env: WARNs naming delta+epsilon the running image never resolved" "closure from the checkout: +delta" "$out_cli"

echo "$PASS/$((PASS+FAIL)) topology-selftest checks passed"
[ "$FAIL" -eq 0 ]
