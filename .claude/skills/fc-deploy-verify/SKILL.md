---
name: fc-deploy-verify
description: 기본 환경 세팅(2-0-setup)이 적절한지 검증할 때 사용 — "초기 세팅 잘 됐어?", "세팅 확인해줘", "환경 세팅 봐줘", 2-0-setup 각 단계 직후, 수업·리허설 전 점검. dev/prod 서비스 스택 상태(app EC2·ALB·RDS·smoke)는 판단하지 않는다 — 서비스 라이브 확인은 Slack의 Hermes 조회 또는 fc-e2e-live.
---

# Deploy Verify (기본 환경 세팅)

2-0-setup이 만드는 공유 기반 — state 버킷 · 1-foundation · 리포 거버넌스 · 3-grafana · 4-hermes 연동 — 을 정본(`2-0-setup/README.md` + 하위 단계 README + `docs/setup-command-guide.md`)과 대조한다. dev/prod 서비스 스택(tfvars 기대 상태, app EC2·bastion, ALB/target, smoke, RDS)은 이 스킬의 판단 대상이 아니다 — 보여도 세팅 판정에 반영하지 않고 정보로만 기록한다. 전 항목 read-only.

모든 CLI 호출: `--profile "$AWS_PROFILE" --region ap-northeast-2`. `$AWS_PROFILE`이 비어 있으면 사용자에게 setup 0단계에서 정한 프로파일명을 물어서 쓴다. 자격증명이 만료됐으면 재인증을 요청한다 — SSO면 사용자가 터미널에서 `aws sso login --profile <프로파일>` 실행, access key면 `aws configure --profile <프로파일>` 재설정.

## 체크 항목 (전부 매 실행)
1. **준비물**: 실습 리포 2개가 템플릿 독립 리포로 존재 — iac(현 리포) + `gh repo view <owner>/ops-agent-plugin` (app 리포는 배포 중 자동 clone이라 별도 확인 불필요).
2. **0-bootstrap — state 버킷**: `<project>-state-<account>` 실존 + 버저닝 `Enabled`(`aws s3api get-bucket-versioning`) + 암호화(`get-bucket-encryption`) + 퍼블릭 액세스 차단(`get-public-access-block` 4항목 true).
3. **1-foundation — 네트워크·접근**: VPC `10.42.0.0/16` + 퍼블릭 서브넷 2개(AZ 분산) + IGW, NAT 게이트웨이 없음(발견 시 비용 이상으로 보고). key pair `<project>` 등록, SG `<project>` 인바운드가 trusted IP 한정 — 실 접속원 IP와 CIDR 대조 (CGNAT면 HTTPS로 확인한 IP와 SSH 발신 IP가 다를 수 있음).
4. **1-foundation — OIDC·IAM**: OIDC provider(`token.actions.githubusercontent.com`) 존재. 기대 sub prefix를 먼저 GitHub에서 확보 — `gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix`. 2026-07-15 이후 생성된 리포는 `repo:<owner>@<owner-id>/<repo>@<repo-id>` 불변-ID 형식이 강제(opt-out 불가)라 이름 기반 `repo:<owner>/<repo>` 리터럴과 절대 일치하지 않는다 — 기대값을 하드코딩하지 말고 반드시 이 API 값과 대조한다. `aws iam get-role`로 trust policy 실물 확인 — `<project>-plan`은 sub `<prefix>:pull_request`, `<project>-apply`는 sub에 `<prefix>:ref:refs/heads/main`·`<prefix>:ref:refs/heads/dev` 둘 다, 전부 `StringEquals`(와일드카드 발견 시 이상), `<project>-hermes-readonly`는 trust가 hermes 호스트 롤. prefix 불일치가 guard(plan)의 `Not authorized to perform sts:AssumeRoleWithWebIdentity` 반복 실패의 근본 원인 — 실발급 sub는 CloudTrail `AssumeRoleWithWebIdentity` AccessDenied 이벤트의 `userIdentity.userName`에 원문 그대로 남으니 그걸로 한 글자 단위 대조. 음성 확인도 하나: 로컬 프로파일로 `aws sts assume-role --role-arn <apply 롤 ARN>` 시도 → `AccessDenied`가 정상 (성공하면 trust 과다 개방 — CI 밖 apply 경로가 생긴 것).
5. **1-foundation — 상주 리소스·seed**: 베이스라인 EC2 3대(`*-hermes`, `*-monitoring-server`, `*-gha-runner`) 존재 — `stopped`는 세션 절감 stop일 수 있으니 이상이 아니라 "stop 상태(재개 시 `scripts/refresh-ip.sh`로 IP 갱신 필요)"로 기록. monitoring-server private IP `10.42.0.10` 고정 + EIP 부착, Grafana `:3000` 응답. Seed 리소스 6종 실존 — 없으면 1-foundation apply 누락. Seed는 `2-0-setup/1-foundation/monitoring.tf`가 만드는 unused-resource 탐지 시나리오용 의도적 시드라 orphan·미사용으로 보고 금지: `*-seed-vol-a`, `*-seed-vol-keep`, `*-seed-snapshot`, `*-seed-eip`(미부착이 정상), `*-seed-orphan`(SG), `*-seed-role`(IAM). snapshot은 Description이 아니라 `Tags[?Key=='Name']`로 조회 — Description은 비어 있는 게 정상.
6. **러너**: `gh api repos/<owner>/<repo>/actions/runners`로 label `ansible` 러너 online + 러너 버전 확인. 최근 ansible-ops 런이 job setup 단계에서 죽으면 러너 버전 노후를 의심 (실측: 2.320.0은 `actions/checkout@v5`의 node24 미지원으로 setup에서 실패).
7. **2-github — secrets/vars**: `gh secret list` / `gh variable list`. 필수 secrets: `AWS_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `DB_PASSWORD`, `SLACK_WEBHOOK_URL`, `EXPIRY_APP_ID`, `EXPIRY_APP_PRIVATE_KEY`. 필수 vars: `AWS_REGION`, `PROJECT_NAME`, `INFRA_SLACK_MENTION`. 누락은 효과까지 구체적으로 보고:
   - `DB_PASSWORD` 누락 → 모든 경로(tf-plan/tf-apply/tf-destroy의 `TF_VAR_db_password`, ansible-ops의 `DB_ADMIN_PASSWORD`)가 워크플로 fallback 리터럴 `AppDemoPw2026!`(variables.tf 기본값과 동일한 리포 공개 값이므로 보고에 실값을 명시)로 동작한다. 누락은 이상이 아니라 "기본 데모 비밀번호 사용 중"으로 보고.
   - `EXPIRY_*` 누락 → access-expiry schedule 런 전부 실패.
8. **2-github — 거버넌스**: ruleset 등록과 실적용을 구분 — `gh api repos/<owner>/<repo>/rulesets`로 `main-guardrails`·`dev-guardrails`(required check `guard`) 등록 확인, `gh api repos/<owner>/<repo>/rules/branches/dev`(main도)로 실적용 확인. private repo free plan은 등록돼도 미적용이며 auto-merge.yml의 check-run 폴링이 대체 게이트 — "등록됨/미적용(플랜)"으로 구분해 보고. `.github/CODEOWNERS`가 브랜치별 의도대로 다른지(dev 브랜치는 `2-1-dev/`·`modules/`·`ansible/` unown) + 오너 핸들이 리포 소유자 본인인지 — 템플릿 원본 핸들이 남아 있으면 승인 게이트가 존재하지 않는 리뷰어에 걸려 prod PR 승인 불가(setup의 sed 치환 누락). destroy 게이트: `gh api repos/<owner>/<repo>/environments`에 `destroy-approval` environment + required reviewer 존재 — 없으면 tf-destroy가 승인 없이 돈다.
9. **Cloudflare 배선**: `2-1-dev/env.auto.tfvars`·`2-2-prod/env.auto.tfvars`의 `cloudflare_zone_id`가 둘 다 기입 + 동일 값. 미기입이면 이상이 아니라 "시나리오 5·6은 PR 생성까지만 동작" 상태로 보고.
10. **3-grafana**: 대시보드 provisioning apply 완료 + output의 Grafana URL·서비스 토큰이 hermes `.env`의 `OPS_GRAFANA_URL`·`OPS_GRAFANA_TOKEN`과 일치(11번과 교차 확인).
11. **CI (세팅 관련만)**: access-expiry 최근 schedule 런 (`gh run list -w access-expiry -L 3`) — 리포 생성 직후라 실행 이력이 없으면 실패로 단정하지 않는다. tf-plan/tf-apply 결과는 서비스 스택 영역이라 판정하지 않는다. 참고(판정 항목 아님): 브랜치 신설 push(`before`=000…0)는 tf-apply 변경 감지가 `detected: []`로 떨어져 apply job이 skip된다 — 사용자가 "세팅했는데 스택이 없다"고 하면 이 함정을 안내하고 `workflow_dispatch`(target=해당 스택) 수동 실행을 알려준다.
12. **Hermes 에이전트 내부 세팅** — 매 실행 항상 수행하고 생략하지 않는다 (전 항목 read-only). 정본은 `2-0-setup/4-hermes/README.md` + `docs/setup-command-guide.md` 6장. SSH로 hermes 호스트에 들어가 확인한다 — `ssh -i ~/.ssh/ops-agent-iac ubuntu@<hermes public IP>` (IP는 `terraform -chdir=2-0-setup/1-foundation output -raw hermes_host_public_ip` 또는 EC2 인벤토리의 `*-hermes`). SG가 열려 있는데 SSH가 timeout이면 접속원 공인 IP가 `trusted_ip`와 다를 수 있다(CGNAT 환경은 HTTPS로 확인한 IP와 SSH 실 발신 IP가 다름) — SG 인바운드의 CIDR과 실 IP를 대조해 보고. `hermes gateway restart` 금지 (재시작은 보류 중이던 요청을 재개시켜 중복 PR 등 부작용을 낳는다).
    - 게이트웨이: `systemctl --user status hermes-gateway.service` active + `hermes gateway status`로 Slack 연결 확인.
    - 모델: `hermes auth status openai-codex`가 logged in (`logged out`이면 에이전트가 아예 못 돎 — 알려진 1순위 장애 모드) + `~/.hermes/config.yaml`의 `model` 블록(provider·default가 setup 6-1에서 정한 값)과 `approvals.mode: off` 확인.
    - `~/.hermes/.env`: 존재 + 권한 600 (`stat -c %a`). 키 존재·형식만 확인하고 시크릿 값은 출력·보고에 싣지 않는다.
      - Slack: `SLACK_APP_TOKEN`(xapp- 접두), `SLACK_BOT_TOKEN`(xoxb- 접두), `SLACK_HOME_CHANNEL`, `SLACK_FREE_RESPONSE_CHANNELS`(#ops-agent 채널 ID — 미설정 시 채널 자유응답 안 됨), `SLACK_ALLOW_BOTS=all`(미설정 시 봇/웹훅 메시지 무시 — 알람 스레드 대응 불가).
      - read: `OPS_PROJECT_PREFIX`(= gh variable `PROJECT_NAME`과 일치), `OPS_AWS_READ_ROLE`(`<project>-hermes-readonly` 롤 ARN — `aws iam get-role`로 실존 확인), `OPS_GRAFANA_URL`·`OPS_GRAFANA_TOKEN`(3-grafana output과 대조), `OPS_CLOUDFLARE_READ_TOKEN`+`OPS_CLOUDFLARE_ZONE_ID`(둘 다 있거나 둘 다 없어야 함), `OPS_PAGERDUTY_TOKEN`(full-access — read-only 키는 write 403)·`OPS_PAGERDUTY_FROM_EMAIL`(없으면 PD write 도구 미노출)·`OPS_PAGERDUTY_ROUTING_KEY`(실페이지 게이트).
      - write: `OPS_GITHUB_APP_ID`·`OPS_GITHUB_INSTALLATION_ID`·`OPS_GITHUB_PRIVATE_KEY_PATH`·`OPS_GITHUB_REPO` 4개 전부 (하나라도 빠지면 PR 도구 미노출) + PRIVATE_KEY_PATH가 가리키는 pem 파일 실존.
      - stale 키: `OPS_IAC_REPO_PATH`·`OPS_ANSIBLE_SSH_KEY`가 남아 있으면 무시되는 키로 표시하고 제거 권고 (ansible은 GHA dispatch 경로로 이전됨).
    - 호스트 `gh auth status` 인증 상태 — 플러그인 리포를 private으로 만든 경우 미인증이면 설치·pull 재동기화가 전부 막힌다(권장 기본은 public).
    - 플러그인: `~/.hermes/plugins/ops` 존재, `hermes plugins list | grep ops` enabled, `hermes tools list`에서 `ops-read`·`ops-github-write`·`ops-ansible-write` enabled. `ops-monitoring-write`는 알람 대응 모드 토글이라 on/off 모두 정상 — 현재 상태만 기록. `git -C ~/.hermes/plugins/ops status --porcelain`으로 로컬 수정(self-patch drift) 여부 확인 — 수정이 있으면 리포와 diff를 보고.
    - `~/.hermes/SOUL.md`: 존재 + 첫 줄이 한국어 규칙(`# 최우선 규칙: 응답 언어는 한국어`) — 언어 지시가 파일 끝에 있으면 영어로 새는 알려진 문제. 정본은 ops-agent-plugin README heredoc — diff로 대조.
    - runbook 스킬: 정본 로드 경로는 플러그인 qualified name(`ops:ops-operating` 등, SOUL.md 라우팅 규칙) — 플러그인 checkout `skills/`에 4종(ops-change·ops-operating·ops-incident-response·ops-incident-rca)이 있으면 라우팅은 동작한다. `~/.hermes/skills/devops/` 런타임 복사본은 fallback일 뿐이라 **없어도 이상이 아니다** — 있을 때만 `diff -rq ~/.hermes/plugins/ops/skills ~/.hermes/skills/devops`로 self-patch 드리프트를 확인해 보고한다 (런타임 쪽에만 있는 수정은 재구축 시 유실).
    - 정기 cron 3종 (미사용 리소스·비용·Cloudflare 5xx): `~/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main cron list`로 등록 확인, 정본은 `~/.hermes/plugins/ops/data/cron-jobs.yaml` (스케줄은 UTC — 호스트 `date`로 TZ 확인). 호스트 재구축 시 유실되는 항목이라 세팅 검증에서 반드시 본다.
    - read 경계 smoke: 호스트에서 `aws sts assume-role --role-arn <OPS_AWS_READ_ROLE> --role-session-name verify` 성공 확인.
    - 플러그인 테스트: `python3 -m pytest ~/.hermes/plugins/ops/tests -q` 통과.

## 실패 시 세팅 가이드 (체크 번호 → 정본 세팅 단계)
이상 항목을 보고할 때 아래 매핑으로 세팅 방법까지 함께 제시한다. 정본은 `docs/setup-command-guide.md`(장 번호)와 각 단계 README — 핵심 명령을 보고에 옮기되, 이 스킬 자신은 실행하지 않는다(read-only 유지, 세팅 실행은 사용자 결정). 전 항목이 부재하면(teardown 직후 등) 항목별 조치 대신 setup-command-guide 0→8장 순서의 전체 재부트스트랩을 안내한다 — 순서 의존이 있다: 0-bootstrap 없이는 foundation의 backend 등록이, foundation 없이는 3-grafana·hermes가 진행 불가 (4장 PagerDuty만 Day 3 전 적용으로 미룰 수 있음).

1. **준비물** → 가이드 0장: `gh repo create <본인>/ops-agent-iac --template <템플릿 owner>/ops-agent-iac --public --clone` (plugin도 동일 — fork 아님, template 독립 리포. app 리포는 생성 불필요).
2. **state 버킷** → 가이드 1장: `bash 2-0-setup/0-bootstrap.sh` (`AWS_PROFILE`·`AWS_REGION` export 상태에서 — 멱등, 버킷 있으면 건너뜀. 버저닝·암호화·퍼블릭 차단도 이 스크립트가 설정).
3·4·5. **1-foundation** → 가이드 2장: `terraform -chdir=2-0-setup/1-foundation init` 후 `bash 2-0-setup/foundation.sh apply`. 템플릿으로 만든 리포면 `-var github_owner=<본인 핸들>` 필수 — owner가 다르면 모든 CI 롤 assume이 AccessDenied. `trusted_ip`는 자동 감지(접속원이 다르면 `-var 'trusted_ip=<ip>/32'`), SSH 키 기본 `~/.ssh/ops-agent-iac.pub`. trust 와일드카드·과다 개방 발견도 재apply로 정정. EC2 3대 stopped는 세팅 문제가 아님 — start 후 `scripts/refresh-ip.sh`.
6. **러너** → foundation 재apply(위 2장 동일 명령)가 러너 인스턴스를 교체·재등록한다 — 러너 토큰은 helper가 매 apply 자동 발급, 새 호스트엔 latest stable runner 설치라 버전 노후도 함께 해소.
7. **secrets/vars** → `AWS_ACCOUNT_ID`·`AWS_REGION`·`PROJECT_NAME`·`DB_PASSWORD`(데모 기본값 1차 등록 — 기존 값은 덮지 않음)는 0-bootstrap.sh 재실행이 등록(gh 인증 전제, 멱등). 서비스 secrets/vars는 가이드 3장: `gh secret set DB_PASSWORD`(교체 시) · `SLACK_WEBHOOK_URL` · `CLOUDFLARE_API_TOKEN`(8장) · `EXPIRY_APP_ID`/`EXPIRY_APP_PRIVATE_KEY`(4-hermes README 1장의 GitHub App 발급 산출물), `gh variable set INFRA_SLACK_MENTION`.
8. **거버넌스** → 가이드 3장: CODEOWNERS 오너를 본인 핸들로 sed 치환·커밋 후 `bash 2-0-setup/2-github/branch_ruleset.sh` + `bash 2-0-setup/2-github/destroy_approval.sh` (둘 다 멱등 — ruleset 2개·dev 브랜치·destroy-approval environment 생성). "등록됨/미적용(플랜)"은 세팅 문제가 아니라 플랜 한계 — auto-merge.yml 폴링이 대체 게이트이며, 리포를 public으로 전환하면 Free 플랜에서도 실적용된다.
9. **Cloudflare** → 가이드 8장: zone id를 `GET /client/v4/zones`로 조회해 `2-1-dev`·`2-2-prod`의 `env.auto.tfvars`에 동일 값 기입(사람 소유 파일 — 커밋·push), write 토큰은 `gh secret set CLOUDFLARE_API_TOKEN`.
10. **3-grafana** → 가이드 5장: foundation apply로 Grafana가 기동한 뒤 `terraform -chdir=2-0-setup/3-grafana init` + `apply`, output `ops_grafana_url`·`ops_grafana_token`을 hermes `.env`에 배선(12번 .env 항목과 교차).
11. **access-expiry** → 워크플로가 disabled면 `gh workflow enable access-expiry` — 단 세션 절감용 수동 disable일 수 있으니 의도 확인 후 안내. schedule 런 실패는 7번 `EXPIRY_*` secrets부터.
12. **Hermes** → 가이드 6·7장 + `2-0-setup/4-hermes/README.md` 전체 절차. 하위 항목별:
    - 게이트웨이·모델 로그인·config → 가이드 6장 (설치 + Slack 앱 + `hermes auth login` + `config.yaml`).
    - SOUL.md 부재·언어 규칙 위치 이상 → ops-agent-plugin README "응답 언어: 한국어 (SOUL.md)" heredoc으로 재배선 (언어 지시는 파일 최상단).
    - `.env` 키 누락 → 4-hermes README 4장 — read 키는 3-grafana output·Cloudflare read 토큰·PagerDuty(3-1-pagerduty README), write 키 4종은 4-hermes README 1장의 GitHub App 발급.
    - 플러그인 부재·미설치 → 가이드 7장: 호스트에서 `gh auth login` 후 플러그인 clone + install. self-patch drift는 리포 흡수가 정본 경로 — 임의 discard 금지, diff를 보고하고 사용자 판단에 맡긴다.
    - 정기 cron 3종 유실 → plugin README "정기 cron (정기 점검) — 재구축 시 재등록" 절: `data/cron-jobs.yaml` 정의대로 `cron create` 재등록.

## 출력
한국어, 첫 줄에 세팅 기준 판정 ("세팅 정상 — 12개 항목 통과" 또는 "세팅 이상 N건"). 이어서 체크별 pass/fail 표, 그다음 이상 항목만 — 각 항목에 ① 상태를 바꾸지 않는(읽기 전용) 다음 조치 ② 세팅 방법(위 '실패 시 세팅 가이드'의 해당 항목 — 정본 장 번호 + 핵심 명령) 순으로 제시. dev/prod 스택 상태(app EC2·ALB·RDS)는 판정·표에 넣지 않는다 — 눈에 띈 사실이 있으면 말미에 "참고"로만 한 줄.
