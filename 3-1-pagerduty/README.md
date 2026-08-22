# 3-1-pagerduty — 에이전트 에스컬레이션 페이징 (PagerDuty)

## 목표

2-3에서 알람이 Slack/Hermes로 도착하는 경로를 만들었다. 여기서는 그 위에
**에이전트가 런북으로 처리하지 못한 사건만 온콜을 페이지**하는 escalation 경로를
얹는다 — 알람은 전부 Slack(에이전트 triage)으로 가고, 사람 폰이 울리는 것은
에이전트가 서킷 브레이커에서 자동 대응을 포기하고 `ops_pagerduty_page_oncall`을
호출했을 때뿐이다. 런북으로 해소된 알람은 페이지가 아예 나가지 않는다.

이 디렉토리가 PagerDuty 계정 쪽 리소스(escalation policy · service · Events API v2
integration)를 IaC로 만드는 CI terraform 디렉터리다 — main 브랜치 tf-plan/tf-apply가
S3 state로 적용한다. 토큰 발급만 사람이 하고(PD가 API/Terraform 발급 미지원),
발급한 키는 repo secret으로 넣어 적용은 GHA가 한다 — 다른 스택과 같은 경로다.
여기서 뽑은 routing_key는 Grafana가 아니라 **Hermes 플러그인**(`OPS_PAGERDUTY_ROUTING_KEY`)에
배선한다 — Grafana에는 PD contact point가 없다(Slack 단일 통지, 2-3 README 참고).

## 전제

- 활성 PagerDuty 플랜(또는 유효한 트라이얼). 플랜이 없으면 정상 발급한 key도
  REST API에서 401(빈 body)을 반환해 `terraform init`의 provider 검증부터 실패한다
  — 키/헤더 문제가 아니라 계정 구독 tier 문제다. 플랜이 없으면 이 실습은 건너뛴다
  (2-3의 Slack·Hermes 라우팅은 그대로 동작).
- provider 인증용 API key — 반드시 full-access(read/write). 발급:
  Integrations > Developer Tools > API Access Keys > Create New API Key
  → "Read-only API Key" 체크 해제 (read-only면 apply/destroy가 403 Access Denied).

## 세팅 절차

토큰과 온콜 이메일을 repo에 등록하고(1회), CI로 apply한다:

```bash
gh secret set PAGERDUTY_TOKEN                               # full-access API key 붙여넣기
gh variable set PD_ONCALL_EMAIL --body '<본인 PD 로그인 이메일>'

gh workflow run tf-apply.yml --ref main -f target=3-1-pagerduty
gh run watch                                                # apply 완료 확인
```

이후 이 디렉토리 변경은 main으로의 PR → tf-plan(guard) → 머지 → 자동 apply로 흐른다
(다른 스택과 동일). 온콜 이메일을 tfvars로 커밋하지 않는 이유: 개인 이메일이 리포에
남지 않도록 repo variable로 주입한다(INFRA_SLACK_MENTION과 같은 패턴).

routing_key 확인 — state가 S3에 있으므로 AWS 자격증명으로 backend init 후 읽는다:

```bash
cd 3-1-pagerduty
terraform init \
  -backend-config="bucket=<project>-state-<account-id>" \
  -backend-config="key=states/3-1-pagerduty.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="use_lockfile=true"
terraform output -raw routing_key; echo
```

> 이전에 이 스택을 로컬 state로 apply한 적이 있다면(구 방식), 첫 CI apply 전에
> PD 콘솔에서 기존 service/escalation policy를 지우거나 `terraform import`로
> S3 state에 넣어야 한다 — 빈 state로 apply하면 service 이름 충돌로 실패한다.

## 플러그인에 배선 — Hermes .env

routing_key를 Hermes 호스트의 `~/.hermes/.env`에 넣고 재시작하면
`ops_pagerduty_page_oncall`(에스컬레이션 페이지)이 노출된다. 이 도구가 incident를
만드는 유일한 자동 경로다 — 같은 에피소드는 dedup_key로 병합돼 중복 페이지가 없다.

```bash
# routing_key를 위에서 확인한 뒤 Hermes 호스트에서:
echo "OPS_PAGERDUTY_ROUTING_KEY=<routing_key>" >> ~/.hermes/.env
# hermes 재시작으로 반영
```

## 플러그인 토큰 (선택)

플러그인 `.env`에 넣는 `OPS_PAGERDUTY_TOKEN`은 full-access key다 — 조회에 더해
incident ack/snooze/resolve(ops_pagerduty_manage_incident)까지 쓴다. incident write의
REST 필수 From 헤더용으로 `OPS_PAGERDUTY_FROM_EMAIL`(PD 로그인 이메일)도 함께 넣는다.
PagerDuty가 API/Terraform 발급을 지원하지 않아 UI 수동 발급이 유일한 경로다
(API Access Keys > Create New API Key). 위 provider용 키를 재사용해도 된다 —
단순함이 목표인 실습에선 키 하나로 충분하다.

## destroy

tf-destroy 워크플로로 지운다 (destroy-approval environment 승인 게이트 동일):

```bash
gh workflow run tf-destroy.yml --ref main -f target=3-1-pagerduty
# Hermes .env의 OPS_PAGERDUTY_ROUTING_KEY도 지워야 페이지 도구가 내려간다
# (남겨두면 도구는 노출되지만 전송이 4xx로 실패한다).
```
