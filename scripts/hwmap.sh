#!/bin/bash
# hwmap.sh — `pol hwmap`: the hardware map (hwm-1). scan runs ON THIS DEVICE
# (host python, stdlib only — usb/pci/iommu/serial/nics/kvm facts), push
# sends the snapshot to a Polari API, the rest queries it.
#   pol hwmap scan                       JSON to stdout
#   pol hwmap push [--api URL]           scan + POST /api/hwmap/ingest (default: the local isle api)
#   pol hwmap devices|ports|candidates [--device D] [--app A] [--api URL]
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
FW="$(cd "$SCRIPT_DIR/../.." && pwd)/polari-rf-node/polari-framework"
API="${POLARI_API:-https://api.polari.isle}"; DEV=""; APP=""
VERB="${1:-help}"; shift || true
while [ $# -gt 0 ]; do case "$1" in --api) API="$2"; shift 2 ;; --device) DEV="$2"; shift 2 ;; --app) APP="$2"; shift 2 ;; *) shift ;; esac; done
CURL="curl -sk --max-time 30 --resolve api.polari.isle:443:127.0.0.1"
scan(){ (cd "$FW" && PYTHONPATH=.:modules python3 -m hwmap.custom.scanner); }
case "$VERB" in
    scan) scan ;;
    push) scan | $CURL -X POST -H 'Content-Type: application/json' --data-binary @- "$API/api/hwmap/ingest" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(("[ OK ] " if d.get("ok") else "[FAIL] ") + json.dumps(d))' ;;
    devices) $CURL "$API/api/hwmap" | python3 -c 'import json,sys; [print("%-28s tier-ready=%s cpu-virt=%s kvm=%s libvirt=%s iommu=%s usb=%s pci=%s nics=%s serial=%s at %s" % (d["device"], d["hardwareTierReady"], d["cpuVirt"], d["kvm"], d["libvirt"], d["iommuGroups"], d["usb"], d["pci"], d["nics"], d["serial"], d["observedAt"])) for d in json.load(sys.stdin)["devices"]]' ;;
    ports) $CURL "$API/api/hwmap/ports?device=$DEV" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("%-8s %-8s %-40s %-32s owner=%s" % (p["kind"], p["role"], p["id"], p["description"][:32], p["owner"])) for p in d["ports"]]; print(len(d["slots"]), "slots")' ;;
    candidates) $CURL "$API/api/hwmap/candidates?device=$DEV&app=$APP" | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("%s %-20s %-45s %s  %s" % ("OK " if c["mappable"] else "NO ", c["mapping"], c["port"][-45:], c["reasons"][0][:60], c["satisfies"])) for c in d["candidates"]]; print("mappable:", d["mappable"]); [print("MISSING:", m) for m in d["missing"]]' ;;
    *) sed -n 2,8p "$0" ;;
esac
