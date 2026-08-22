---
name: fc-deploy-verify-phase1
description: 기본 환경 Phase 1 세팅을 읽기 전용으로 검증할 때 사용 — "초기 세팅 잘 됐어?", "Phase 1 확인", "state/foundation/GitHub/Hermes 기본 세팅 봐줘", 2-0-setup 직후 또는 수업·리허설 전 점검. state 버킷, foundation, 리포 거버넌스, Cloudflare 기본 배선, Hermes core를 확인한다. Grafana provisioning·Grafana Hermes 배선·PagerDuty는 fc-deploy-verify-phase2 대상이며, dev/prod 서비스 스택은 fc-e2e-live 대상이다.
---

# Deploy Verify Phase 1

`2-0-setup`의 기반 세팅을 정본(`2-0-setup/README.md`, `2-0-setup/2-github/README.md`, `2-0-setup/3-hermes/README.md`)과 대조한다. 전 항목 read-only다.

## 범위 경계

- 포함: state 버킷, foundation 네트워크/IAM/상주 EC2/seed, GitHub 설정과 거버넌스, Cloudflare zone 기본 배선, Hermes core.
- 제외: Grafana HTTP/API, `4-grafana` state/dashboard/token, `OPS_GRAFANA_*`, `ops-monitoring-write`, PagerDuty 전체. `$fc-deploy-verify-phase2`로 확인한다.
- 제외: dev/prod app·bastion·ALB·RDS·smoke. `$fc-e2e-live` 또는 Slack Hermes 조회로 확인한다.
- Grafana/PagerDuty 미배선 때문에 Hermes 로그에 나타나는 tool check warning은 Phase 1 실패로 잡지 않는다.

모든 로컬 AWS CLI 호출에 `--profile "$AWS_PROFILE" --region ap-northeast-2`를 붙인다. `$AWS_PROFILE`이 비어 있으면 setup 0단계에서 정한 프로파일명을 사용자에게 묻는다. 자격증명 만료 시 SSO는 `aws sso login --profile <프로파일>`, access key는 `aws configure --profile <프로파일>` 재인증을 안내한다.

## 체크 항목 (매 실행 전부 수행)

1. **준비물**
   - 현재 iac 리포가 사용자 소유 독립 리포이며 fork가 아닌지 확인한다.
   - 플러그인은 **원본 `wo-o/ops-agent-plugin`을 그대로 사용하는 것이 정답**이다. `gh repo view wo-o/ops-agent-plugin` 접근 가능 여부만 확인한다.
   - 사용자 소유 `ops-agent-plugin` 복제본을 요구하거나, 원본 사용을 이상으로 보고하거나, 별도 plugin 리포 생성을 권하지 않는다. app 리포도 별도 생성하지 않는다.

2. **0-bootstrap — state 버킷**
   - `<project>-state-<account>` 존재, versioning `Enabled`, 암호화, public access block 4개 `true`를 확인한다.

3. **1-foundation — 네트워크·접근**
   - VPC `10.42.0.0/16`, public subnet 2개(AZ 분산), IGW, NAT 없음, key pair `<project>`를 확인한다.
   - SG `<project>`의 외부 인바운드는 trusted IP로 제한되는지 현재 공인 IP와 CIDR을 대조한다. SG self/runner 참조 규칙은 정상이다.

4. **1-foundation — OIDC·IAM**
   - `token.actions.githubusercontent.com` OIDC provider를 확인한다.
   - GitHub API의 실제 `sub_claim_prefix`를 읽고 IAM trust와 한 글자 단위로 대조한다. 2026-07-15 이후 immutable-ID prefix를 이름 기반 문자열로 재구성하지 않는다.
   - plan=`<prefix>:pull_request`, apply에 main/dev branch sub가 모두 있고 전부 `StringEquals`인지 확인한다. destroy environment sub가 추가된 것은 정상이다.
   - `<project>-hermes-readonly` trust가 hermes 호스트 롤로 제한되는지 확인한다.
   - 로컬 프로파일의 apply role `assume-role`은 `AccessDenied`가 정상이다. 성공하면 과다 개방이다.

5. **1-foundation — 상주 리소스·seed**
   - `<project>-hermes`, `<project>-monitoring-server`, `<project>-gha-runner` 3대를 확인한다. `stopped`는 비용 절감 상태로 기록하고 실패로 잡지 않는다.
   - monitoring-server private IP `10.42.0.10`과 EIP 부착만 확인한다. Grafana `:3000` 응답은 Phase 2로 넘긴다.
   - seed 6종을 Name 태그로 확인한다: `seed-vol-a`, `seed-vol-keep`, `seed-snapshot`, `seed-eip`, `seed-orphan`, `seed-role`. seed-eip 미부착과 snapshot 빈 Description은 정상이다.

6. **러너**
   - GitHub Actions runner에 label `ansible`, status `online`, 최신 호환 버전이 있는지 확인한다. 필요하면 러너 호스트의 `Runner.Listener --version`을 SSH로 읽는다.
   - 최근 ansible-ops 실행은 참고하되 현재 러너 online/version/service를 우선 판정한다.

7. **2-github — secrets/vars**
   - 필수 secrets: `AWS_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `DB_PASSWORD`, `SLACK_WEBHOOK_URL`, `EXPIRY_APP_ID`, `EXPIRY_APP_PRIVATE_KEY`.
   - 필수 vars: `AWS_REGION`, `PROJECT_NAME`, `INFRA_SLACK_MENTION`.
   - `DB_PASSWORD`가 없으면 실패가 아니라 공개 fallback `AppDemoPw2026!` 사용 중으로 보고한다.
   - `EXPIRY_*` 누락은 현재 access-expiry 구성이 불완전한 실패다.

8. **2-github — 거버넌스**
   - `main-guardrails`·`dev-guardrails` 등록과 main/dev 실적용을 각각 확인한다. required check는 `guard`여야 한다.
   - main/dev `.github/CODEOWNERS`가 의도대로 다르고 owner가 iac 리포 소유자인지 확인한다. dev는 `2-1-dev/`·`modules/`·`ansible/`이 unowned여야 한다.
   - `destroy-approval` environment와 리포 소유자 required reviewer를 확인한다.

9. **Cloudflare 기본 배선**
   - dev/prod `env.auto.tfvars`의 `cloudflare_zone_id`가 모두 기입되고 동일한지 확인한다.
   - Hermes의 `OPS_CLOUDFLARE_READ_TOKEN`과 `OPS_CLOUDFLARE_ZONE_ID`가 둘 다 있거나 둘 다 없는지 확인하고, zone ID가 tfvars와 일치하는지 확인한다.
   - 미기입은 실패가 아니라 "시나리오 5·6은 PR 생성까지만 동작"으로 보고한다.

10. **CI — 현재 구성 상태**
   - `access-expiry` workflow가 active인지와 현재 `EXPIRY_APP_ID`·`EXPIRY_APP_PRIVATE_KEY` 존재 여부를 우선 판정한다.
   - `gh secret list`의 `updatedAt`과 schedule run `createdAt`을 비교한다. **현재 secret 등록보다 앞선 실패 실행은 과거 구성의 결과이므로 현재 실패로 세거나 "최근 3회 실패"라고 보고하지 않는다.**
   - 두 secret과 workflow가 현재 존재하면 "현재 구성 완료"로 보고한다. secret 변경 이후 완료된 schedule이 아직 없으면 "구성 완료·다음 실행 검증 대기"로 기록하며 실패로 잡지 않는다.
   - secret 변경 이후 실행이 실패한 경우에만 현재 runtime 실패로 보고하고 failed log를 읽어 원인을 제시한다. 실행 이력이 없어도 구성 누락으로 단정하지 않는다.
   - tf-plan/tf-apply 결과는 서비스 스택 영역이라 판정하지 않는다.

11. **Hermes core**
   - SSH로 hermes 호스트에 접속한다. `hermes gateway restart`는 금지한다.
   - gateway service active와 Slack 연결을 확인한다. Slack token prefix, home/free-response channel, `SLACK_ALLOW_BOTS=all`을 값 노출 없이 검증한다.
   - `hermes auth status openai-codex` logged in, config의 model provider/default, resolved `approvals.mode=off`를 확인한다.
   - `~/.hermes/.env` 존재와 mode 600을 확인한다. Phase 1 키만 검증한다: Slack 5종, `OPS_PROJECT_PREFIX`, `OPS_AWS_READ_ROLE`, Cloudflare pair, GitHub App 4종과 PEM 실존.
   - `OPS_IAC_REPO_PATH`·`OPS_ANSIBLE_SSH_KEY`는 stale 키로 보고한다.
   - 호스트 플러그인 origin은 `https://github.com/wo-o/ops-agent-plugin.git`이 기대값이다. 원본이 public이므로 호스트 `gh auth` 미인증만으로 실패 처리하지 않는다.
   - ops plugin enabled, `ops-read`·`ops-github-write`·`ops-ansible-write` enabled, git drift 없음, SOUL.md 첫 줄/전체 heredoc 정합, runbook 4종을 확인한다.
   - plugin toolset의 판정 정본은 `hermes tools list`다. `platform_toolsets.slack`·`known_plugin_toolsets.slack`에는 plugin toolset이 원래 나타나지 않을 수 있으므로 그 config 값만 보고 ops toolset 누락으로 판정하지 않는다.
   - `~/.hermes/skills/devops`는 fallback이다. 없어도 정상이고, 있을 때 diff는 정보로 보고하되 qualified plugin 스킬 4종이 정상이면 fallback 불일치만으로 실패 처리하지 않는다.
   - host TZ, AWS read role assume 성공, plugin pytest 통과를 확인한다.

## 실패 시 안내

- 1: 가이드 0장. iac 리포만 사용자 독립 리포인지 정정한다. plugin은 `wo-o/ops-agent-plugin` 원본을 사용한다.
- 2: 가이드 1장 — `bash 2-0-setup/0-bootstrap.sh`.
- 3~5: 가이드 2장 — `terraform -chdir=2-0-setup/1-foundation init` 후 `bash 2-0-setup/foundation.sh apply`.
- 6: foundation 재apply로 runner를 교체·재등록한다.
- 7: 가이드 1·3장. 누락 secret/var만 등록한다.
- 8: 가이드 3장. 브랜치별 CODEOWNERS를 정정한 뒤 `branch_ruleset.sh`와 `destroy_approval.sh`를 멱등 실행한다.
- 9: 가이드 8장. 두 tfvars에 동일 zone ID를 기록하고 Cloudflare write secret을 등록한다.
- 10: workflow가 disabled면 의도 확인 후 enable한다. `EXPIRY_*`가 없을 때만 3-hermes README의 GitHub App 산출물로 등록한다.
- 11: 가이드 6·7장과 `2-0-setup/3-hermes/README.md`. drift는 임의 폐기하지 않고 diff를 먼저 보고한다.

이 스킬은 복구 명령을 실행하지 않는다.

## 출력

한국어 첫 줄에 `Phase 1 세팅 정상 — 11개 항목 통과` 또는 `Phase 1 세팅 이상 N건`을 쓴다. 이어서 11개 항목 pass/fail 표, 그다음 이상 항목만 ① 읽기 전용 다음 조치 ② 정본 단계와 핵심 세팅 명령 순으로 제시한다. 현재 구성보다 오래된 CI 실패는 이상 건수에 넣지 않는다. Grafana/PagerDuty는 표와 이상 건수에서 완전히 제외하고 필요하면 마지막에 `$fc-deploy-verify-phase2` 대상으로 한 줄만 안내한다.
