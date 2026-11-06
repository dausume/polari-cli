#!/bin/bash
# bench.sh — `pol bench`: every Bench Solution action the Workbench / Runs pages do, as a command (cis arc,
# COHERENT_ISLE_WORK_SPLIT.md). Thin client over the EXISTING backend doors; no logic of its own, no root, no isle.
#
#   pol bench help
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/pol-api.sh"

usage() {
printf '%b\n' "$(cat <<USAGE
${BOLD}pol bench${NC} — Bench Solutions, their topology, runs, captures and coverage, over a backend's HTTP API (cis arc)

  Shared flags (anywhere): ${CYAN}--api https://api.<name>.isle${NC} (else \$POL_API / \$POLARI_API, else the local docker backend)
                           ${CYAN}--json${NC} print the backend's own body verbatim
  Exit: 0 ok · 1 refused (the backend said no; its words on stderr) · 2 unreachable / usage.
        For CHECK verbs (status, coverage untested) exit 1 also means "not green" — the line says which.

  ${CYAN}list${NC}                                 Bench Solutions with whole/missing          GET /api/board/bench-solutions
  ${CYAN}show <bench>${NC}                         the whole check and every leg               GET /api/board/bench-solutions/<b>
  ${CYAN}legs <bench>${NC}                         the legs as rows                            GET .../bench-solutions/<b>/legs
  ${CYAN}status <bench>${NC}                       one screen: legs, nodes + last run, untested; exit 1 = NOT GREEN (composite of the doors below)
  ${CYAN}words${NC}                                the topology vocabulary                     GET /api/cmod/topology-words
  ${CYAN}specs${NC}                                shipped topology specs                      GET /api/cmod/topology-specs
  ${CYAN}apply-spec <bench> [--spec NAME]${NC}     apply the Bench System's spec               POST B/apply-spec
  ${CYAN}topology <bench>${NC}                     nodes, edges, events                        GET B
  ${CYAN}events <bench>${NC}                       the offered Hardware Events                 GET B (events)
  ${CYAN}predicted <bench> <event>${NC}            the chain the assertions predict            GET B/events/<e>/predicted
  ${CYAN}node add <bench> --file node.json${NC}    define a node + its incoming edge           POST B/nodes
      or flags: --slug S --from NODE --event EVENT [--title T] [--edge-kind trigger] [--require om:field:kind[:value]]... [--exec atom[:isotope]]...
  ${CYAN}edge add <bench> --from N --to N --event E [--kind K]${NC}   another path into a node   POST B/edges
  ${CYAN}run <bench> <node> [--pin] [--path P] [--profile P] [--play-from X]${NC}   one twin run; --pin keeps its capture (the only pin door)   POST B/nodes/<n>/run
  ${CYAN}run-all <bench>${NC}                      every state node by every path              POST B/run-all
  ${CYAN}retest <bench> [--catom C]${NC}           sync isotopes, re-run the affected nodes    POST B/retest
  ${CYAN}runs <bench> <node>${NC}                  a node's kept runs                          GET B/nodes/<n>/runs
  ${CYAN}signals|edges <bench> <run>${NC}          one run's rows                              GET B/runs/<r>/signals | /edges
  ${CYAN}captures <bench> <run>${NC}               the WaveformCaptures a run kept             GET B/runs/<r>/captures
  ${CYAN}vcd <bench> <run> [--acquisition A] [-o FILE]${NC}   the capture as VCD text          GET B/runs/<r>/vcd
  ${CYAN}diff <bench> <run> <other>${NC}           changes between two runs                    GET B/runs/<r>/diff?other=
  ${CYAN}coverage <bench> [untested|nodes|events|runs|assertions|strip-rows]${NC}   what is tested; 'untested' exits 1 when NOT GREEN   GET B/coverage[/x]
  ${CYAN}confirmations <bench> <node>${NC}         a person's confirmations                    GET B/nodes/<n>/confirmations
  ${CYAN}confirm <bench> <node> --who W --words "…" [--path P]${NC}                            POST B/nodes/<n>/confirm
  ${CYAN}hardware-record <bench> <node> --hex-sha256 H --source S [--field k=v]... [--duration-s S] [--path P]${NC}   POST B/nodes/<n>/hardware-record
  ${CYAN}check add <bench> --edge E --kind K --field F --value V [--tolerance T] [--bound-s S]${NC}   POST B/checks
  ${CYAN}profiles <bench>${NC} / ${CYAN}profile add <bench> --file p.json${NC}                   GET / POST B/profiles
  ${CYAN}canvas <bench> [--put FILE]${NC}          the no-code drawing (PUT: titles only)      GET / PUT B/canvas
  ${CYAN}structs <bench> [--view instances|fields|path|samples] [--instance I] [--field F] [--bridge B]${NC}   GET /api/cmod/bench-structs/<b>
  ${CYAN}step-rules <bench> [--variant V]...${NC}  derive the IsotopeStepRule rows             POST B/step-rules

  B = /api/cmod/bench-topology/<bench>.  <node> is the slug (on-by-button) or the full name (bench:on-by-button).
  Selftest: scripts/bench-selftest.sh (fake curl, no network)
USAGE
)"
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift
pol_api_flags "$@" || exit 2
set -- "${ARGS[@]+"${ARGS[@]}"}"

need() { [ -n "${1:-}" ] || die "usage: pol bench $2"; }
B() { printf '/api/cmod/bench-topology/%s' "$(pol_api_enc "$1")"; }
slug() { # node slug: strip a leading "<bench>:" when the full name was given
    local b=$1 n=$2; case "$n" in "$b:"*) n=${n#"$b:"} ;; esac; printf '%s' "$n"; }
out() { # out BODY — --json prints verbatim; else the given python pretty snippet reads it
    if [ "$JSON" = 1 ]; then printf '%s\n' "$1"; else printf '%s' "$1" | pretty "$2"; fi; }
call() { # call METHOD PATH [BODY] -> sets RESP; exits 1/2 on refusal/unreachable (body still printed under --json)
    local rc=0; RESP=$(pol_api "$@") || rc=$?
    if [ $rc -ne 0 ]; then [ "$JSON" = 1 ] && printf '%s\n' "$RESP"; exit $rc; fi; }
kv_json() { # kv_json k=v k=v ... -> JSON object (values: json literals when they parse, else strings)
    python3 -c '
import json,sys
o={}
for a in sys.argv[1:]:
    k,_,v=a.partition("=")
    try: o[k]=json.loads(v)
    except Exception: o[k]=v
print(json.dumps(o))' "$@"; }
# opt NAME DEFAULT — pull "--name value" pairs out of REST (set by take_opts)
take_opts() { # "--k v" pairs; a flag followed by another flag (or nothing) is boolean ("--pin" -> pin=1)
    OPTS=(); REST=(); while [ $# -gt 0 ]; do case "$1" in
        --*) case "${2:-}" in ""|--*) OPTS+=("${1#--}=1"); shift ;; *) OPTS+=("${1#--}=$2"); shift 2 ;; esac ;;
        *) REST+=("$1"); shift ;; esac; done; }
optval() { local k=$1 d=${2:-}; local o; for o in "${OPTS[@]+"${OPTS[@]}"}"; do case "$o" in "$k="*) printf '%s' "${o#*=}"; return ;; esac; done; printf '%s' "$d"; }
optvals() { local k=$1 o; for o in "${OPTS[@]+"${OPTS[@]}"}"; do case "$o" in "$k="*) printf '%s\n' "${o#*=}" ;; esac; done; }
hasflag() { local k=$1 o; for o in "${OPTS[@]+"${OPTS[@]}"}"; do case "$o" in "$k="*) return 0 ;; esac; done; return 1; }

case "$cmd" in
    help|-h|--help) usage ;;

    list) call GET /api/board/bench-solutions
        out "$RESP" '
for r in d.get("rows", []):
    print("  %-5s %-32s missing %-3s %s" % ("whole" if r.get("whole") else "-", r["name"], r.get("missing", "-"), (r.get("title") or "")[:70]))' ;;

    show) need "${1:-}" "show <bench>"; call GET "/api/board/bench-solutions/$(pol_api_enc "$1")"
        out "$RESP" '
print("  %s  whole=%s  %s" % (d["name"], d.get("whole"), d.get("title", "")))
for leg, r in sorted((d.get("legs") or {}).items()):
    print("  %-9s %-5s %-24s %s" % (leg, "ok" if r.get("ok") else "NOT", r.get("ref", "-"), (r.get("why") or "")[:90]))
for m in d.get("missing") or []: print("  missing:", m[:140])' ;;

    legs) need "${1:-}" "legs <bench>"; call GET "/api/board/bench-solutions/$(pol_api_enc "$1")/legs"
        out "$RESP" '
for r in d.get("rows", []): print("  %-9s %-5s %-24s %s" % (r["leg"], "ok" if r.get("ok") else "NOT", r.get("ref","-"), (r.get("why") or "")[:100]))' ;;

    words) call GET /api/cmod/topology-words
        out "$RESP" '
for k, v in d.items():
    if k != "ok": print("  %-18s %s" % (k, ", ".join(map(str, v)) if isinstance(v, list) else v))' ;;

    specs) call GET /api/cmod/topology-specs
        out "$RESP" '
for r in d.get("rows", []): print("  %-20s system %-18s nodes %-3s roles %s  %s" % (r["name"], r.get("bench_system"), r.get("nodes"), ",".join(r.get("roles") or []), (r.get("title") or "")[:50]))' ;;

    apply-spec) need "${1:-}" "apply-spec <bench> [--spec NAME]"; b=$1; shift; take_opts "$@"
        body='{}'; s=$(optval spec); [ -n "$s" ] && body=$(kv_json "spec=$s")
        call POST "$(B "$b")/apply-spec" "$body"
        out "$RESP" '
print("  [ OK ] spec %s on %s (variant %s): nodes %s, skipped %s" % (d.get("spec"), d.get("bench_solution"), d.get("variant"), len(d.get("nodes") or []), len(d.get("skipped") or [])))
for w in d.get("words") or []: print("   ", w)' ;;

    topology) need "${1:-}" "topology <bench>"; call GET "$(B "$1")"
        out "$RESP" '
print("  root:", d.get("root"))
for n in d.get("nodes", []):
    print("  %-7s %-40s paths %-2s %s%s" % (n.get("kind",""), n["name"], len(n.get("paths") or []), "BLOCKED " if n.get("blocked") else "", (n.get("title") or "")[:50]))
print("  edges:")
for e in d.get("edges", []): print("    %s -> %s  [%s] on %s" % (e.get("from_node"), e.get("to_node"), e.get("kind"), e.get("event")))
print("  events: " + ", ".join(ev["name"] for ev in d.get("events", [])))' ;;

    events) need "${1:-}" "events <bench>"; call GET "$(B "$1")"
        out "$RESP" '
for ev in d.get("events", []): print("  %-40s %-10s %-8s %s" % (ev["name"], ev.get("kind",""), ev.get("source",""), (ev.get("what") or ev.get("title") or "")[:60]))' ;;

    predicted) need "${2:-}" "predicted <bench> <event>"; call GET "$(B "$1")/events/$(pol_api_enc "$2")/predicted"
        out "$RESP" '
for r in d.get("rows", []): print("  " + json.dumps(r)[:160])' ;;

    node) sub=${1:-}; shift || true; [ "$sub" = add ] || die "usage: pol bench node add <bench> --file node.json | --slug S --from N --event E ..."
        need "${1:-}" "node add <bench> ..."; b=$1; shift; take_opts "$@"
        f=$(optval file)
        if [ -n "$f" ]; then [ -f "$f" ] || die "no such file: $f"; body=$(cat "$f")
        else
            s=$(optval slug); fr=$(optval from); ev=$(optval event)
            [ -n "$s" ] && [ -n "$fr" ] && [ -n "$ev" ] || die "node add needs --file, or --slug --from --event (plus --require/--exec)"
            body=$(python3 -c '
import json,sys
a=json.loads(sys.argv[1]); reqs=[]; execs=[]
for r in a["require"]:
    p=r.split(":"); o={"object_map":p[0],"field":p[1],"kind":p[2]}
    if len(p)>3: o["value"]=":".join(p[3:])
    reqs.append(o)
for e in a["exec"]:
    atom,_,iso=e.partition(":"); execs.append({"atom":atom,"isotope":iso} if iso else atom)
o={"slug":a["slug"],"from_node":a["from"],"event":a["event"],"edge_kind":a["edge_kind"] or "trigger","requirements":reqs,"executions":execs,"collaterals":a["collateral"]}
if a["title"]: o["title"]=a["title"]
print(json.dumps(o))' "$(python3 -c 'import json,sys; print(json.dumps({"slug":sys.argv[1],"from":sys.argv[2],"event":sys.argv[3],"edge_kind":sys.argv[4],"title":sys.argv[5],"require":sys.argv[6].split("\n") if sys.argv[6] else [],"exec":sys.argv[7].split("\n") if sys.argv[7] else [],"collateral":sys.argv[8].split("\n") if sys.argv[8] else []}))' "$s" "$fr" "$ev" "$(optval edge-kind)" "$(optval title)" "$(optvals require)" "$(optvals exec)" "$(optvals collateral)")")
        fi
        call POST "$(B "$b")/nodes" "$body"
        out "$RESP" 'print("  [ OK ] node %s  paths %s  requirements %s" % (d.get("name"), len(d.get("paths") or []), len(d.get("requirements") or [])))' ;;

    edge) sub=${1:-}; shift || true; [ "$sub" = add ] || die "usage: pol bench edge add <bench> --from N --to N --event E [--kind K]"
        need "${1:-}" "edge add <bench> ..."; b=$1; shift; take_opts "$@"
        fr=$(optval from); to=$(optval to); ev=$(optval event); [ -n "$fr" ] && [ -n "$to" ] && [ -n "$ev" ] || die "edge add needs --from --to --event"
        call POST "$(B "$b")/edges" "$(kv_json "from_node=$fr" "to_node=$to" "event=$ev" "kind=$(optval kind trigger)")"
        out "$RESP" 'print("  [ OK ] node %s now has %s path(s)" % (d.get("name"), len(d.get("paths") or [])))' ;;

    run) need "${2:-}" "run <bench> <node> [--pin] [--path P] [--profile P] [--play-from X]"; b=$1; n=$(slug "$1" "$2"); shift 2; take_opts "$@"
        kv=(); hasflag pin && kv+=("pin=true"); for k in path profile play-from; do v=$(optval "$k"); [ -n "$v" ] && kv+=("${k//-/_}=$v"); done
        call POST "$(B "$b")/nodes/$(pol_api_enc "$n")/run" "$(kv_json "${kv[@]+"${kv[@]}"}")"
        out "$RESP" '
r = d.get("run") or {}
print("  [ OK ] %s  outcome %s  hex %s  capture %s" % (r.get("name"), r.get("outcome"), (r.get("hex_sha256") or "")[:16], d.get("capture") or "-"))
for e in d.get("edges") or []: print("    edge %s  %s" % (e.get("name", e.get("kind","")), "met" if e.get("met") else e.get("words","")))' ;;

    run-all) need "${1:-}" "run-all <bench>"; call POST "$(B "$1")/run-all" '{}'
        out "$RESP" 'print("  [ OK ] %s: reached %s of %s, runs %s, untested %s" % (d.get("bench_solution"), d.get("reached"), d.get("of"), len(d.get("runs") or []), len(d.get("untested") or [])))' ;;

    retest) need "${1:-}" "retest <bench> [--catom C]"; b=$1; shift; take_opts "$@"; body='{}'; c=$(optval catom); [ -n "$c" ] && body=$(kv_json "catom=$c")
        call POST "$(B "$b")/retest" "$body"
        out "$RESP" 'print("  [ OK ] " + "; ".join(d.get("words") or [json.dumps(d)[:200]]))' ;;

    runs) need "${2:-}" "runs <bench> <node>"; call GET "$(B "$1")/nodes/$(pol_api_enc "$(slug "$1" "$2")")/runs"
        out "$RESP" '
for r in d.get("rows", []): print("  %-44s %-9s %-7s %s  hex %s" % (r["name"], r.get("outcome"), r.get("engine",""), r.get("ran_at",""), (r.get("hex_sha256") or "")[:12]))' ;;

    signals|edges) need "${2:-}" "$cmd <bench> <run>"; call GET "$(B "$1")/runs/$(pol_api_enc "$2")/$cmd"
        out "$RESP" '
for r in d.get("rows", []): print("  " + json.dumps(r)[:160])' ;;

    captures) need "${2:-}" "captures <bench> <run>"; call GET "$(B "$1")/runs/$(pol_api_enc "$2")/captures"
        out "$RESP" '
for r in d.get("rows", []): print("  %-24s %-8s %s" % (r.get("name") or r.get("id",""), r.get("kind",""), (r.get("words") or r.get("why") or "")[:100]))' ;;

    vcd) need "${2:-}" "vcd <bench> <run> [--acquisition A] [-o FILE]"; b=$1; r=$2; shift 2; q=''; o=''
        while [ $# -gt 0 ]; do case "$1" in --acquisition) q="?acquisition=$(pol_api_enc "$2")"; shift 2 ;; -o|--output) o=$2; shift 2 ;; *) shift ;; esac; done
        rc=0; RESP=$(pol_api GET "$(B "$b")/runs/$(pol_api_enc "$r")/vcd$q" '' --raw) || rc=$?; [ $rc -eq 0 ] || exit $rc
        if [ -n "$o" ]; then printf '%s\n' "$RESP" > "$o"; log_success "wrote $o"; else printf '%s\n' "$RESP"; fi ;;

    diff) need "${3:-}" "diff <bench> <run> <other>"; call GET "$(B "$1")/runs/$(pol_api_enc "$2")/diff?other=$(pol_api_enc "$3")"
        out "$RESP" '
rows = d.get("rows") or d.get("diff") or []
for r in rows: print("  " + json.dumps(r)[:160])
if not rows: print("  no differences")' ;;

    coverage) need "${1:-}" "coverage <bench> [untested|nodes|events|runs|assertions|strip-rows]"; b=$1; v=${2:-}
        p="$(B "$b")/coverage"; [ -n "$v" ] && p="$p/$v"; call GET "$p"
        out "$RESP" '
rows = d.get("rows") if isinstance(d, dict) else d
if isinstance(rows, list):
    for r in rows: print("  " + (r.get("words") if isinstance(r, dict) and "words" in r else json.dumps(r)[:160]))
    if not rows: print("  (none)")
else: print(json.dumps(d, indent=2)[:2000])'
        if [ "$v" = untested ]; then printf '%s' "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); n=len(d.get("rows") or []); sys.stderr.write("[NOT GREEN] %d untested\n" % n) if n else sys.stderr.write("[ OK ] nothing untested\n"); sys.exit(1 if n else 0)'; fi ;;

    confirmations) need "${2:-}" "confirmations <bench> <node>"; call GET "$(B "$1")/nodes/$(pol_api_enc "$(slug "$1" "$2")")/confirmations"
        out "$RESP" '
for r in d.get("rows", []): print("  %-12s %-24s %s" % (r.get("who",""), r.get("at", r.get("ran_at","")), (r.get("words") or "")[:100]))' ;;

    confirm) need "${2:-}" "confirm <bench> <node> --who W --words \"…\" [--path P]"; b=$1; n=$(slug "$1" "$2"); shift 2; take_opts "$@"
        w=$(optval who); s=$(optval words); [ -n "$w" ] && [ -n "$s" ] || die "confirm needs --who and --words"
        kv=("who=$w" "words=$s"); p=$(optval path); [ -n "$p" ] && kv+=("path=$p")
        call POST "$(B "$b")/nodes/$(pol_api_enc "$n")/confirm" "$(kv_json "${kv[@]}")"
        out "$RESP" 'print("  [ OK ] " + json.dumps(d)[:200])' ;;

    hardware-record) need "${2:-}" "hardware-record <bench> <node> --hex-sha256 H --source S [--field k=v]... [--duration-s S] [--path P]"; b=$1; n=$(slug "$1" "$2"); shift 2; take_opts "$@"
        h=$(optval hex-sha256); s=$(optval source); [ -n "$h" ] && [ -n "$s" ] || die "hardware-record needs --hex-sha256 and --source"
        fields=$(kv_json $(optvals field)); kv=("hex_sha256=$h" "source=$s" "fields=$fields"); dur=$(optval duration-s); [ -n "$dur" ] && kv+=("duration_s=$dur"); p=$(optval path); [ -n "$p" ] && kv+=("path=$p")
        call POST "$(B "$b")/nodes/$(pol_api_enc "$n")/hardware-record" "$(kv_json "${kv[@]}")"
        out "$RESP" 'print("  [ OK ] " + json.dumps(d)[:300])' ;;

    check) sub=${1:-}; shift || true; [ "$sub" = add ] || die "usage: pol bench check add <bench> --edge E --kind K --field F --value V [--tolerance T] [--bound-s S]"
        need "${1:-}" "check add <bench> ..."; b=$1; shift; take_opts "$@"
        kv=(); for k in edge kind field value tolerance bound-s; do v=$(optval "$k"); [ -n "$v" ] && kv+=("${k//-/_}=$v"); done
        [ ${#kv[@]} -ge 4 ] || die "check add needs --edge --kind --field --value"
        call POST "$(B "$b")/checks" "$(kv_json "${kv[@]}")"
        out "$RESP" 'print("  [ OK ] " + json.dumps(d)[:200])' ;;

    profiles) need "${1:-}" "profiles <bench>"; call GET "$(B "$1")/profiles"
        out "$RESP" '
for r in d.get("rows", []): print("  %-20s %s  items %s" % (r.get("name"), r.get("title",""), len(r.get("items") or [])))' ;;

    profile) sub=${1:-}; shift || true; [ "$sub" = add ] || die "usage: pol bench profile add <bench> --file p.json"
        need "${1:-}" "profile add <bench> --file p.json"; b=$1; shift; take_opts "$@"; f=$(optval file); [ -f "$f" ] || die "profile add needs --file p.json"
        call POST "$(B "$b")/profiles" "$(cat "$f")"
        out "$RESP" 'print("  [ OK ] " + json.dumps(d)[:200])' ;;

    canvas) need "${1:-}" "canvas <bench> [--put FILE]"; b=$1; shift; take_opts "$@"; f=$(optval put)
        if [ -n "$f" ]; then [ -f "$f" ] || die "no such file: $f"; call PUT "$(B "$b")/canvas" "$(python3 -c 'import json,sys; print(json.dumps({"definition": json.load(open(sys.argv[1]))}))' "$f")"
            out "$RESP" 'print("  [ OK ] %s  changes %s" % (d.get("why",""), len(d.get("changes") or [])))'
        else call GET "$(B "$b")/canvas"; out "$RESP" 'print(json.dumps(d.get("definition"), indent=2)[:4000])'; fi ;;

    structs) need "${1:-}" "structs <bench> [--view ...]"; b=$1; shift; take_opts "$@"; q=''
        for k in view instance field bridge; do v=$(optval "$k"); [ -n "$v" ] && q="$q&$k=$(pol_api_enc "$v")"; done
        call GET "/api/cmod/bench-structs/$(pol_api_enc "$b")${q:+?${q#&}}"
        out "$RESP" '
print("  view %s  count %s" % (d.get("view"), d.get("count")))
for r in d.get("rows", []): print("  " + json.dumps(r)[:160])' ;;

    step-rules) need "${1:-}" "step-rules <bench> [--variant V]..."; b=$1; shift; take_opts "$@"
        call POST "$(B "$b")/step-rules" "$(python3 -c 'import json,sys; print(json.dumps({"variants":[v for v in sys.argv[1].split("\n") if v]}))' "$(optvals variant)")"
        out "$RESP" '
for r in d.get("rows", []): print("  " + json.dumps(r)[:160])' ;;

    status) need "${1:-}" "status <bench>"; b=$1
        # composite, read-only: legs + topology nodes + last run per node + untested. exit 1 = NOT GREEN.
        call GET "/api/board/bench-solutions/$(pol_api_enc "$b")"; SOL=$RESP
        call GET "$(B "$b")"; TOP=$RESP
        call GET "$(B "$b")/coverage/untested"; UNT=$RESP
        RUNS='{}'; for n in $(printf '%s' "$TOP" | python3 -c 'import json,sys; [print(x["name"]) for x in json.load(sys.stdin).get("nodes",[])]'); do
            s=$(slug "$b" "$n"); rc=0; r=$(pol_api GET "$(B "$b")/nodes/$(pol_api_enc "$s")/runs" 2>/dev/null) || rc=$?; [ $rc -eq 0 ] || r='{"rows":[]}'
            RUNS=$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a[sys.argv[2]]=json.loads(sys.argv[3]).get("rows",[]); print(json.dumps(a))' <(printf '%s' "$RUNS") "$n" "$r"); done
        python3 - "$JSON" "$SOL" "$TOP" "$UNT" "$RUNS" <<'PY'
import json, sys
js, sol, top, unt, runs = sys.argv[1] == "1", *[json.loads(a) for a in sys.argv[2:6]]
nodes = []
for n in top.get("nodes", []):
    rs = runs.get(n["name"]) or []
    last = max(rs, key=lambda r: r.get("ran_at") or "") if rs else None
    nodes.append({"name": n["name"], "kind": n.get("kind"), "blocked": bool(n.get("blocked")), "paths": len(n.get("paths") or []),
                  "last_run": {k: last.get(k) for k in ("name", "outcome", "ran_at", "hex_sha256")} if last else None})
legs = sol.get("legs") or {}
red = [l for l, r in legs.items() if not r.get("ok")] + [n["name"] for n in nodes if n["blocked"] or (n["last_run"] and n["last_run"]["outcome"] != "reached")]
untested = unt.get("rows") or []
green = not red and not untested
out = {"ok": True, "bench_solution": sol.get("name"), "whole": sol.get("whole"), "green": green, "legs": legs, "nodes": nodes,
       "untested": untested, "red": red}
if js:
    print(json.dumps(out, indent=2))
else:
    print("  %s  whole=%s  %s" % (sol.get("name"), sol.get("whole"), "GREEN" if green else "NOT GREEN"))
    for l, r in sorted(legs.items()): print("  leg %-9s %-4s %-22s %s" % (l, "ok" if r.get("ok") else "NOT", r.get("ref", "-"), (r.get("why") or "")[:80]))
    for n in nodes:
        lr = n["last_run"]
        print("  node %-40s %-7s %s" % (n["name"], n["kind"] or "", ("BLOCKED" if n["blocked"] else (("last %s %s" % (lr["outcome"], lr["ran_at"])) if lr else "never run"))))
    print("  untested: %d" % len(untested))
    for u in untested[:12]: print("    " + (u.get("words") if isinstance(u, dict) else str(u)))
    if len(untested) > 12: print("    … %d more" % (len(untested) - 12))
sys.exit(0 if green else 1)
PY
        ;;

    *) log_error "unknown verb: pol bench $cmd"; usage; exit 2 ;;
esac
