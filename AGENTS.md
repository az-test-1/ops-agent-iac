# AGENTS.md

Claude Code는 `.claude/skills/`의 스킬을 자동 인식한다. 그 외 하니스(codex 등)는
스킬 자동 로드가 없으므로, 아래 상황에 해당하면 작업을 시작하기 전에 해당 스킬의
SKILL.md를 읽고 그대로 따른다.

| 상황 | 스킬 |
|---|---|
| 변경이 의도대로 됐는지 리뷰 | `.claude/skills/fc-intent-review/SKILL.md` |
| 서비스 떠 있는지 / 배포 확인 | `.claude/skills/fc-deploy-verify/SKILL.md` |
| e2e 시나리오 실제 실행 | `.claude/skills/fc-e2e-live/SKILL.md` |
| Slack 스레드 RCA ("왜 이렇게 했어?") | `.claude/skills/fc-slack-rca/SKILL.md` |
| 채널 보고 플러그인 개선 / 응답 품질 점검 | `.claude/skills/fc-plugin-improve/SKILL.md` |
| 사용자 Chrome으로 Slack 조작 | `.claude/skills/fc-browser-slack/SKILL.md` |

브라우저 조작은 Playwright MCP(extension 모드) 사전 설정이 필요하다 —
`.claude/skills/fc-browser-slack/setup.md`에 하니스별 등록 절차가 있다.
MCP 도구 이름 접두사는 하니스마다 다르다 — `browser_snapshot` 등 도구 이름으로
찾는다.
