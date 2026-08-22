---
name: fc-slack-rca
description: 사용자가 Hermes/ops-agent 대화의 Slack permalink(…slack.com/archives/…)를 공유하며 에이전트가 왜 그렇게 동작했는지 물을 때 사용 — "왜 이렇게 했어?", "왜 이렇게 답했지?", "이상하게 동작했어", 잘못된 tool 선택, 잘못된 PR, 놓친 알람, 또는 ops Slack 채널의 모든 예상 밖 에이전트 응답.
---

# Slack RCA (Hermes 행동 → plugin/iac 근본 수정)

Slack 스레드에서 에이전트가 무엇을 보고 무엇을 했는지 재구성하고, 에이전트의 실제 입력에서 근본 원인을 찾아, ops-agent-plugin이나 ops-agent-iac의 소스에서 고친다. 스레드는 증상이다; 원인은 에이전트에게 주어진 것 안에 있다. 증상 패치 금지.

## 1. 스레드 읽기
- Permalink `…/archives/<CHANNEL>/p<digits>` → ts = 숫자열 마지막 6자리 앞에
  점 (`p1752640000123456` → `1752640000.123456`); `?thread_ts=` = 부모 메시지.
- Slack MCP `slack_read_thread` (대안: 해당 ts 주변을 `slack_read_channel`).
  MCP를 못 쓰면 → 사용자에게 스레드 텍스트를 붙여달라고 요청.
- 추출: 사용자의 정확한 프롬프트, 모든 에이전트 응답, 에이전트가 서술한 tool
  호출, Grafana 알람 메시지 (incident 시나리오), 타임스탬프.

## 2. 에이전트의 입력 재구성
동작은 정확히 다음 것들의 함수다 — 스레드가 시사하는 것부터 확인:
- SOUL.md — canonical은 plugin README의 heredoc; 라이브 호스트 복사본은 드리프트 가능.
- Plugin 스킬 `skills/ops-operating|ops-change|ops-incident-response/SKILL.md`
  (라우팅 runbook) — 호스트의 `~/.hermes/skills`는 리포 복사본; 드리프트 가능.
- Tool 정의: `schemas.py`, `tools_*.py` — 모델이 실제로 본 이름/파라미터/description.
- Tool 출력: read tool이 반환한 것 (필요하면 read-only로 호출을 재현).
- iac 계약: guard workflow, CODEOWNERS/ruleset, surface tfvars, `ansible-ops.yml` +
  `ansible/playbooks.yml` 등록부·`ansible/specs/` 스펙.
리포와 호스트가 다를 수 있으면, 리포를 탓하기 전에 둘을 diff한다.

## 3. 근본 원인 분류 (주 원인 하나를 고른다)
| 레이어 | 의미 |
|---|---|
| instruction | SOUL.md / 스킬 runbook이 이 케이스를 잘못 또는 모호하게 라우팅 |
| tool definition | description/파라미터 스키마가 모델을 오도 |
| tool output | read tool이 잘못된/불충분한 데이터를 반환; 모델의 추론은 정상 |
| iac contract | guard/CODEOWNERS/등록부·스펙이 문서와 다르게 동작 |
| wiring drift | 리포는 정상; 호스트 복사본이 낡음 |
| model/user prompt | 코드 결함 아님 — 기록만, 수정 없음 |

하드룰: file:line은 직접 Read한 뒤에만 인용; `reviews/settled-decisions.md`를
먼저 확인 (없으면 → 빈 제외 목록으로 진행) — 목록에 있는 항목은 재보고 불가.

## 4. 소스에서 수정
- 위협모델 필터 먼저 (실습: 단순함이 목표; 새 guard 레이어는 대개 해결책이
  아니라 결함 — 기존 instruction/tool을 고치는 쪽을 우선).
- plugin → 수정 + `python3 -m pytest tests -q` + 커밋.
- iac → 수정 + 커밋; 반영은 PR→guard→merge→GHA 경로로만, 로컬 apply 금지.
- SOUL.md / 스킬 텍스트 → 리포(canonical)에서 고치고, 호스트 재동기화가
  필요하다는 것을 출력에 명시 (git pull + restart; SOUL은 scp) — 그때까지
  라이브 동작은 안 바뀐다.
- 진짜 설계 분기 → 수정 전에 옵션을 제시하고 사용자에게 묻는다.

## 5. 수정을 라이브로 증명
테스트는 코드 경로를 증명할 뿐 동작을 증명하지 않는다 — 수정의 확인은
재트리거뿐이다. 호스트 재동기화 후 (그리고 재시작으로 재개된 작업이 있는지
채널 확인 후 — 중복 PR 레이스), 원래 프롬프트(또는 최소 재현)를 채널에서
다시 보내 기대 동작을 관찰한다. 사용자가 이를 명시적으로 미룰 수 있다 —
그러면 조용히 생략하지 말고 출력에 그렇게 적는다.

## 6. 출력 계약
한국어, 첫 줄: `원인: <레이어> — <한 문장>`. 이어서 스레드 증거(인용 메시지),
원인 증거(file:line), 적용한 수정 + 테스트 결과, 라이브 재확인 결과(또는
사용자가 미룸), 호스트 재동기화 필요 여부. 주목할 finding →
`reviews/YYYY-MM-DD-slack-rca-<slug>.md`.

## Red flags
| 생각 | 실제 |
|---|---|
| "스레드만 봐도 원인이 명확하다" | 스레드 = 증상. 에이전트의 입력을 먼저 읽어라. |
| "검증 레이어를 추가하면 된다" | 위협모델: 여기선 레이어 추가가 결함이다. |
| "호스트에서 바로 고치자" | 리포가 canonical; 호스트 수정은 드리프트를 만든다. |
| "리포 고쳤으니 끝" | 호스트 재동기화 전까지 라이브 에이전트는 그대로다 — 그렇게 말하라. |
