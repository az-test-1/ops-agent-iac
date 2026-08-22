#!/usr/bin/env python3
"""IaC 실습 리포 에이전트(쓰기 정체성)를 위한 원클릭 GitHub App 생성기.

이게 왜 필요한가
---------------
에이전트는 PR을 당신 이름이 아니라 자기 이름(예: `your-app[bot]`)으로 연다.
그 봇 정체성에는 GitHub App이 필요하다 — PAT를 쓰면 모든 PR에 당신 아이디가
찍힌다. GitHub App은 Terraform이나 평범한 API 토큰으로 만들 수 없다: 생성은
브라우저에서 "App Manifest flow"로 소유자가 승인한다. 이 스크립트는 그 필수
클릭 한 번만 빼고 나머지 과정을 전부 자동화한다:

  1. 작은 로컬 웹 서버를 띄운다 (포트는 OS가 빈 것을 자동 할당; --port로 고정 가능)
  2. 앱 이름 + 권한이 미리 채워진 폼을 보여준다
     (Contents: write, Pull requests: write, Metadata: read)
  3. "Create GitHub App"을 누르면 -> GitHub이 임시 코드와 함께 되돌려보낸다
  4. 스크립트가 그 코드를 app id + private key로 교환해
     ./ .secrets/ (git-ignored)에 저장한 뒤 설치 URL을 출력한다

Usage
-----
    python3 2-0-setup/2-github/create_github_app.py            # owner/repo는 gh로 자동 감지
    python3 2-0-setup/2-github/create_github_app.py --name my-bot        # 포트 자동
    python3 2-0-setup/2-github/create_github_app.py --port 9000          # 포트 고정

사전 요구사항: `gh` CLI 인증 (gh auth status). 그 외엔 없음 — stdlib만 사용.

끝나면 당신 repo에 앱을 설치(INSTALL)하고(링크가 출력됨), 자격증명을 에이전트에
연결하라 (2-0-setup/2-github/README.md 참고).
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import secrets
import ssl
import subprocess
import sys
import urllib.request
import webbrowser
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def _gh(*args: str) -> str:
    return subprocess.check_output(["gh", *args], text=True).strip()


def detect_owner_repo() -> tuple[str, str, str]:
    """현재 gh repo에서 (owner, repo, owner_type)를 반환하고, repo 안이 아니면
    인증된 사용자로 폴백한다."""
    try:
        full = _gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner")
        owner, repo = full.split("/", 1)
    except Exception:
        owner = _gh("api", "user", "--jq", ".login")
        # fallback: repo name follows the repository directory name
        repo = Path(__file__).resolve().parents[1].name
    try:
        owner_type = _gh(
            "api", f"users/{owner}", "--jq", ".type"
        )  # "User" | "Organization"
    except Exception:
        owner_type = "User"
    return owner, repo, owner_type


def build_manifest(owner: str, repo: str, name: str, redirect_url: str) -> dict:
    return {
        "name": name,
        "url": f"https://github.com/{owner}/{repo}",
        "redirect_url": redirect_url,
        "public": False,
        "default_permissions": {
            "contents": "write",  # 브랜치 생성 + tfvars 커밋
            "pull_requests": "write",  # PR 열기
            "actions": "write",  # ansible-ops workflow_dispatch + run 상태 조회(ops-ansible-write)
            "metadata": "read",
        },
        "default_events": [],
    }


FORM = """<!doctype html><html><head><meta charset=utf-8>
<title>Create {name}</title>
<style>body{{font-family:system-ui;max-width:640px;margin:60px auto;padding:0 20px;line-height:1.5}}
button{{font-size:18px;padding:12px 24px;background:#1f883d;color:#fff;border:0;border-radius:8px;cursor:pointer}}
code{{background:#f0f0f0;padding:2px 6px;border-radius:4px}}</style></head><body>
<h2>{name} — 봇용 GitHub App 생성</h2>
<p>이 앱은 에이전트가 <b>{owner}/{repo}</b>에 PR을 <b>봇 이름</b>으로 열게 해줍니다.
권한: Contents(write), Pull requests(write), Actions(write), Metadata(read).</p>
<p>버튼을 누르면 GitHub로 이동합니다. 확인 후 <b>Create GitHub App</b>을 누르면
자동으로 이 창으로 돌아와 자격증명을 저장합니다.</p>
<form action="{action}" method="post">
  <input type="hidden" name="manifest" value='{manifest}'>
  <button type="submit">Create GitHub App</button>
</form>
</body></html>"""


class _handler_placeholder(http.server.BaseHTTPRequestHandler):
    """바인딩 시점용 임시 핸들러 — main()에서 실제 핸들러로 교체된다."""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", help="App name (default <repo>-<owner>)")
    ap.add_argument(
        "--port",
        type=int,
        default=0,
        help="콜백 서버 포트 (기본 0 = OS가 빈 포트 자동 할당)",
    )
    ap.add_argument(
        "--out", default=".secrets", help="Dir to save app id + private key"
    )
    args = ap.parse_args()

    owner, repo, owner_type = detect_owner_repo()
    name = args.name or f"{repo}-{owner}"
    # 개인 계정과 organization은 생성 엔드포인트가 다르다
    if owner_type == "Organization":
        action = f"https://github.com/organizations/{owner}/settings/apps/new?state={{state}}"
    else:
        action = "https://github.com/settings/apps/new?state={state}"

    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    state = secrets.token_hex(8)
    result: dict = {"done": False}

    # 콜백 서버를 먼저 바인딩한다 — --port 0이면 OS가 빈 포트를 골라주므로
    # "port busy"로 실패할 일이 없다. manifest의 redirect_url에 실제 포트가
    # 박혀야 하므로 바인딩 후에 manifest를 만든다.
    try:
        srv = http.server.HTTPServer(("127.0.0.1", args.port), _handler_placeholder)
    except OSError as e:
        print(
            f"ERROR: port {args.port} busy ({e}). --port 없이 실행하면 자동 할당됩니다.",
            file=sys.stderr,
        )
        return 1
    port = srv.server_address[1]
    redirect_url = f"http://localhost:{port}/callback"
    manifest = build_manifest(owner, repo, name, redirect_url)

    class H(http.server.BaseHTTPRequestHandler):
        def _send(self, code: int, body: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self) -> None:  # noqa: N802
            p = urlparse(self.path)
            if p.path == "/":
                self._send(
                    200,
                    FORM.format(
                        name=name,
                        owner=owner,
                        repo=repo,
                        action=action.format(state=state),
                        manifest=json.dumps(manifest).replace("'", "&#39;"),
                    ),
                )
                return
            if p.path == "/callback":
                code = (parse_qs(p.query).get("code") or [""])[0]
                if not code:
                    self._send(400, "no code in callback")
                    return
                req = urllib.request.Request(
                    f"https://api.github.com/app-manifests/{code}/conversions",
                    method="POST",
                    headers={
                        "Accept": "application/vnd.github+json",
                        "User-Agent": "manifest-flow",
                    },
                )
                try:
                    with urllib.request.urlopen(
                        req, context=ssl.create_default_context(), timeout=30
                    ) as r:
                        data = json.load(r)
                except Exception as e:  # noqa: BLE001
                    self._send(500, f"conversion failed: {e}")
                    return
                (out / "app.pem").write_text(data["pem"])
                os.chmod(out / "app.pem", 0o600)
                meta = {
                    "app_id": data["id"],
                    "slug": data["slug"],
                    "client_id": data.get("client_id"),
                    "html_url": data.get("html_url"),
                    "owner": owner,
                    "repo": repo,
                }
                (out / "app.json").write_text(json.dumps(meta, indent=2))
                os.chmod(out / "app.json", 0o600)
                result.update(done=True, **meta)
                self._send(
                    200,
                    f"<h2>App 생성 완료 &#10003;</h2><p>app_id={data['id']} slug={data['slug']}</p>"
                    f"<p>이제 <b>설치</b>하세요: <a href='{data['html_url']}/installations/new'>"
                    f"{data['html_url']}/installations/new</a> → {repo} 선택 → Install.</p>"
                    f"<p>이 창은 닫아도 됩니다.</p>",
                )
                return
            self._send(404, "not found")

        def log_message(self, *a) -> None:  # 로그 출력 억제
            pass

    srv.RequestHandlerClass = H

    url = f"http://localhost:{port}/"
    print(f"Creating GitHub App '{name}' for {owner}/{repo} ({owner_type}).")
    print(f"Opening {url} — click 'Create GitHub App' in the browser.")
    try:
        webbrowser.open(url)
    except Exception:
        print(f"(open it manually: {url})")
    while not result["done"]:
        srv.handle_request()
    print(f"\nSaved credentials to {out}/app.pem and {out}/app.json")
    print(f"app_id={result['app_id']} slug={result['slug']}")
    print(f"INSTALL NOW: {result['html_url']}/installations/new  (select {repo})")
    print("Then wire it into the agent — see 2-0-setup/2-github/README.md.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
