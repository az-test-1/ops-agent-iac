---
name: fc-plugin-improve
description: Slack 채널의 최근 ops-agent 응답을 점검해서 plugin을 개선하라는 요청에 사용 — "채널 확인해서 플러그인 개선해줘", "최근 응답 보고 개선점 찾아줘", "에이전트 응답 품질 점검", 또는 특정 사건 없이 하는 주기적 개선 패스. 단일 permalink + "왜 이렇게 했어?"에는 쓰지 않는다 (fc-slack-rca 사용). 시나리오를 라이브로 돌리는 것도 아니다 (fc-e2e-live 사용).
---

# Plugin Improve (채널 스윕 → plugin 개선)

코스 Slack 워크스페이스 `#ops-agent`의 최근 Hermes 응답을 훑고, 의도 대비 채점하고, 확인된 약점을 root-cause한 뒤 ops-agent-plugin의 소스에서 고친다. fc-slack-rca를 permalink 하나에서 최근 채널 히스토리로 일반화한 것 — 인과 레이어도, 하드룰도 동일하다.

## 1. 스윕 범위 정하기
- Slack MCP `slack_read_channel`로 채널을 읽는다 (채널 `#ops-agent`).
- 기본 범위: 가장 최근 `reviews/*plugin-improve*.md` 이후 (없으면 최근 7일
  또는 ~30개 스레드). 사용자가 범위/개수를 지정하면 그것이 우선.
- 이월 항목 로드: 가장 최근 plugin-improve 리뷰 문서의 "관찰 — 재발 시 수정"
  목록을 가져온다 (없으면 빈 목록). 이번 스윕에서 재발한 증상은 그 이전 관찰을
  3단계의 2회+ 기준에 합산한다.
- 에이전트가 관여한 모든 스레드에 `slack_read_thread`를 실행하고 수집: 사용자
  프롬프트, 각 에이전트 응답, 서술된 tool 호출, 되묻기, 최종 산출물
  (PR URL / 명령 / 판정), 메시지 간 지연.

## 2. 스레드별 채점
기준선 = 커리큘럼 의도 (`docs/scenario-prompts.md`, 워크스페이스 루트)와
SOUL.md 계약 (한국어, 표 금지). 스레드마다 pass / weak를 매기고,
weak면 증상을 기록:
- 잘못된 결과: 잘못된 env, 잘못된 repo, 잘못된 tool/runbook 라우팅, 산출물 누락
- 프로세스: 불필요한 되묻기, follow-through 누락, stall, 중복 작업
- 출력 계약: 언어/포맷 위반, 장황함, PR 링크나 명령 누락
- 동작은 맞지만 사용자가 스레드에서 낮게 평가한 경우 (reaction/답글도 증거로 인정)

## 3. 제안 전에 root-cause
- 일회성 vs 패턴: weak 스레드 하나는 결함이 instruction/tool 정의에 명백히
  있는 경우가 아니면 모델 variance다. plugin 수정은 (a) 증상이 2회 이상 —
  이전 스윕의 이월 관찰 포함 (1단계 carry-over) — 이거나 (b) 단일 사례를
  완전히 설명하는 결함을 file:line으로 지목할 수 있을 때만. 아니면 리뷰
  문서에 "관찰 — 재발 시 수정"으로 기록만 한다.
- fc-slack-rca의 레이어 표(instruction / tool definition / tool output /
  iac contract / wiring drift / model·user prompt)로 분류하고, 같은 방식으로
  에이전트의 실제 입력을 재구성한다 — 스레드는 증상이지 원인이 아니다.
- 하드룰: 보고 전에 주장된 file:line을 직접 Read (subagent 주장: 여기 FP율
  25~50%); `reviews/settled-decisions.md`를 먼저 확인 (없으면 → 빈 제외 목록)
  — 목록에 있는 항목은 어떤 프레이밍으로도 재보고 불가.

## 4. 소스에서 수정
- 위협모델 필터: 실습용 위협모델, 단순함이 목표. 새 guard 레이어, 검증 래퍼,
  이론적 오용 방어는 개선이 아니라 결함이다 — 기존 instruction/tool 텍스트를
  고치는 쪽을 우선한다.
- 의도를 보존하는 기계적 수정 (잘못된 description, 깨진 runbook 단계, 계약
  위반) → 수정 + `python3 -m pytest tests -q` + 커밋.
- 동작/설계 분기 (에이전트가 묻는 시점 vs 실행하는 시점 변경, tool 추가/제거,
  시나리오 라우팅 변경) → 수정 전에 옵션을 제시하고 사용자에게 묻는다.
- SOUL.md의 canonical은 plugin README의 heredoc; `~/.hermes/skills` 아래
  스킬은 리포 복사본. 리포에서 고치고 동기화한다 (cp/scp + hermes restart) —
  동기화 전까지 라이브 동작은 안 바뀐다. 재시작은 보류 중이던 요청을 재개한다:
  진행 중 스레드가 있는지 채널을 먼저 확인 (중복 PR 레이스).

## 5. 출력 계약
- 리뷰 문서: `reviews/YYYY-MM-DD-plugin-improve.md` — 스윕 범위, permalink가
  달린 스레드별 채점표, 증거(인용 메시지 + file:line)가 붙은 약점, 적용한
  수정 + 테스트 결과, 이월 관찰.
- 채팅: 한국어, 판정 먼저 — "N개 스레드 점검, 약점 M건, 수정 K건(동기화 완료/필요)".
- 사용자가 finding을 기각하면 → 같은 턴에 `reviews/settled-decisions.md`.

## Red flags
| 생각 | 실제 |
|---|---|
| "이 응답 하나만 봐도 프롬프트를 고쳐야" | 일화 하나 = variance. 패턴이나 file:line 증거, 아니면 기록만. |
| "검증 단계를 하나 추가하면 안전" | 실습용 위협모델: 레이어 추가가 보고 대상 결함이다. |
| "스레드 요약만으로 원인이 보인다" | 탓하기 전에 입력(SOUL/skills/schemas/tool output)을 재구성하라. |
| "리포 커밋했으니 개선 완료" | 런타임은 호스트 복사본을 돈다. 미동기화 수정 = 미수정 — 동기화 + 재시작, 그리고 그렇게 말한다. |
| "재시작하고 바로 확인해보자" | 재시작은 보류 작업을 재개한다 — 채널을 먼저 읽지 않으면 중복 PR 레이스. |
| "저번 리뷰에서 본 이슈, 다시 올리자" | settled-decisions.md는 구속력이 있다. 새 증거 → "재개 요청"하고 묻는다. |
