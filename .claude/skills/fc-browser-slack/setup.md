# Playwright MCP (extension 모드) — 최초 1회 설정

Claude Code를 이미 실행 중인 Chrome에 연결해서 브라우저 조작이 실제 프로필
(기존 Slack 로그인 포함)에서 돌게 한다. fc-e2e-live와 fc-browser-slack에
필요하다. 한 번 설정하면 런타임엔 다시 볼 일 없다 — 실행 방법은 SKILL.md.

## 동작 방식
1. Chrome은 평소처럼 사용자 프로필로 실행된다.
2. **Playwright MCP Bridge** Chrome extension이 CDP 브리지를 연다.
3. Playwright MCP 서버(`@playwright/mcp`의 `--extension` 모드)가 그 브리지로
   연결되고, Claude가 활성 탭을 제어한다.

## 설치
1. Chrome에 "Playwright MCP Bridge" extension 설치
   (Chrome Web Store ID: `mmlmfjhmonkocbjadbfplnigmagldckm`).
2. 사용하는 하니스에 MCP 서버 등록. token은 extension 아이콘을 클릭하면 보이며,
   하니스가 달라도 같은 token을 쓴다.

Claude Code — `~/.claude.json`의 `mcpServers`:

```json
{
  "playwright_chrome": {
    "type": "stdio",
    "command": "npx",
    "args": ["@playwright/mcp@0.0.70", "--extension"],
    "env": {
      "PLAYWRIGHT_MCP_EXTENSION_TOKEN": "<extension이 보여주는 token>"
    }
  }
}
```

Codex CLI — `~/.codex/config.toml` (`codex mcp add`로도 등록 가능):

```toml
[mcp_servers.playwright_chrome]
command = "npx"
args = ["@playwright/mcp@0.0.70", "--extension"]

[mcp_servers.playwright_chrome.env]
PLAYWRIGHT_MCP_EXTENSION_TOKEN = "<extension이 보여주는 token>"
```

나중에 token을 재발급하면 등록해 둔 설정을 갱신하고 하니스를 재시작한다
(MCP 서버는 시작 시점에 token을 읽는다).

## Claude Code 외 하니스(codex 등)에서 쓸 때
- codex는 리포 루트의 `.agents/skills`(→ `.claude/skills` symlink, 리포에 포함)에서
  이 스킬을 자동 로드한다. 스킬 자동 로드가 없는 그 외 하니스는 프로젝트 지침
  파일(AGENTS.md 등)에 "브라우저로 Slack을 조작하기 전에 이 스킬 디렉토리의
  SKILL.md를 읽고 그대로 따를 것" 포인터를 넣어야 한다.
- 도구 이름 형식이 다르다: `mcp__playwright_chrome__browser_snapshot` →
  `playwright_chrome.browser_snapshot` 식. 이름이 달라도 같은 도구다.
- Chrome 하나 ↔ 세션 하나 제약은 하니스를 가로질러 적용된다: 다른 하니스의
  세션이 `playwright-mcp --extension` 프로세스를 물고 있으면 Connect가 그쪽
  relay에 붙는다. 기존 세션을 먼저 종료(또는 해당 프로세스 kill)한다.

## 확인
1. Chrome을 열고 Bridge extension 아이콘 → **Connect** 클릭.
2. 하니스에서 아무 `browser_snapshot` 도구 호출
   (예: "브라우저 스냅샷 떠줘") — 페이지 트리가 돌아오면 정상.
3. 타임아웃이면 → extension이 연결 안 된 상태 (Connect 다시 클릭; Chrome
   재시작·프로필 전환 후엔 매번 필요), 또는 token이 낡은 것.

## 제약
- Chrome이 이미 실행 중이어야 한다 — extension 모드는 직접 못 띄운다.
- Chrome 하나 ↔ 에이전트 세션 하나. 병렬 세션은 탭을 두고 경합한다.
