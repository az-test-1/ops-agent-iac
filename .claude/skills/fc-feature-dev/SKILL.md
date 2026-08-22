---
name: fc-feature-dev
description: Fastcampus 워크스페이스(ops-agent 3-repo) 전용. ops-agent 서비스의 동작을 바꾸거나 기능을 추가·확장하라는 요청에 사용 — "~하게 바꿔줘", "~도 되게 확장하고 싶어", "~기능 넣어줘" (예. "EC2 접근을 bastion 경유로만", "disk-grow를 role_app 외 역할로 확장"). 기존 구현의 리뷰(fc-intent-review), 응답 품질 개선(fc-plugin-improve), 사건 RCA(fc-slack-rca), 라이브 검증(fc-e2e-live)에는 쓰지 않는다.
---

# Feature Dev (ops-agent 3-repo 신기능·동작 변경)

요청을 관찰 가능한 동작 변화로 명세화하고, 그 동작을 소유한 지점을 3-repo(ops-agent-app / ops-agent-iac / ops-agent-plugin)에서 확정한 뒤, 닿는 경로 전부를 같은 흐름에서 구현하고 정본 문서를 함께 갱신한다. 구현 후 검증은 이 스킬의 소유가 아니다 — 정적 대조는 fc-intent-review, 라이브는 fc-e2e-live로 인계한다.

## 1. 요청 → 동작 명세
- 요청을 "누가(수강생/에이전트) 무엇을 하면, 무엇이 지금과 달라지는가"로 한 문장 재진술한다.
- `docs/scenario-prompts.md`(워크스페이스 루트)와 대조: 어느 시나리오·갈래의 동작이 바뀌는지, 아니면 새 갈래인지 적는다. 시나리오에 닿지 않는 변경은 드물다 — 닿는 곳이 안 보이면 탐색이 부족한 것부터 의심한다.
- 범위가 갈리면 AskUserQuestion: dev만 vs prod까지, 기존 동작 대체 vs 병행 옵션, 에이전트 경유 경로(plugin) 포함 여부. 명확하면 묻지 않고 진행한다.

## 2. 설계 전 필터
- `reviews/settled-decisions.md`를 로드한다 (없으면 빈 목록). 사용자의 명시 요청이 곧 결정이다 — 요청이 settled 결정이나 기존 코스 설계와 충돌해도 되묻지 않고 진행하되, 충돌 사실과 당시 사유를 응답에 한 줄로 알린다. 구현 후 settled-decisions.md의 해당 항목을 새 결정으로 갱신한다. 이 필터가 진행을 막는 경우는 아래 프로드 게이트 하나뿐이다.
- 불가침: 2-* prod 게이트(승격 PR 사람 승인, incident-mode 등) 구조 변경 금지. 기능이 게이트 변경 없이는 불가능하면 구현하지 말고 그 사실을 보고한다.
- 실습용 위협모델, 단순함이 목표: 새 guard 레이어·검증 래퍼·이론적 오용 방어를 기능에 끼워 넣는 것은 개선이 아니라 결함이다. 기존 구조 위에 최소 변경.
- 구조·실행주체를 단정하기 전에 `rg`로 현재 코드를 확인한다 — 기억·옛 문서 금지 (repo 재생성 이력, docs stale 사례 다수).

## 3. 소유 지점 확정
| 동작 | 소유 | 라이브 반영 경로 |
|---|---|---|
| HTTP 앱 동작 | ops-agent-app | 태그 릴리스(vN) → iac tfvars `app_version` bump → merge → CI apply (blue-green 교체) |
| 인프라 (SG·ALB·RDS·EC2·DNS·알람) | ops-agent-iac `modules/` · `2-1-dev/` · `2-2-prod/` | merge → CI apply. dev 직접 push는 tf-apply가 안 뜬다(No PR found) → workflow dispatch |
| 조치 플레이북 | ops-agent-iac `ansible/<name>.yml` + `playbooks.yml` 등록 + 파라미터 받으면 `ansible/specs/<name>.yml` | allowlist=환경 정본 브랜치 등록분 (dev=dev, prod=main 승격). specs/는 dev에서도 사람 소유 |
| 에이전트 tool·skill·SOUL | ops-agent-plugin | 리포 수정 → 호스트 동기화(cp/scp) + hermes restart. 커밋 ≠ 라이브 |
| CI·거버넌스 | ops-agent-iac `.github/workflows/` | push 즉시 |

- 하나의 기능은 보통 여러 줄에 걸친다. 예: "bastion 경유만 허용" = iac SG 변경 + plugin의 접근 안내 runbook + scenario-prompts 갱신. "disk-grow 대상 역할 확장" = `ansible/disk-grow.yml` hosts 파라미터화 + `specs/disk-grow.yml` 신설 + `playbooks.yml` desc + plugin skill의 조치 안내 + 문서.
- 닿는 지점 목록을 먼저 완성하고 구현을 시작한다. 구현 중 새 지점이 드러나면 목록에 추가하고 같은 흐름에서 처리한다.

## 4. 구현
- 전 경로 커버 하드룰: dev·prod 양쪽과 관련 시나리오 갈래 전부를 같은 흐름에서 끝까지 구현한다. 일부만 하고 "나머지는 미커버"로 보고하는 것은 금지된 패턴이다. 의도적으로 범위를 좁히려면 구현 전에 사용자 합의를 받는다.
- 변경한 repo의 테스트를 돌린다: 3-repo 모두 `python3 -m pytest tests -q`. terraform 변경은 `terraform validate` 로컬 + plan은 CI tf-plan으로 확인한다.
- 스택이 철거 상태면(라이브 리소스 없음) 코드·등록·문서까지 완성하고, 라이브 반영은 "재구축 후 적용"으로 상태를 명시한다 — 죽은 스택에 apply를 시도하지 않는다.

## 5. 정본 문서 동기화
같은 커밋 배치에서 갱신한다 — doc-drift는 fc-intent-review가 finding으로 잡는 유형이고, plugin 안내·docs가 옛 동작을 서술하면 에이전트가 옛 경로로 수강생을 안내한다.
- `docs/scenario-prompts.md` — 시나리오 기준선이 바뀌면 반드시.
- 닿은 디렉토리의 README (`2-0-setup/`, 모듈, plugin `PLUGIN.md` 등).
- 슬라이드(`sessions/dayN/slides.html`)에 닿으면 이 스킬에서 고치지 않는다 — 변경 사실만 보고하고 슬라이드 작업은 별도로.

## 6. 커밋·반영 보고 (출력 계약)
- ops-agent-iac는 확인 질문 없이 바로 커밋하고 `git show --stat HEAD`로 검증 후 즉시 push한다 (amend 전 fetch로 HEAD가 내 미push 커밋인지 확인). app·plugin도 conventional commits로 커밋한다.
- 채팅은 한국어, 첫 줄에 판정: "구현 완료 — repo N개 변경, 라이브 반영 상태: ...". repo별 반영 상태를 넷 중 하나로 명시: applied / merged-not-applied / committed-not-synced(plugin) / 스택 부재로 보류.
- 마지막에 검증 인계를 제안한다: 정적 대조 fc-intent-review, 라이브 확인 fc-e2e-live. 이 스킬 안에서 검증을 반복하지 않는다.

## Red flags
| 생각 | 실제 |
|---|---|
| "iac만 고치면 끝" | 동작은 3-repo에 걸친다. plugin 안내·docs가 옛 동작이면 에이전트가 옛 경로로 안내한다. |
| "커밋했으니 반영됐다" | repo마다 반영 경로가 다르다 — CI apply / app_version bump / 호스트 동기화. 커밋 ≠ 라이브, 상태를 넷 중 하나로 말한다. |
| "dev에서 됐으니 prod도 됐다" | prod는 main 승격분이 정본이다. 갈래별로 따로 확인한다. |
| "기존 설계 의도와 다르니 먼저 물어보자" | 사용자의 명시 요청이 결정이다. 충돌은 한 줄 고지 후 바로 진행 — 진행을 막는 건 prod 게이트뿐이다. |
| "게이트를 우회하면 구현이 간단해진다" | 2-* prod 게이트 불가침. 우회 설계 금지 — 필요하면 중단하고 보고한다. |
| "안전하게 검증 레이어를 하나 추가하자" | 실습용 위협모델: 레이어 추가는 기능이 아니라 보고 대상 결함이다. |
| "구조는 기억하고 있다" | repo 재생성·문서 stale 이력이 있다. rg로 현재 코드를 확인한 뒤 단정한다. |
| "핵심 경로만 하고 나머지는 나중에" | 전 경로를 같은 흐름에서. 범위 축소는 구현 전 사용자 합의로만 한다. |
