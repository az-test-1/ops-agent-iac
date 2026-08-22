---
name: fc-deploy-verify-phase2
description: 후반 환경 Phase 2의 Grafana·PagerDuty 세팅을 읽기 전용으로 검증할 때 사용 — "Phase 2 확인", "Grafana provisioning 됐어?", "그라파나/Hermes 배선 확인", "PagerDuty 세팅 봐줘", Day 3 사전 세팅·수업·리허설 전 점검. foundation/GitHub/Hermes core는 fc-deploy-verify-phase1, dev/prod 서비스 라이브는 fc-e2e-live 대상이다.
---

# Deploy Verify Phase 2

Grafana provisioning과 Hermes Grafana/PagerDuty 연동만 검증한다. 정본은 `2-0-setup/README.md`의 4-grafana 절, `2-0-setup/3-hermes/README.md`, `3-1-pagerduty/README.md`다. 전 항목 read-only다.

## 범위 경계

- Phase 1 기반이 없으면 해당 전제만 차단 사유로 보고 `$fc-deploy-verify-phase1`을 먼저 안내한다. Phase 1 전 항목을 중복 실행하지 않는다.
- dev/prod app·ALB·RDS·smoke와 2-3 incident-response 알람 룰 자체는 판정하지 않는다.
- `hermes gateway restart`, Terraform apply, secret/env 수정, PagerDuty event 전송은 실행하지 않는다.

모든 로컬 AWS CLI 호출에 `--profile "$AWS_PROFILE" --region ap-northeast-2`를 붙인다. `$AWS_PROFILE`이 비어 있으면 setup 0단계 프로파일명을 사용자에게 묻는다.

## 체크 항목 (매 실행 전부 수행)

1. **Grafana 기반 endpoint**
   - foundation output 또는 EC2 인벤토리로 monitoring-server가 존재하고 private IP `10.42.0.10`, EIP 부착인지 확인한다.
   - trusted IP에서 public `:3000/api/health`가 HTTP 200이고 database `ok`인지 확인한다.

2. **4-grafana provisioning**
   - `terraform -chdir=2-0-setup/4-grafana state list`에서 folder, dashboard, service account, token 리소스를 확인한다.
   - `ops_grafana_url`, `ops_grafana_public_url`, `ops_grafana_token` output이 존재하는지 확인한다. token 원문은 출력하지 않고 hash/길이만 비교한다.
   - Grafana API `/api/search`로 service overview dashboard가 존재하는지 확인한다. 기본 admin 자격증명으로 dashboard 0개인 상태는 provisioning 미적용이다.

3. **Hermes Grafana 배선**
   - SSH로 hermes 호스트의 `.env` mode 600과 `OPS_GRAFANA_URL`, `OPS_GRAFANA_PUBLIC_URL`, `OPS_GRAFANA_TOKEN`을 확인한다.
   - URL은 Terraform output과 문자열로, token은 원문 노출 없이 hash로 대조한다.
   - 호스트에서 bearer token으로 Grafana `/api/search` read smoke를 실행한다.
   - `ops-read`가 enabled인지 확인하고 `ops-monitoring-write`는 on/off 현재 상태만 기록한다. 알람 대응 모드 토글이므로 어느 쪽도 이상이 아니다.

4. **PagerDuty 현재 구성과 Hermes 배선**
   - PagerDuty를 사용하는 환경이면 GitHub secret `PAGERDUTY_TOKEN`, variable `PD_ONCALL_EMAIL`과 3-1-pagerduty apply/state 존재를 확인한다.
   - routing key output과 Hermes `OPS_PAGERDUTY_ROUTING_KEY`가 일치하는지 원문 노출 없이 hash로 대조한다.
   - Hermes `OPS_PAGERDUTY_TOKEN`, `OPS_PAGERDUTY_FROM_EMAIL`, `OPS_PAGERDUTY_ROUTING_KEY` 3개를 확인한다. token은 full-access 용도이며 값은 출력하지 않는다.
   - PagerDuty REST GET으로 token 인증만 읽기 전용 smoke한다. incident 생성, ack, resolve, page event는 금지한다.
   - active plan이 없어서 사용자가 의도적으로 건너뛴 경우 `DEFERRED — PagerDuty 미사용`으로 기록하고 실패 건수에서 제외한다. 의도 확인 없이 임의로 deferred 처리하지 않는다.

## 실패 시 안내

- 1: Phase 1 foundation 전제 문제면 가이드 2장 — `terraform -chdir=2-0-setup/1-foundation init` 후 `bash 2-0-setup/foundation.sh apply`.
- 2: 가이드 5장 — `terraform -chdir=2-0-setup/4-grafana init` 후 `terraform -chdir=2-0-setup/4-grafana apply`.
- 3: 4-grafana output 3종을 `~/.hermes/.env`에 배선한다. 검증 중 gateway를 재시작하지 않는다.
- 4: `3-1-pagerduty/README.md`에 따라 현재 구성한다:

```bash
gh secret set PAGERDUTY_TOKEN
gh variable set PD_ONCALL_EMAIL --body '<본인 PD 로그인 이메일>'
gh workflow run tf-apply.yml --ref main -f target=3-1-pagerduty
```

apply 후 routing key와 PagerDuty 3개 키를 Hermes `.env`에 배선한다. 이 스킬은 위 명령을 실행하지 않는다.

## 출력

한국어 첫 줄에 `Phase 2 세팅 정상 — 4개 항목 통과`, `Phase 2 세팅 정상 — 3개 통과·PagerDuty deferred`, 또는 `Phase 2 세팅 이상 N건`을 쓴다. 이어서 4개 항목을 pass/fail/deferred 표로 제시하고, 이상 항목만 ① 읽기 전용 다음 조치 ② 정본 단계와 핵심 세팅 명령 순으로 적는다. Phase 1과 dev/prod 서비스 상태는 표와 이상 건수에 넣지 않는다.
