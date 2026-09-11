"""
prodguide.facts — everything the guide learns from the machine comes from the
bash side, as JSON (`pol prod facts`), so both front ends see the same facts.
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
from typing import Dict, List, Optional


def pol() -> List[str]:
    """How to call `pol prod …` from here: the installed pol, else the checkout's index.js."""
    exe = shutil.which("pol")
    if exe:
        return [exe]
    suite = os.environ.get("POL_SUITE_ROOT", "")
    idx = os.path.join(suite, "polari-cli", "index.js")
    if suite and os.path.isfile(idx):
        return ["node", idx]
    raise RuntimeError("pol is not installed and POL_SUITE_ROOT is not set")


async def run(args: List[str], timeout: float = 180) -> str:
    proc = await asyncio.create_subprocess_exec(*pol(), *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError(f"pol {' '.join(args)} timed out after {timeout:.0f}s")
    if proc.returncode != 0 and not out:
        raise RuntimeError((err or b"").decode(errors="replace").strip()[-800:] or f"pol {' '.join(args)} failed")
    return out.decode(errors="replace")


async def facts(domain: Optional[str] = None) -> Dict:
    args = ["prod", "facts"] + (["--domain", domain] if domain else [])
    text = await run(args)
    start = text.find("{")
    return json.loads(text[start:]) if start >= 0 else {}


async def check_image(repo: str, tag: str) -> bool:
    text = await run(["prod", "facts", "--check-image", repo, tag], timeout=60)
    start = text.find("{")
    try:
        return bool(json.loads(text[start:]).get("ok"))
    except Exception:
        return False


def answers_path(f: Dict) -> str:
    return f.get("answers_file") or os.path.join(os.environ.get("POL_SUITE_ROOT", "."), ".generated", "prod-answers.env")
