#!/usr/bin/env python3
"""이 repo의 GitHub App installation_id를 출력한다.

.secrets/app.json (app_id) + .secrets/app.pem (private key)를 읽어 짧은
app JWT (RS256)를 발급하고, 그 앱의 installation 목록을 조회한다. repo에 앱을
설치한 뒤에(AFTER) 실행하라 (2-0-setup/2-github/create_github_app.py가 설치 링크를 출력한다).

    python3 2-0-setup/2-github/print_install_id.py

PyJWT가 필요하다 (`pip install pyjwt cryptography`) — Hermes 에이전트 venv에는
이미 들어 있다. 그 외 환경은 stdlib.
"""

from __future__ import annotations

import json
import ssl
import sys
import time
import urllib.request
from pathlib import Path


def main() -> int:
    sec = Path(".secrets")
    meta_path, pem_path = sec / "app.json", sec / "app.pem"
    if not meta_path.exists() or not pem_path.exists():
        print(
            "ERROR: .secrets/app.json or app.pem missing — run 2-0-setup/2-github/create_github_app.py first.",
            file=sys.stderr,
        )
        return 1
    meta = json.loads(meta_path.read_text())
    app_id = meta["app_id"]

    try:
        import jwt  # PyJWT
    except ImportError:
        print(
            "ERROR: PyJWT not installed. `pip install pyjwt cryptography` "
            "or run with the Hermes venv python.",
            file=sys.stderr,
        )
        return 1

    now = int(time.time())
    token = jwt.encode(
        {"iat": now - 60, "exp": now + 540, "iss": str(app_id)},
        pem_path.read_text(),
        algorithm="RS256",
    )

    req = urllib.request.Request(
        "https://api.github.com/app/installations",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "print-install-id",
        },
    )
    with urllib.request.urlopen(
        req, context=ssl.create_default_context(), timeout=30
    ) as r:
        installs = json.load(r)

    if not installs:
        print(f"App {meta['slug']} is not installed anywhere yet.")
        print(
            f"Install it: {meta['html_url']}/installations/new  (select {meta['repo']})"
        )
        return 2
    owner = meta.get("owner") or ""
    for ins in installs:
        acct = (ins.get("account") or {}).get("login")
        print(
            f"installation_id={ins['id']}  account={acct}  target={ins.get('target_type')}"
        )

    # persist the matching id so 2-0-setup/env.sh can emit OPS_GITHUB_* without retyping
    matched = [
        ins for ins in installs if (ins.get("account") or {}).get("login") == owner
    ] or (installs if len(installs) == 1 else [])
    if matched:
        meta["installation_id"] = matched[0]["id"]
        meta_path.write_text(json.dumps(meta, indent=2))
        print(f"saved installation_id={matched[0]['id']} to {meta_path}")
    else:
        print(
            f"WARNING: no installation matches owner {owner} — "
            "fill OPS_GITHUB_INSTALLATION_ID manually.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
