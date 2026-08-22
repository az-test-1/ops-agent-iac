---
name: fc-intent-review
description: ops-agent 서비스가 코스 의도대로 구현됐는지 리뷰·검증을 요청받을 때 사용 — "의도대로 됐는지", "리뷰해줘", "검토해줘", "빠진 거 없어?", 리허설·수업 전, 또는 ops-agent-app/iac/plugin에 걸친 커밋 배치 이후.
---

# Intent Review (ops-agent 3-repo)

구현(ops-agent-app / ops-agent-iac / ops-agent-plugin)을 코스 의도와 대조한다. finding은 file:line을 직접 확인하고 settled/위협모델 필터를 통과한 뒤에만 보고할 수 있다.

## 의도 소스 (우선순위 순)
1. `docs/scenario-prompts.md` (워크스페이스 루트) — 시나리오 9개 (dev 자동 / prod 게이트) = "완료" 기준선
2. `docs/curriculum.md` — 코스 개요
3. `docs/setup-command-guide.md` — 부트스트랩 순서 + step-10 smoke test
4. `docs/e2e-findings-*.md` — 알려진 blocker 상태 (오래됐을 수 있음; 코드에서 재검증)
5. Repo 계약: iac repo `README.md` 핵심원칙 + plugin repo `PLUGIN.md`

의도 문서끼리 충돌하면 repo 문서/코드가 우선 — 문서가 repo를 설명하는 것이지 그 반대가 아니다.

## 절차
1. 제외 목록을 먼저 로드: `reviews/settled-decisions.md` + 가장 최근 `reviews/*.md`. 목록에 있는 항목은 논외. 두 파일이 없으면 → 빈 제외 목록으로 진행 (새 환경에선 정상).
2. 범위 선택: **delta** (기본 — 마지막 리뷰 파일 이후 변경: repo별 `git log` + 미커밋 diff), 또는 repo / 시나리오 N / full. full 범위는 repo별로 Explore agent를 병렬로 띄울 수 있다.
3. finding 후보 수집. 후보마다 기록: repo/file:line, 위반한 의도 소스, severity.
4. 검증: 출력에 넣기 전에 주장된 file:line을 직접 Read한다. subagent의 주장은 후보일 뿐 finding이 아니다 (이 프로젝트에서 측정된 false-positive율 25-50%). repo를 가로지르는 주장은 양쪽을 모두 읽어야 한다 (예: plugin tool ↔ 그것이 겨냥하는 iac 경로).
5. 위협모델 필터: 수강생 본인의 AWS 계정, 수강생이 운영하는 Hermes, write 경로 = PR 둘 — surface tfvars PR(dev·prod) + dev 한정 코드 PR(2-1-dev/·modules/·ansible/, 2026-07-20 개방; prod 코드는 dev→main 승격 PR 사람 승인, 비용 상한은 tf-plan 비용 가드레일이 2차 강제) (customs/는 제거됨, iac c28dac1 — 부활 제안 금지), apply는 merge 후 CI로만. "dev에서 에이전트가 .tf를 고칠 수 있다"는 finding이 아니라 설계다 — dev 코드 PR의 무승인 auto-merge를 위반으로 보고하지 않는다. 이론적 / 공급망 / prompt-injection finding → 최대 한 줄: "이론적 위험 — 위협모델상 수용". 과잉 설계(불필요한 레이어, dead path, 중복 검증)는 보고 대상 finding이다.
6. 생존 항목 분류: severity (critical/high/medium/low) × 유형 (intent_mismatch / bug / doc-drift / over-engineering / cleanup).

## 출력 계약
1. `reviews/YYYY-MM-DD-<scope>.md` 작성. finding마다: `[severity] [type] repo/file:line`, 메커니즘 한 문단, 위반한 의도 소스, `verified: <방법>`. 다음 delta 실행의 기준선이 되도록 "지난 리뷰 이후 수정됨" 목록 포함.
2. 채팅 응답은 한국어, 첫 줄에 판정 ("의도 대비 격차 N건 — critical X, high Y, ..."), finding은 severity 순. 과정 서술 금지.
3. 사용자가 finding을 기각하면 → 같은 턴에 기각 사유와 함께 `reviews/settled-decisions.md`에 추가.

## Red flags — 버리거나 재검증
| 생각 | 실제 |
|---|---|
| "Explore agent가 이미 확인했다" | 네가 직접 file:line을 읽기 전까진 finding이 아니다. |
| "심각하니까 다시 제기해도 된다" | settled는 settled. 새 증거가 있으면 → "재개 요청"으로 표시하고 먼저 묻는다; 재주장 금지. |
| "검증 레이어를 추가하면 해결된다" | 위협모델 체크 먼저. 여기선 레이어 추가가 보통 해결책이 아니라 결함이다. |
| "옛 리뷰 스냅샷에 깨졌다고 나온다" | 스냅샷은 낡는다. 현재 코드로 재검증 — 상당수는 이미 수정됐거나 무의미해졌다. |
