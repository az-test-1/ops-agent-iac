---
name: fc-browser-slack
description: 코스 워크플로가 사용자의 실제 Chrome으로 Slack을 조작해야 할 때 사용 — 로그인된 사용자로서 #ops-agent에서 @Ops Agent에게 프롬프트 전송, 채널에서 Hermes 응답 읽기, 또는 Slack API/MCP가 실제 클라이언트를 대신하면 안 되는 모든 app.slack.com 조작. Playwright MCP + Chrome Bridge 연결 설정 레퍼런스도 겸한다 (setup.md 참고).
---

# Browser Slack (사용자 Chrome + Playwright MCP extension 모드)

이미 실행 중인 사용자의 Chrome을 — 실제 Slack 로그인 상태 그대로 —
`mcp__playwright_chrome__browser_*` 도구로 제어한다. Slack API/MCP가 실제
클라이언트를 대신할 수 없는 조작(클라이언트 UI 확인, 세션 상태 점검 등)에 쓴다.

최초 설정(MCP 서버 등록 + Bridge extension 설치)은 이 스킬 디렉토리의
`setup.md`. 아래 연결 체크가 실패했고 원인이 extension 연결 끊김이 아니라
설정 누락일 때만 읽는다.

## 연결 체크 (브라우저 조작 전 필수)
0. 도구가 있나? `browser_snapshot` 등 playwright 브라우저 도구가 도구 목록에
   아예 없으면 MCP 서버 미등록이다 — `setup.md`의 하니스별 등록 절차부터.
   (Claude Code 외 하니스는 도구 이름 접두사가 다르다 — `browser_snapshot`
   이름으로 찾는다.)
1. Chrome 실행 중? `pgrep -x "Google Chrome"` — 안 떠 있으면 → 사용자에게 Chrome
   실행을 요청한다 (extension 모드는 떠 있는 인스턴스에 붙는 방식이라 직접 못 띄운다).
2. Bridge 연결됨? `browser_snapshot` 호출. 타임아웃이면 → 사용자에게 Playwright
   MCP Bridge extension 아이콘 → **Connect** 클릭을 요청하고 재시도. extension은
   Chrome 재시작·프로필 전환 때마다 다시 연결해야 한다.
3. **Slack permalink URL로 navigate 금지.** `https://<ws>.slack.com/archives/...`
   permalink는 slack:// 딥링크 인터스티셜을 거치는데, 이 리다이렉트가 CDP 세션을
   죽인다(실측 2회: TypeError 후 브리지 사망, Connect 재클릭 필요). 항상
   `https://app.slack.com/client/<team-id>/<channel-id>` 형태로 이동하고,
   스레드는 채널 안에서 "N replies" 버튼을 클릭해 연다. Connect 직후 제어 탭이
   connect.html이어도 일반 URL navigate는 안전하다 — 딥링크만이 킬러다.
4. 맞는 컨텍스트? app.slack.com으로 이동해 snapshot에서 코스 워크스페이스와
   `#ops-agent`가 보이는지 확인. 워크스페이스/계정이 다르면 → 사용자에게 Chrome에서
   전환을 요청한 뒤 extension을 재연결.

단일 세션 전용: extension 모드는 Chrome 하나를 에이전트 세션 하나에 묶는다.
두 번째 세션이 브라우저를 공유하면 탭 경합이 생긴다.

## 기본 루프
모든 조작은 가장 최신 `browser_snapshot`의 `ref`가 필요하다 — 페이지가 갱신되면
ref는 무효가 된다. snapshot → 분석 → 조작 → snapshot으로 검증. selector를
추측하지 않는다.

## #ops-agent에 메시지 보내기 (신뢰 가능한 시퀀스)
Slack composer는 Quill 리치텍스트 에디터라 mention chip 관련 race가 알려져 있다 —
mention 뒤에 본문을 한 글자씩 타이핑하면 메시지가 깨진다. 항상:
1. composer 클릭 → `@Ops Agent` 입력 → 자동완성 팝업에서 제안을 선택(Enter)해서
   mention을 chip으로 만든다.
2. 본문 전체를 한 번에 주입: 포커스된 composer에 `browser_evaluate`로
   `document.execCommand('insertText', false, <body>)`. mention chip 뒤에서
   `browser_type`으로 한 글자씩 입력하는 것 금지.
3. snapshot으로 composer를 다시 읽어 — Enter 누르기 전에 — 텍스트가 의도한
   그대로인지(프롬프트 원문, mention chip 유지) 확인한다.
4. 전송(Enter) 후 다시 snapshot으로 메시지가 올라갔는지 확인.

## 채널에서 응답 읽기
- `browser_snapshot`으로 폴링 — 반드시 `filename` 파라미터를 넘겨 snapshot을
  디스크에 쓰고 선별적으로 Read한다. Slack 페이지는 매우 커서, snapshot 수백 개를
  컨텍스트에 직접 받으면 실행 도중 컨텍스트가 고갈된다.
- 스레드의 최신 메시지가 중간 진행 메모라면 완료가 아니다 — 완료 기준은 호출자가
  정의한다.

## 알려진 제약 (Slack 관련)
- 클립보드는 Playwright에서 접근 불가 — 복사가 아니라 DOM에서 텍스트를 추출한다.
- extension 모드에선 파일 업로드가 막혀 있다 (CDP 제약) — 사용자에게 수동 업로드를
  요청한다; `browser_file_upload` 재시도 금지 (실패한 시도마다 file-chooser
  다이얼로그가 쌓여 페이지를 막는다; `browser_close` + 채널 URL로
  `browser_navigate`해서 복구).
- 활성 탭은 한 번에 하나; 전환은 `browser_tabs`.

## 에러 처리
| 에러 | 조치 |
|---|---|
| 연결 타임아웃 | 사용자가 Bridge extension → Connect 클릭, 재시도 |
| Chrome 안 떠 있음 | 사용자가 먼저 Chrome 실행 |
| stale ref | 재-snapshot 후 새 ref 사용 |
| composer 텍스트 깨짐 | composer 비우고 전송 시퀀스를 1번부터 다시 |
| "Target page ... has been closed" | `browser_tabs` → `browser_navigate`로 복구 |
| permalink(archives URL) navigate 후 TypeError → 브리지 사망 | slack:// 딥링크가 CDP를 죽인 것 — 사용자 Connect 재클릭 요청 후 app.slack.com/client URL로만 이동 |
| Connect를 눌러도 계속 "browser has been closed" | 다른 에이전트 세션의 `--extension` MCP 서버가 살아 있어 Connect가 그쪽 relay에 붙는 경합. `ps aux \| grep 'playwright-mcp --extension'`으로 현 세션 외 프로세스를 kill한 뒤 Connect 재클릭 (Slack 탭 활성 상태에서) |
