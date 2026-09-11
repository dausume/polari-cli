"""
prodguide.model — the answers of `pol prod`, as ONE model with the constraints
that must hold together.

The bash side (polari-cli/scripts/prod.sh) does the work and reads the answers
from `.generated/prod-answers.env` (POL_PROD_<KEY>=value lines). This model is
the only writer of that file from the Textual guide, and `problems()` is the
gate: nothing is written while a constraint fails, so the pairs that must map
together (registry ↔ tag, profile ↔ stack ↔ certificate names, DNS provider ↔
challenge, exposure address ↔ DNS check) can never be submitted mismatched.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field, fields
from typing import Dict, List, Tuple

KEYS = ["ROUTE", "DOMAIN", "EXPOSURE_IP", "DNS_PROVIDER", "STASH", "CERT_MODE", "LE_CHALLENGE",
        "LE_EMAIL", "AUTH", "MODULES", "DEBS", "DEMO", "IMAGE_TAG", "IMAGE_REPO", "ODOO"]
FLOOR_MODULES = ["polariapps", "appstore", "islemesh", "terms"]
HOST_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$")
IPV4_RE = re.compile(r"^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")


@dataclass
class Answers:
    ROUTE: str = "swarm"
    DOMAIN: str = ""
    EXPOSURE_IP: str = ""          # empty = use the detected address
    DNS_PROVIDER: str = "registrar"  # registrar | digitalocean | cloudflare
    STASH: str = "some"            # all | some | none
    CERT_MODE: str = "letsencrypt"  # letsencrypt | self-signed
    LE_CHALLENGE: str = "http"     # http | dns
    LE_EMAIL: str = ""
    AUTH: str = "off"              # off | keycloak
    MODULES: str = ",".join(FLOOR_MODULES)
    DEBS: str = "skip"             # build | skip | copy:<dir>
    DEMO: str = "on"               # on | off
    IMAGE_TAG: str = "prod"
    IMAGE_REPO: str = ""           # empty = build here; else a registry prefix ending in /
    ODOO: str = "off"
    # not answers — facts the guide learned, kept so the constraints can see them
    detected_ip: str = field(default="", compare=False)
    registry_verified: bool = field(default=False, compare=False)

    # ---- derived: the things that MUST map together, computed from one source
    @property
    def profile(self) -> str:
        return "full" if self.AUTH == "keycloak" else "lean"

    @property
    def compose_file(self) -> str:
        return "docker-compose.prod.yml" if self.profile == "full" else "docker-compose.lean.yml"

    @property
    def stack_name(self) -> str:
        return "polari-prod" if self.profile == "full" else "polari-lean"

    @property
    def cert_row(self) -> str:
        return "pol-proxy-public" if self.profile == "full" else "pol-proxy-lean"

    def names(self) -> List[str]:
        d = self.DOMAIN or "example.org"
        if self.profile == "full":
            subs = ["", "www.", "auth.", "psc.", "api.psc.", "prf.", "api.prf.", "files.", "s3.", "odoo.", "apt."]
        else:
            subs = ["", "www.", "prf.", "api.prf.", "apt."]
        return [s + d for s in subs]

    @property
    def exposure_ip(self) -> str:
        return self.EXPOSURE_IP or self.detected_ip

    @property
    def images_from(self) -> str:
        if self.IMAGE_REPO:
            return f"pull from {self.IMAGE_REPO} at tag {self.IMAGE_TAG}"
        return f"build on this machine, tagged {self.IMAGE_TAG}"

    def modules(self) -> List[str]:
        return [m.strip() for m in self.MODULES.split(",") if m.strip()]

    # ---- the constraints
    def problems(self) -> List[Tuple[str, str]]:
        """(field, message) for everything that stops an apply. Empty = consistent."""
        p: List[Tuple[str, str]] = []
        if self.ROUTE != "swarm":
            p.append(("ROUTE", "this guide applies the swarm (server) route; a home computer uses pol dev / the store"))
        if not HOST_RE.match(self.DOMAIN.lower()):
            p.append(("DOMAIN", "a public domain is required, like example.org (the five or eleven names are made from it)"))
        if self.EXPOSURE_IP and not IPV4_RE.match(self.EXPOSURE_IP):
            p.append(("EXPOSURE_IP", "the exposure address must be an IPv4 address like 203.0.113.10"))
        if not self.exposure_ip:
            p.append(("EXPOSURE_IP", "no exposure address: none detected, none answered"))
        if self.CERT_MODE not in ("letsencrypt", "self-signed"):
            p.append(("CERT_MODE", "certificate must be letsencrypt or self-signed"))
        if self.CERT_MODE == "letsencrypt":
            if not EMAIL_RE.match(self.LE_EMAIL):
                p.append(("LE_EMAIL", "Let's Encrypt needs a contact e-mail (expiry warnings go there)"))
            if self.LE_CHALLENGE == "dns" and self.DNS_PROVIDER != "digitalocean":
                p.append(("LE_CHALLENGE", "the DNS challenge is only implemented for DigitalOcean DNS — choose the HTTP challenge, or set DNS provider to DigitalOcean"))
        if self.ODOO == "on" and self.profile != "full":
            p.append(("ODOO", "Odoo needs the full profile (logins = Keycloak)"))
        missing = [m for m in FLOOR_MODULES if m not in self.modules()]
        if missing:
            p.append(("MODULES", "the floor modules are required: " + ", ".join(missing)))
        if self.DEBS.startswith("copy:") and len(self.DEBS) <= 5:
            p.append(("DEBS", "the pool needs a directory, a release page URL, or github:<owner/repo>@<tag>"))
        if self.DEBS.startswith("copy:") and self.DEBS[5:].startswith("github:") and "@" not in self.DEBS:
            p.append(("DEBS", "a GitHub pool needs a tag: github:<owner/repo>@<tag>"))
        if self.DEBS == "release:":
            p.append(("DEBS", "no official release with installers is published yet — choose skip, build, or another pool"))
        # images: registry and tag are ONE decision
        if not TAG_RE.match(self.IMAGE_TAG or ""):
            p.append(("IMAGE_TAG", "an image tag is required"))
        if self.IMAGE_REPO:
            if not self.IMAGE_REPO.endswith("/"):
                p.append(("IMAGE_REPO", "a registry prefix ends with a slash, like ghcr.io/dausume/"))
            if self.IMAGE_TAG == "prod":
                p.append(("IMAGE_TAG", "prod is the tag of images built here; a pull needs the registry's tag (a release like polari-v2026.09.11, or staging)"))
            if not self.registry_verified:
                p.append(("IMAGE_REPO", f"{self.IMAGE_REPO}prf-backend:{self.IMAGE_TAG} has not been verified reachable — use Verify"))
        else:
            if self.IMAGE_TAG not in ("prod", "staging"):
                p.append(("IMAGE_TAG", "images built here are tagged prod (or staging when those already exist on this machine)"))
        if self.STASH not in ("all", "some", "none"):
            p.append(("STASH", "stash policy must be all, some or none"))
        return p

    def warnings(self, facts: dict) -> List[str]:
        """Things worth saying that do not stop an apply."""
        w: List[str] = []
        dns = facts.get("dns", {}) or {}
        ours = {a["address"] for a in facts.get("addresses", []) if a["role"] in ("reserved", "public4")} | {self.exposure_ip}
        bad = [n for n in self.names() if dns.get(n, "") not in ours]
        if bad and self.CERT_MODE == "letsencrypt":
            w.append("a publicly trusted certificate needs every name pointing here first; not yet: " + ", ".join(bad))
        if facts.get("on_droplet") == "1" and not any(a["role"] == "reserved" for a in facts.get("addresses", [])):
            w.append("no reserved IP attached to this droplet — a rebuild changes its address (attach one in Networking → Reserved IPs)")
        if not self.IMAGE_REPO:
            try:
                mb = int(facts.get("mem_total_mb") or 0)
            except ValueError:
                mb = 0
            if mb and mb < 3500:
                w.append(f"this machine has {mb} MB of memory; building the frontend image here needs about 3 GB — pulling images is safer")
        if self.DEBS == "build" and (facts.get("piece.isle-mesh") != "1" or facts.get("piece.app-shell") != "1"):
            w.append("building the installers needs the Isle-Mesh and polari-app-shell pieces (get-polari.sh pulls them)")
        if self.profile == "full":
            w.append("full profile: Keycloak + MariaDB + MinIO + scorecard — about 1 GB more memory; credentials are generated at apply and recorded in the vault")
        return w

    # ---- the file the bash side reads
    def to_env(self) -> str:
        lines = ["# pol prod answers — written by the Textual guide. Edit and re-run: pol prod apply. Env vars POL_PROD_* override."]
        for k in KEYS:
            lines.append(f"POL_PROD_{k}={getattr(self, k)}")
        return "\n".join(lines) + "\n"

    @classmethod
    def from_facts(cls, facts: dict) -> "Answers":
        a = cls()
        for k, v in (facts.get("answers") or {}).items():
            if k in KEYS and v != "":
                setattr(a, k, v)
        a.detected_ip = facts.get("detected_ip", "") or ""
        if a.IMAGE_REPO:
            a.registry_verified = False
        return a

    def plan_rows(self) -> List[Tuple[str, str]]:
        """What the review screen shows — every derived pairing in one table."""
        return [
            ("route", "swarm (server)"),
            ("profile", f"{self.profile}  →  {self.compose_file}  →  stack {self.stack_name}  →  certificate row {self.cert_row}"),
            ("domain", self.DOMAIN),
            ("names", ", ".join(self.names())),
            ("exposure address", f"{self.exposure_ip} ({'answered' if self.EXPOSURE_IP else 'detected'})"),
            ("DNS records at", self.DNS_PROVIDER),
            ("certificate", ("publicly trusted (Let's Encrypt, %s challenge, %s)" % (self.LE_CHALLENGE, self.LE_EMAIL)) if self.CERT_MODE == "letsencrypt" else "self-signed by the suite CA (browsers warn)"),
            ("logins", "Keycloak" if self.AUTH == "keycloak" else "none"),
            ("odoo", self.ODOO),
            ("modules", self.MODULES),
            ("installers", {"skip": "none staged", "build": "built on this machine"}.get(self.DEBS, self.DEBS.replace("release:", "official release ").replace("copy:", "pool: "))),
            ("demo notice", self.DEMO),
            ("images", self.images_from),
            ("provider stash", self.STASH),
        ]


def all_keys() -> List[str]:
    return [f.name for f in fields(Answers) if f.name in KEYS]
