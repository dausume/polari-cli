#!/bin/bash
# reticulum-status.sh — what this isle's sidecar sees: interfaces, peers
# heard (announces), LXMF facts + stored messages; and the backend's view.
set -u
curl -sf --max-time 3 http://127.0.0.1:4285/status | python3 -c "
import json,sys,time; s=json.load(sys.stdin)
print('sidecar', s['identityHash'][:16], 'up %ss' % s['uptimeSeconds'])
for i in s['interfaces']: print('  iface %-28s %s' % (i['name'], 'ONLINE' if i['online'] else 'offline'))
print('  lxmf facts:', json.dumps(s.get('lxmf', {}))[:300])
now=time.time()*1000
for p in s['peersHeard']: print('  heard dest %s ident %s x%d last %.0fs ago' % (p['destHash'][:16], (p.get('identityHash') or '')[:16], p['count'], (now-p['lastHeardMs'])/1000))
if not s['peersHeard']: print('  peers heard: none yet (the other isle must announce AFTER the link is up — restart its sidecar)')" || echo "sidecar not answering on :4285"
echo "-- messages (backend seam, ret-7):"
curl -sk --max-time 5 --resolve api.polari.isle:443:127.0.0.1 https://api.polari.isle/api/reticulum/messages | python3 -c "
import json,sys; d=json.load(sys.stdin)
if not d.get('ok'): print('  ', d.get('error') or d); sys.exit()
print('  facts:', json.dumps(d.get('facts', {}))[:300])
for m in d.get('messages', [])[-5:]: print('  msg from %s at %s: %s' % (str(m.get('source',''))[:16], m.get('receivedAt') or m.get('timestamp'), str(m.get('content'))[:80]))
print('  send:', d.get('sendHow'))" 2>/dev/null || echo "   backend /api/reticulum/messages not answering (module admitted? RETICULUM_URL set? see reticulum-enable.sh)"
