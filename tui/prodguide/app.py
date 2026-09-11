"""
prodguide.app — `pol prod guide` as a Textual application.

Left: the steps and where you are. Right: the current step's form, or the live
log while apply runs. Bottom: keys. Every fact comes from `pol prod facts`
(the bash side); every answer goes through the model's constraints before it
is written to the answers file; apply is `pol prod apply --yes` streamed here
and logged by the bash side to .generated/prod-log/.
"""
from __future__ import annotations

import asyncio
import os
from typing import Dict, List, Optional

from textual import on, work
from textual.app import App, ComposeResult
from textual.containers import Container, Horizontal, Vertical, VerticalScroll
from textual.widgets import (Button, Checkbox, ContentSwitcher, DataTable, Footer, Header, Input, Label, ListItem,
                             ListView, Markdown, RadioButton, RadioSet, RichLog, Static)

from . import facts as F
from .model import Answers

STEPS = [
    ("welcome", "Credentials & vault"),
    ("domain", "Domain & DNS host"),
    ("address", "Exposure address"),
    ("dns", "DNS check"),
    ("cert", "HTTPS certificate"),
    ("profile", "Logins & modules"),
    ("images", "Images"),
    ("extras", "Installers & notice"),
    ("review", "Review & apply"),
    ("apply", "Apply"),
]
GLYPH = {"pending": "○", "current": "●", "done": "✔", "failed": "✖"}


def radio(rs: RadioSet) -> str:
    """The pressed button's id suffix — read from the buttons themselves, so a value set in code counts too."""
    on = [b for b in rs.query(RadioButton) if b.value]
    if len(on) > 1:  # a value just set in code: the set has not un-toggled the old one yet — the new one is not pressed_button
        on = [b for b in on if b is not rs.pressed_button] or on
    b = on[0] if on else rs.pressed_button
    return (b.id or "").split("-", 1)[-1] if b is not None else ""


class ProdGuide(App):
    TITLE = "pol prod — production deployment guide"
    CSS_PATH = "app.tcss"
    BINDINGS = [("ctrl+n", "next", "Next"), ("ctrl+b", "back", "Back"), ("ctrl+r", "refresh", "Re-check"), ("ctrl+q", "quit", "Quit")]

    def __init__(self, facts: Optional[Dict] = None, auto_apply: bool = False) -> None:
        super().__init__()
        self.facts: Dict = facts or {}
        self.a: Answers = Answers.from_facts(self.facts) if facts else Answers()
        self.state: Dict[str, str] = {sid: "pending" for sid, _ in STEPS}
        self.current = "welcome"
        self.auto_apply = auto_apply
        self.apply_done = False
        self.confirmed_apply = False
        self.answers_file: str = (facts or {}).get("answers_file", "")

    # ---------------------------------------------------------------- layout
    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="body"):
            with Vertical(id="side"):
                yield Static("Steps", classes="side-title")
                yield ListView(*[ListItem(Label(f"{GLYPH['pending']} {t}", id=f"lbl-{sid}"), id=f"item-{sid}") for sid, t in STEPS], id="steps")
                yield Static("", id="side-facts")
            with VerticalScroll(id="main"):
                with ContentSwitcher(initial="step-welcome", id="panels"):
                    yield from self.panel_welcome()
                    yield from self.panel_domain()
                    yield from self.panel_address()
                    yield from self.panel_dns()
                    yield from self.panel_cert()
                    yield from self.panel_profile()
                    yield from self.panel_images()
                    yield from self.panel_extras()
                    yield from self.panel_review()
                    yield from self.panel_apply()
        with Horizontal(id="nav"):
            yield Static("", id="problems")
            yield Button("Back", id="back")
            yield Button("Next", id="next", variant="primary")
        yield Footer()

    def panel_welcome(self) -> ComposeResult:
        with Vertical(id="step-welcome"):
            yield Markdown(
                "## Credentials and the vault\n\n"
                "Everything this guide generates (Keycloak admin, database and file-store passwords on the full profile) "
                "is written **once** into an encrypted, root-only vault at `/etc/polari/vault`. Read it later with "
                "`sudo pol security vault show`.\n\n"
                "**Provider credentials** you give along the way (a DigitalOcean API token for the DNS challenge, a registry "
                "pull token) *can* be stashed in the same vault so the next run does not ask again. Advice: record them in your "
                "own password manager and remove them from the vault afterwards (`sudo pol security vault forget 'provider <name>'`).")
            yield Label("Stash provider credentials in the vault?", classes="q")
            with RadioSet(id="rs-stash"):
                yield RadioButton("Stash every provider credential I enter (convenient; move them out later)", id="stash-all")
                yield RadioButton("Ask me for each one", id="stash-some", value=True)
                yield RadioButton("Never — I keep them myself and re-enter when asked", id="stash-none")
            yield Static("", id="vault-line", classes="note")

    def panel_domain(self) -> ComposeResult:
        with Vertical(id="step-domain"):
            yield Markdown("## Domain\n\nThe public domain this server answers for. The site lives at the apex; `www.`, `prf.`, "
                           "`api.prf.` and `apt.` are made from it (the full profile adds `auth.`, `psc.`, `api.psc.`, `files.`, `s3.`, `odoo.`).")
            yield Label("Domain", classes="q")
            yield Input(placeholder="example.org", id="in-domain")
            yield Label("Where are the domain's DNS records managed?", classes="q")
            with RadioSet(id="rs-dnsp"):
                yield RadioButton("At the registrar where the domain was bought (most common)", id="dnsp-registrar", value=True)
                yield RadioButton("At DigitalOcean (delegated to its nameservers) — also enables the DNS challenge", id="dnsp-digitalocean")
                yield RadioButton("At Cloudflare", id="dnsp-cloudflare")
            yield Static("", id="dnsp-links", classes="note")

    def panel_address(self) -> ComposeResult:
        with Vertical(id="step-address"):
            yield Markdown("## Exposure address\n\nThe address the internet reaches this server at. Every DNS **A** record must carry it. "
                           "Detected below — keep it, or type the address you know is right (a reserved IP, the public side of a NAT, a proxy in front). "
                           "What you answer here is what the checks and the certificate use.")
            yield DataTable(id="tbl-addr")
            yield Label("Use", classes="q")
            with RadioSet(id="rs-addr"):
                yield RadioButton("the detected address", id="addr-detected", value=True)
                yield RadioButton("another address (type it below)", id="addr-other")
            yield Input(placeholder="203.0.113.10", id="in-addr")
            yield Static("", id="addr-note", classes="note")

    def panel_dns(self) -> ComposeResult:
        with Vertical(id="step-dns"):
            yield Markdown("## DNS check\n\nWhere each name resolves right now, against the exposure address. "
                           "A publicly trusted certificate needs every name pointing here first. Ctrl+R re-checks after you change records.")
            yield DataTable(id="tbl-dns")
            yield Static("", id="dns-links", classes="note")

    def panel_cert(self) -> ComposeResult:
        with Vertical(id="step-cert"):
            yield Markdown("## HTTPS certificate\n\nA **publicly trusted** certificate is signed by an authority every browser and phone already trusts, "
                           "so visitors see the padlock with no warning. Let's Encrypt issues them free and automatically.")
            with RadioSet(id="rs-cert"):
                yield RadioButton("Publicly trusted (Let's Encrypt): recognised instantly by anyone on the internet, renews itself — needs the DNS", id="cert-letsencrypt", value=True)
                yield RadioButton("Auto-generated by this suite's own CA: works now, browsers warn until the root is imported", id="cert-self-signed")
            yield Label("How should Let's Encrypt verify you own the names?", classes="q")
            with RadioSet(id="rs-chal"):
                yield RadioButton("HTTP challenge through this server's port 80 — any registrar, nothing to configure", id="chal-http", value=True)
                yield RadioButton("DNS challenge through the DigitalOcean API — needs DO_API_TOKEN; works before port 80 is open", id="chal-dns")
            yield Label("Contact e-mail (expiry warnings; never published)", classes="q")
            yield Input(placeholder="you@example.org", id="in-email")
            yield Static("", id="cert-links", classes="note")

    def panel_profile(self) -> ComposeResult:
        with Vertical(id="step-profile"):
            yield Markdown("## Logins and modules\n\nA distribution server needs no accounts. Keycloak adds about 1 GB and brings the scorecard and the file store; "
                           "its credentials are generated at apply and recorded in the vault.")
            with RadioSet(id="rs-auth"):
                yield RadioButton("No logins — the lean profile (docker-compose.lean.yml → stack polari-lean, 5 names)", id="auth-off", value=True)
                yield RadioButton("Keycloak logins — the full profile (docker-compose.prod.yml → stack polari-prod, 11 names)", id="auth-keycloak")
            yield Checkbox("Also deploy the Odoo ERP pair (full profile only)", id="cb-odoo")
            yield Label("Modules the server boots (comma-separated; the floor set is required)", classes="q")
            yield Input(placeholder="polariapps,appstore,islemesh,terms", id="in-modules")

    def panel_images(self) -> ComposeResult:
        with Vertical(id="step-images"):
            yield Markdown("## Images\n\nBackend and frontend images for this deployment. Registry and tag are **one** decision — they are set together and verified.")
            with RadioSet(id="rs-imgsrc"):
                yield RadioButton("Build the images on this machine from this checkout → tag prod (needs ~3 GB RAM, 5–15 min)", id="imgsrc-build", value=True)
                yield RadioButton("Use the staging images already present on this machine", id="imgsrc-staging")
                yield RadioButton("Pull from a registry: one of our official sources, or one I type — then a tag", id="imgsrc-pull")
            yield Label("Source", classes="q")
            with RadioSet(id="rs-imgreg"):
                yield RadioButton("official: ghcr.io/dausume/ — GitHub Container Registry, the Polari images", id="imgreg-official")
                yield RadioButton("manual entry", id="imgreg-manual")
            yield Input(placeholder="registry prefix, ending in a slash — example: registry.example.org/polari/", id="in-imgrepo")
            yield Label("Tag — example: polari-v2026.09.11 (a release) or staging (the moving tier tag)", classes="q")
            yield Input(placeholder="polari-v2026.09.11", id="in-imgtag")
            yield Button("Verify the registry has this image", id="verify-image")
            yield Static("", id="img-note", classes="note")

    def panel_extras(self) -> ComposeResult:
        with Vertical(id="step-extras"):
            yield Markdown("## Installers and the demonstration notice")
            yield Label("Installers to hand out on the Download page", classes="q")
            with RadioSet(id="rs-debs"):
                yield RadioButton("Skip for now (the page lists nothing)", id="debs-skip", value=True)
                yield RadioButton("Build the platform debs here (needs the Isle-Mesh and app-shell pieces; minutes)", id="debs-build")
                yield RadioButton("Copy them from a release pool directory (type it below)", id="debs-copy")
            yield Input(placeholder="/path/to/release/debs", id="in-debs")
            yield Checkbox("Show the 'demonstration instance — no personal information' notice and terms gate on the apps", id="cb-demo", value=True)

    def panel_review(self) -> ComposeResult:
        with Vertical(id="step-review"):
            yield Markdown("## Review\n\nEverything below is derived from your answers; the pairs that must match are shown together. Next applies.")
            yield DataTable(id="tbl-plan")
            yield Static("", id="review-warn", classes="note")

    def panel_apply(self) -> ComposeResult:
        with Vertical(id="step-apply"):
            yield Static("Applying — every line below is also in .generated/prod-log/ (pol prod log).", classes="note")
            yield RichLog(id="log", highlight=False, markup=False, wrap=True)
            with Horizontal(id="after"):
                yield Button("Show status", id="btn-status")
                yield Button("Show the vault (sudo)", id="btn-vault")
                yield Button("Quit", id="btn-quit")

    # ---------------------------------------------------------------- lifecycle
    async def on_mount(self) -> None:
        for t in ("tbl-addr", "tbl-dns", "tbl-plan"):
            self.query_one(f"#{t}", DataTable).cursor_type = "row"
        self.query_one("#tbl-addr", DataTable).add_columns("role", "address", "note")
        self.query_one("#tbl-dns", DataTable).add_columns("name", "resolves to", "verdict")
        self.query_one("#tbl-plan", DataTable).add_columns("item", "value")
        self.query_one("#after").display = False
        if not self.facts:
            await self.load_facts()
        else:
            self.fill_from_answers()
        self.goto("welcome")
        self.refresh_side()

    async def load_facts(self, domain: Optional[str] = None) -> None:
        try:
            self.facts = await F.facts(domain)
        except Exception as e:  # noqa: BLE001
            self.notify(f"could not read the machine's facts: {e}", severity="error", timeout=10)
            self.facts = self.facts or {}
        if self.answers_file:
            self.facts["answers_file"] = self.answers_file   # the path is decided once (tests point it elsewhere)
        else:
            self.answers_file = self.facts.get("answers_file", "")
        keep = self.a
        self.a = Answers.from_facts(self.facts)
        if domain:  # keep what the user already typed this session
            for k in ("DOMAIN", "EXPOSURE_IP", "DNS_PROVIDER", "STASH", "CERT_MODE", "LE_CHALLENGE", "LE_EMAIL", "AUTH", "MODULES", "DEBS", "DEMO", "IMAGE_TAG", "IMAGE_REPO", "ODOO"):
                setattr(self.a, k, getattr(keep, k))
            self.a.registry_verified = keep.registry_verified
        self.fill_from_answers()
        self.refresh_side()

    def fill_from_answers(self) -> None:
        a = self.a
        self.set_radio("rs-stash", "stash-" + a.STASH)
        self.query_one("#in-domain", Input).value = a.DOMAIN
        self.set_radio("rs-dnsp", "dnsp-" + a.DNS_PROVIDER)
        self.set_radio("rs-addr", "addr-other" if a.EXPOSURE_IP else "addr-detected")
        self.query_one("#in-addr", Input).value = a.EXPOSURE_IP
        self.set_radio("rs-cert", "cert-" + a.CERT_MODE)
        self.set_radio("rs-chal", "chal-" + a.LE_CHALLENGE)
        self.query_one("#in-email", Input).value = a.LE_EMAIL
        self.set_radio("rs-auth", "auth-" + a.AUTH)
        self.query_one("#cb-odoo", Checkbox).value = a.ODOO == "on"
        self.query_one("#in-modules", Input).value = a.MODULES
        if a.IMAGE_REPO:
            self.set_radio("rs-imgsrc", "imgsrc-pull")
            official = [s["prefix"] for s in self.facts.get("sources", [])]
            self.set_radio("rs-imgreg", "imgreg-official" if a.IMAGE_REPO in official else "imgreg-manual")
        else:
            self.set_radio("rs-imgsrc", "imgsrc-staging" if a.IMAGE_TAG == "staging" else "imgsrc-build")
        self.query_one("#in-imgrepo", Input).value = a.IMAGE_REPO
        self.query_one("#in-imgtag", Input).value = a.IMAGE_TAG if a.IMAGE_REPO else ""
        self.set_radio("rs-debs", "debs-copy" if a.DEBS.startswith("copy") else "debs-" + a.DEBS)
        self.query_one("#in-debs", Input).value = a.DEBS[5:] if a.DEBS.startswith("copy:") else ""
        self.query_one("#cb-demo", Checkbox).value = a.DEMO == "on"
        # facts → tables and notes
        t = self.query_one("#tbl-addr", DataTable); t.clear()
        for row in self.facts.get("addresses", []):
            t.add_row(row["role"], row["address"], row["note"])
        self.query_one("#addr-note", Static).update(f"detected exposure address: {a.detected_ip or 'none'}")
        self.query_one("#vault-line", Static).update(self.facts.get("vault", ""))
        self.query_one("#imgsrc-staging", RadioButton).disabled = self.facts.get("staging_images") != "1"
        self.fill_dns()
        self.fill_links()
        self.fill_plan()

    def fill_dns(self) -> None:
        t = self.query_one("#tbl-dns", DataTable); t.clear()
        dns = self.facts.get("dns", {}) or {}
        ours = {r["address"] for r in self.facts.get("addresses", []) if r["role"] in ("reserved", "public4")} | {self.a.exposure_ip}
        for n in self.a.names():
            r = dns.get(n, "")
            t.add_row(n, r or "unresolved", "✔ this server" if r and r in ours else "✖ not here")

    def fill_links(self) -> None:
        links = self.facts.get("links", {}) or {}
        def fmt(prov: str, n: int = 3) -> str:
            return "\n".join(f"  {l['label']}\n    {l['url']}" for l in links.get(prov, [])[:n])
        self.query_one("#dnsp-links", Static).update("Set the records at:\n" + fmt(self.a.DNS_PROVIDER))
        self.query_one("#dns-links", Static).update("Set the A records at:\n" + fmt(self.a.DNS_PROVIDER))
        self.query_one("#cert-links", Static).update("Let's Encrypt:\n" + fmt("letsencrypt", 4) + ("\nDigitalOcean API token:\n" + fmt("digitalocean", 7).split("API tokens")[-1] if self.a.LE_CHALLENGE == "dns" else ""))

    def fill_plan(self) -> None:
        t = self.query_one("#tbl-plan", DataTable); t.clear()
        for k, v in self.a.plan_rows():
            t.add_row(k, v)
        w = self.a.warnings(self.facts)
        self.query_one("#review-warn", Static).update(("Notes:\n  " + "\n  ".join(w)) if w else "No warnings.")

    def refresh_side(self) -> None:
        for sid, title in STEPS:
            st = "current" if sid == self.current else self.state[sid]
            self.query_one(f"#lbl-{sid}", Label).update(f"{GLYPH[st]} {title}")
        f = self.facts
        self.query_one("#side-facts", Static).update(
            f"host {f.get('host', '?')}\n{'droplet' if f.get('on_droplet') == '1' else 'machine'} · swarm {f.get('swarm', '?')}\n"
            f"ports 80 {f.get('port.80', '?')} · 443 {f.get('port.443', '?')}\nmemory {f.get('mem_total_mb', '?')} MB\ncode {f.get('git', '?')}")

    def set_radio(self, rs_id: str, btn_id: str) -> None:
        try:
            self.query_one(f"#{btn_id}", RadioButton).value = True
        except Exception:  # noqa: BLE001
            pass

    # ---------------------------------------------------------------- collecting answers from the widgets
    def collect(self) -> None:
        a = self.a
        a.STASH = radio(self.query_one("#rs-stash", RadioSet)) or a.STASH
        a.DOMAIN = self.query_one("#in-domain", Input).value.strip().lower()
        a.DNS_PROVIDER = radio(self.query_one("#rs-dnsp", RadioSet)) or a.DNS_PROVIDER
        a.EXPOSURE_IP = self.query_one("#in-addr", Input).value.strip() if radio(self.query_one("#rs-addr", RadioSet)) == "other" else ""
        a.CERT_MODE = radio(self.query_one("#rs-cert", RadioSet)) or a.CERT_MODE
        a.LE_CHALLENGE = radio(self.query_one("#rs-chal", RadioSet)) or a.LE_CHALLENGE
        a.LE_EMAIL = self.query_one("#in-email", Input).value.strip()
        a.AUTH = radio(self.query_one("#rs-auth", RadioSet)) or a.AUTH
        a.ODOO = "on" if self.query_one("#cb-odoo", Checkbox).value else "off"
        a.MODULES = ",".join(m.strip() for m in self.query_one("#in-modules", Input).value.split(",") if m.strip())
        src = radio(self.query_one("#rs-imgsrc", RadioSet))
        if src == "build":
            a.IMAGE_REPO, a.IMAGE_TAG = "", "prod"
        elif src == "staging":
            a.IMAGE_REPO, a.IMAGE_TAG = "", "staging"
        else:
            reg = radio(self.query_one("#rs-imgreg", RadioSet))
            official = [s["prefix"] for s in self.facts.get("sources", [])] or ["ghcr.io/dausume/"]
            repo = official[0] if reg == "official" else self.query_one("#in-imgrepo", Input).value.strip()
            if repo and not repo.endswith("/"):
                repo += "/"
            tag = self.query_one("#in-imgtag", Input).value.strip()
            if (repo, tag) != (a.IMAGE_REPO, a.IMAGE_TAG):
                a.registry_verified = False
            a.IMAGE_REPO, a.IMAGE_TAG = repo, tag
        debs = radio(self.query_one("#rs-debs", RadioSet))
        a.DEBS = ("copy:" + self.query_one("#in-debs", Input).value.strip()) if debs == "copy" else (debs or a.DEBS)
        a.DEMO = "on" if self.query_one("#cb-demo", Checkbox).value else "off"

    # ---------------------------------------------------------------- navigation
    def goto(self, sid: str) -> None:
        if sid != "review":
            self.confirmed_apply = False
        self.current = sid
        self.query_one("#panels", ContentSwitcher).current = f"step-{sid}"
        self.query_one("#steps", ListView).index = [s for s, _ in STEPS].index(sid)
        self.query_one("#next", Button).label = "Apply" if sid == "review" else ("Close" if sid == "apply" else "Next")
        self.query_one("#back", Button).disabled = sid in ("welcome", "apply")
        self.query_one("#problems", Static).update("")
        self.refresh_side()

    def step_problems(self, sid: str) -> List[str]:
        fields = {
            "welcome": {"STASH"}, "domain": {"DOMAIN", "ROUTE"}, "address": {"EXPOSURE_IP"}, "dns": set(),
            "cert": {"CERT_MODE", "LE_EMAIL", "LE_CHALLENGE"}, "profile": {"AUTH", "ODOO", "MODULES"},
            "images": {"IMAGE_TAG", "IMAGE_REPO"}, "extras": {"DEBS"}, "review": set(KEYS_ALL),
        }.get(sid, set())
        return [m for f, m in self.a.problems() if f in fields]

    async def action_next(self) -> None:
        if self.current == "apply":
            self.exit(0 if self.apply_done else 1)
            return
        self.collect()
        probs = self.step_problems(self.current)
        if probs:
            self.query_one("#problems", Static).update("✖ " + "\n✖ ".join(probs))
            self.state[self.current] = "failed"
            self.refresh_side()
            return
        self.state[self.current] = "done"
        order = [s for s, _ in STEPS]
        nxt = order[order.index(self.current) + 1]
        if self.current == "domain":
            await self.load_facts(self.a.DOMAIN)
        if nxt in ("dns", "address"):
            self.fill_dns(); self.fill_links()
        if nxt == "review":
            self.fill_plan()
        if nxt == "apply":
            if not self.confirmed_apply:
                self.confirmed_apply = True
                self.query_one("#problems", Static).update("Press Apply once more to deploy (answers are written first).")
                self.query_one("#next", Button).label = "Apply — confirm"
                return
            self.write_answers()
            self.goto("apply")
            if os.environ.get("PRODGUIDE_DRY"):
                self.query_one("#log", RichLog).write("dry run: pol prod apply --yes NOT started (PRODGUIDE_DRY)")
                return
            self.run_apply()
            return
        self.goto(nxt)

    async def action_back(self) -> None:
        order = [s for s, _ in STEPS]
        i = order.index(self.current)
        if i > 0 and self.current != "apply":
            self.collect()
            self.goto(order[i - 1])

    async def action_refresh(self) -> None:
        self.collect()
        await self.load_facts(self.a.DOMAIN or None)
        self.fill_dns()
        self.notify("re-checked")

    @on(Button.Pressed, "#next")
    async def _next(self) -> None:
        await self.action_next()

    @on(Button.Pressed, "#back")
    async def _back(self) -> None:
        await self.action_back()

    @on(ListView.Selected, "#steps")
    def _jump(self, ev: ListView.Selected) -> None:
        sid = (ev.item.id or "").replace("item-", "")
        if sid in self.state and self.current != "apply" and (self.state[sid] != "pending" or sid == self.current):
            self.collect()
            self.goto(sid)

    @on(RadioSet.Changed)
    def _radio_changed(self, ev: RadioSet.Changed) -> None:
        rs = ev.radio_set.id or ""
        if rs in ("rs-dnsp", "rs-chal", "rs-cert"):
            self.collect(); self.fill_links()
        if rs == "rs-imgsrc":
            pull = radio(ev.radio_set) == "pull"
            for wid in ("#rs-imgreg", "#in-imgrepo", "#in-imgtag", "#verify-image"):
                self.query_one(wid).display = pull
        if rs == "rs-imgreg":
            self.query_one("#in-imgrepo").display = radio(ev.radio_set) == "manual"
        if rs == "rs-addr":
            self.query_one("#in-addr").display = radio(ev.radio_set) == "other"
        if rs == "rs-debs":
            self.query_one("#in-debs").display = radio(ev.radio_set) == "copy"

    @on(Button.Pressed, "#verify-image")
    async def _verify(self) -> None:
        self.collect()
        note = self.query_one("#img-note", Static)
        if not self.a.IMAGE_REPO or not self.a.IMAGE_TAG:
            note.update("a registry prefix and a tag are needed first"); return
        note.update(f"checking {self.a.IMAGE_REPO}prf-backend:{self.a.IMAGE_TAG} …")
        ok = await F.check_image(self.a.IMAGE_REPO, self.a.IMAGE_TAG)
        self.a.registry_verified = ok
        note.update(("✔ reachable: " if ok else "✖ not reachable (not published, private, or a typo): ") + f"{self.a.IMAGE_REPO}prf-backend:{self.a.IMAGE_TAG}")

    # ---------------------------------------------------------------- apply
    def write_answers(self) -> None:
        path = F.answers_path(self.facts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(self.a.to_env())
        self.query_one("#log", RichLog).write(f"answers written: {path}")

    @work(exclusive=True)
    async def run_apply(self) -> None:
        log = self.query_one("#log", RichLog)
        self.query_one("#next", Button).disabled = True
        env = dict(os.environ, POL_PROD_TUI="textual")
        try:
            proc = await asyncio.create_subprocess_exec(*F.pol(), "prod", "apply", "--yes", stdout=asyncio.subprocess.PIPE,
                                                        stderr=asyncio.subprocess.STDOUT, env=env)
        except Exception as e:  # noqa: BLE001
            log.write(f"could not start pol prod apply: {e}")
            self.state["apply"] = "failed"; self.refresh_side(); self.query_one("#next", Button).disabled = False
            return
        assert proc.stdout is not None
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            log.write(line.decode(errors="replace").rstrip("\n"))
        rc = await proc.wait()
        self.apply_done = rc == 0
        self.state["apply"] = "done" if rc == 0 else "failed"
        log.write(f"— pol prod apply finished with exit code {rc} —")
        self.query_one("#after").display = True
        self.query_one("#next", Button).disabled = False
        self.refresh_side()
        if rc == 0:
            self.notify("applied — pol prod status shows the board", timeout=8)
        else:
            self.notify("apply reported a failure — the log above and pol prod log have the details", severity="error", timeout=12)

    @on(Button.Pressed, "#btn-status")
    async def _status(self) -> None:
        log = self.query_one("#log", RichLog)
        try:
            log.write(await F.run(["prod", "status"], timeout=120))
        except Exception as e:  # noqa: BLE001
            log.write(str(e))

    @on(Button.Pressed, "#btn-vault")
    async def _vault(self) -> None:
        log = self.query_one("#log", RichLog)
        log.write("run on the terminal after closing: sudo pol security vault show   (it prints to the terminal only)")

    @on(Button.Pressed, "#btn-quit")
    def _quit(self) -> None:
        self.exit(0 if self.apply_done else 1)


KEYS_ALL = ["ROUTE", "DOMAIN", "EXPOSURE_IP", "DNS_PROVIDER", "STASH", "CERT_MODE", "LE_CHALLENGE", "LE_EMAIL", "AUTH",
            "MODULES", "DEBS", "DEMO", "IMAGE_TAG", "IMAGE_REPO", "ODOO"]
