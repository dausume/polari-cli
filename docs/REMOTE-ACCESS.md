# Remote access for staging — host computer + phone

Test Polari **staging** from your phone over the internet, without putting your
home network at risk. This uses a single-peer **WireGuard** tunnel (open source),
driven by `pol remote`. Access is confined to the staging host only, runs at the
host level (so it survives `pol` rebuilds), and doesn't touch local development.

> Staging only. Don't expose prod or your whole LAN. Bring the tunnel up while
> testing and down when done.

## How it works (30 seconds)
Your home router does NAT, so the internet can't reach the staging host directly.
You forward **one silent UDP port** to it; your phone connects through that port
with a key only it holds. The tunnel **terminates on the staging host with
IP-forwarding off**, so the phone can reach *only* that host's staging ports —
nothing else on your network.

```
iPhone ──(WireGuard, UDP)──▶ home router :PORT ──▶ staging host (only staging reachable)
```

## On the Polari host computer

1. **Generate the configs** (writes only into a git-ignored `.remote-wg/`, no system changes):
   ```bash
   pol remote init --endpoint <your-no-ip-hostname>:51820
   ```
   `--endpoint` is the dynamic-DNS name that tracks your home IP — see
   "Register a home hostname (no-ip)" below. Optional: `--lan-ip <staging-LAN-IP>`
   (auto-detected), `--subnet 10.9.0.0/24`, `--port 51820`, `--out DIR`.

2. **Apply it on this host** (the one exposing step — asks to confirm, needs root and `wireguard-tools`):
   ```bash
   sudo pol remote apply
   ```

3. **Set the router forward** (the only manual step — it can't be automated):
   forward **UDP :51820 → this host's LAN IP**, UDP only. If your home IP is
   dynamic, set up dynamic DNS and use that name as the `--endpoint`.

4. **Toggle the tunnel** around a test session (ephemeral = safest):
   ```bash
   sudo pol remote up      # start before testing
   sudo pol remote down    # stop when done
   pol remote status       # check state
   ```

## On your phone

1. Install the official **WireGuard** app (App Store / Play Store).
2. Import the phone config: `pol remote qr` (scan the QR), or AirDrop / share
   `.remote-wg/phone.conf` and open it in the WireGuard app.
3. Toggle the tunnel on, then browse to your **normal staging URL** —
   e.g. `https://prf.<LAN-IP>.nip.io` — accept the self-signed cert once, and test.
   Toggle off when finished. (The default nip.io URLs work unchanged because the
   tunnel routes the LAN IP — see "Why nip.io needs the tunnel" below.)

## Verify the scope
```bash
bash .remote-wg/scope-check.sh
```
From the phone with the tunnel up: `https://<staging-hostname>:2096` works, and a
connection to any *other* LAN IP fails — that failure is the proof the tunnel is
confined to staging.

## Why nip.io needs the tunnel (and how this handles it)
Staging's default URLs are `https://prf.<LAN-IP>.nip.io` (plus `api.`, `auth.`, `psc.`
variants). nip.io is a public resolver that turns `prf.192.168.1.50.nip.io` into the
LAN IP `192.168.1.50` — which is **unreachable from outside your network**. So the
default URLs don't work remotely on their own.

`pol remote init` handles this by routing the staging host's **LAN IP** through the
tunnel (the phone's `AllowedIPs` includes it — auto-detected, or `--lan-ip`). With the
tunnel up, `prf.<LAN-IP>.nip.io` still resolves to the LAN IP and the tunnel makes that
IP reachable — so your **normal nip.io URLs work from the phone unchanged**, and
Keycloak / OIDC / token issuer / CORS all still match because the hostname never
changed. Forwarding stays off, so the host serves only its own LAN IP — still confined
to staging.

- **Bind address:** services must listen on `0.0.0.0` (Polari's published ports do).
- **DNS rebind protection:** a few phone DNS setups block public names that resolve to
  private IPs. If a nip.io URL won't resolve on the phone, set a `DNS` line in
  `phone.conf`, or use a hostname you control.

## Register a home hostname (no-ip) — for the tunnel endpoint
Your home's public IP is usually **dynamic**, so the phone needs a stable name to find
your network. A free dynamic-DNS hostname solves this. These steps use **no-ip.com**
(other options: DuckDNS, Dynu, Cloudflare, afraid.org — same idea):

1. Create a free account at **no-ip.com** and confirm your email.
2. Create a hostname, e.g. `mypolari.ddns.net` (any free domain they offer).
3. Keep it pointed at your current home IP automatically — either:
   - turn on **Dynamic DNS** in your router and enter the no-ip hostname + your no-ip
     username/password (most routers have a built-in No-IP option), **or**
   - install No-IP's **Dynamic Update Client (DUC)** on the staging host (they ship a
     Linux client) so it updates the record whenever your IP changes.
4. Use that hostname as the tunnel endpoint:
   ```bash
   pol remote init --endpoint mypolari.ddns.net:51820
   ```

This name is only the **entry point** to the tunnel (it just tracks your dynamic home
IP). Once you're inside the tunnel you still browse staging at its normal nip.io URL —
the tunnel makes it reachable, per the section above.

## Persistence & isolation
- **Survives rebuilds:** the tunnel is a host service (`wg-quick@wg0`) with
  host-stored keys, so `pol suite up/rebuild --env staging` re-publishes the same
  ports and the phone config keeps working — no re-keying.
- **Won't interfere with dev:** it's a separate overlay interface; local
  development never routes through it.

## Security notes
- Open source end to end (WireGuard); no proprietary control plane.
- One silent UDP port, one peer, key-only. Forwarding-off confines the blast
  radius to the single staging host.
- Private keys live in `.remote-wg/` (chmod 600, git-ignored). Never commit them.
- Keep the host patched; bring the tunnel down when not testing.
