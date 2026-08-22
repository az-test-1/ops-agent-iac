# ops-agent-iac — AI 에이전트 인프라 운영 실습

제작: **Woojin Kim** ([GitHub](https://github.com/wo-o) ·
[LinkedIn](https://www.linkedin.com/in/wo-o/) ·
[YouTube @ai에이터](https://www.youtube.com/@ai%EC%97%90%EC%9D%B4%ED%84%B0)) —
[MIT License](LICENSE). 배포·수정 자유, 저작자 표기는 유지해야 한다.

AI 에이전트(Hermes)가 인프라를 안전하게 운영하도록 **경계를 설계**하는 법을
실습하는 Template 리포. 수강생은 **본인 GitHub repo(template으로 생성) + 본인
AWS 계정**에서 초저가 리소스(t3.micro/small)로 전 과정을 돌린다.
이 문서는 전체 구조와 세팅 순서만 담는다 — 각 실습의 상세 절차는 해당
디렉토리의 `README.md`에 있다.

## 핵심 원칙

1. **에이전트의 유일한 write는 PR** — 시나리오별 허용된 surface tfvars 키
   (dev-*/prod-*)뿐, `*.tf`·워크플로·스크립트는 사람 전용(CODEOWNERS).
2. **apply·destroy는 CI에서만** (GitHub OIDC 단기 토큰) — 로컬 apply는 사람
   전용 부트스트랩 루트(2-0-setup)뿐. 이 게이트는 리포 안의 약속이 아니라
   IAM trust(OIDC sub) 레벨에서 강제된다.
3. **값 경계는 terraform validation이 강제** — 각 환경/모듈 variables.tf의
   `validation {}`(캡·enum·CIDR 폭)이 plan 시점에 검사한다. 잘못된 값이면
   plan이 실패하고, plan을 기다리는 `guard` 게이트 job이 merge를 막는다.
4. **모든 EC2 접속은 SSH** — 2-0-setup의 `<project>` 키 +
   공유 접근 SG `<project>`(trusted IP에서만 전체 허용, IP는 apply 시 자동 감지).
   SSM은 쓰지 않으며, ansible은 self-hosted gha-runner(또는 본인 Mac)에서 SSH로 실행한다.
5. **state는 환경별 분리** — 버킷 `<project>-state-<account>`,
   key `states/<환경>.tfstate`. dev에서 문제가 생겨도 prod state에는
   영향이 없다.
5-1. **브랜치=환경** — `dev` 브랜치 머지가 `2-1-dev`를, `main` 머지가 `2-2-prod`를
   apply한다. dev 변경 PR은 `dev`로, prod 변경 PR은 `main`으로 연다. `modules/`
   변경도 그 브랜치의 환경만 apply되므로, dev에서 검증한 뒤 `dev`→`main` 승격
   PR로 prod에 반영한다. 이 매핑은 워크플로 + IAM trust(OIDC sub: main·dev) +
   브랜치별 ruleset(main-guardrails·dev-guardrails)이 함께 강제한다.
6. **자동 조치 vs 사람 승인 = CODEOWNERS 소유 여부** — 에이전트가 연 tfvars PR을
   자동 머지할지는 그 surface가 CODEOWNERS에 소유됐는지가 정한다(무소유=auto,
   소유=code-owner 리뷰 대기). plan(값 검증)은 auto라도 반드시 통과해야 한다.
   상세는 아래 "에이전트 조치 & 승인" 참고.

## 에이전트 조치 & 승인 (ruleset + CODEOWNERS)

에이전트가 무엇을 자동 반영하고 무엇을 사람 승인에 걸지는 코드 분기가 아니라
GitHub 레벨에서 강제된다. 두 조각이 맞물린다:

- **ruleset (repo setup에서 1회)** — `2-0-setup/2-github/branch_ruleset.sh`가 main과
  dev 브랜치에 같은 GitHub Repository Ruleset를 건다(멱등, dev 브랜치가 없으면 생성).
  강제 규칙:
    - PR 필수(main·dev 직접 push 금지), 브랜치 삭제·force-push 금지
    - `required_status_checks` = `guard`(tf-plan) 통과 필수 + 브랜치 최신
    - `require_code_owner_review=true`
    - admin은 bypass(세팅·비상)
  이게 있어야 CODEOWNERS가 텍스트가 아니라 실제 게이트로 작동한다.
  GitHub Environment(`2-0-setup/2-github/destroy_approval.sh`)도 여기서 1회 세팅한다.
- **CODEOWNERS (경로 → 소유자)** — PR이 건드린 경로가 소유돼 있으면 그 code owner
  리뷰가 자동으로 필수. 매번 "이건 prod니까 승인" 같은 분기 없이 경로가 곧 정책이다:
    - **auto (무소유)** — `2-1-dev/*.auto.tfvars`(env.auto.tfvars 제외 — dev surface:
      service·ec2-ssh·db-access·disk·dns) + `2-2-prod/waf.auto.tfvars.json`(존 전역
      WAF, prod 전용 — incident 차단은 auto) + `2-2-prod/access-expiry.auto.tfvars.json`
      (만료된 prod access grant 회수 전용) → 승인 0 → auto-merge 워크플로가
      `guard`를 확인한 뒤 사람 개입 없이 머지·apply.
    - **human (소유)** — `*.tf`(모든 인프라 정의) · `/2-2-prod/`의 일반 prod
      surface(`ec2-ssh.auto.tfvars.json`, `db-access.auto.tfvars.json` 포함) ·
      `/2-1-dev/env.auto.tfvars`(구조값) → code owner(@wo-o) 리뷰 대기.
      prod access 추가·연장은 사람이 승인하고, 이미 지난 `expires_at` 회수만
      machine-owned revocation 파일로 자동 처리한다.
- **판단** — `ops-change`(사용자 요청 기반) / `ops-incident-response`(알람 기반 자율
  대응) 스킬이 metric·log를 보고 조치를 정해 surface tfvars PR을 열거나 ansible
  플레이북을 실행한다.
- **삭제 승인** — 리소스 삭제(`tf-destroy`)는 Slack 인프라팀 멘션(`@진`, 기본값 —
  수강생이 서치·수정) + GitHub Environment(`destroy-approval`) 승인 게이트를 거친다.
  `service_enabled=false` surface PR 경로도 머지 후 apply가 같은 environment 승인을
  대기한다(tf-apply의 approve-destroy 잡, dev·prod 공통 — 2026-07-31 추가). 승인을
  거부하면 apply만 막힌다 — false가 이미 머지돼 있으므로 삭제 의사가 없으면 revert할
  것(Slack 알림이 안내).
- **surface 파일은 전용 PR로만** — `*.auto.tfvars*`(에이전트 surface 파일)는 사람의
  feature PR에 끼워 넣지 않는다(핫픽스도 별도 PR로). 같은 변경이 다른 PR로 먼저
  머지되면 뒤따르는 봇 PR이 빈 diff가 되어 auto-merge/tf-apply의 paths 필터에
  걸리지 않고, "머지됐는데 apply가 없는" 혼란을 만든다(2026-07-16 #84/#85 사례).
  플러그인의 no-op 감지가 봇 쪽은 막아주지만, 사람 쪽 규칙은 이것이다.

## 디렉토리 구조

- **`2-0-setup`** [로컬 apply] — 1회성 부트스트랩. 공유 SSH 키·SG, VPC, OIDC 롤,
  read 경계 롤, 공유 모니터링 EC2 1대, hermes 호스트 1대, self-hosted ansible 러너.
- **`2-1-dev` / `2-2-prod`** [CI apply] — A서비스(EC2 앱 + RDS + Bastion + ALB).
  두 환경의 `.tf`는 바이트 단위로 동일하고, 유일한 차이는 `env.auto.tfvars` 한 파일.
- **`2-3-incident-response`** [로컬 apply] — 알람 발화(Grafana) → 에이전트 진단 →
  자동 조치. Grafana 알람 룰·contact point·notification 정책을 이 디렉터리가 provisioning
  하고, 조치는 기존 app + 모니터링 + ansible + surface를 재사용한다.

```
ops-agent-iac/
├── .github/workflows/   # tf-plan(PR) · tf-apply(dev push=2-1-dev, main push=2-2-prod) · tf-destroy · auto-merge(guard 확인 후 봇 PR 머지) · ansible-ops(러너) · access-expiry
├── scripts/             # ansible-inventory.sh · expire_access.py · refresh-ip.sh 등
├── ansible/             # ansible IaC (플레이북 + aws_ec2 동적 인벤토리 + ansible.cfg) — gha-runner 기준
├── modules/             # service(EC2 앱 + RDS + Bastion + ALB) — dev/prod 공용 모듈
├── 2-0-setup/           # [로컬 apply] 0-bootstrap.sh · 1-foundation(.tf 디렉터리: VPC·OIDC 롤·read 경계·SSH 키/SG·
│                        #   모니터링·hermes 호스트·러너) · 2-github(ruleset·environments·App 헬퍼) ·
│                        #   3-hermes · 4-grafana(대시보드·토큰) · teardown.sh
├── 2-1-dev/             # [CI apply] A서비스 dev (EC2 앱 + RDS + Bastion + ALB)
├── 2-2-prod/            # [CI apply] A서비스 prod (2-1-dev와 .tf 동일, env.auto.tfvars만 다름)
├── 2-3-incident-response/  # [로컬 apply] 알람 룰·notification 배선 + 알람 발화 → 에이전트 진단 → 자동 조치
└── 3-1-pagerduty/       # [로컬 apply] critical 페이징 — PD service·integration, routing_key를 2-3에 주입
```

## 세팅 — 부트스트랩 + 환경

로컬 apply는 `2-0-setup` 하나뿐이다. state 버킷은 `2-0-setup/0-bootstrap.sh`가, 나머지
공유 인프라(VPC·SG·OIDC 롤·read 경계·모니터링·hermes 호스트 1대·ansible 러너)는
`2-0-setup`이 만든다. 이후 dev/prod는 전부 CI apply.

```bash
# (1) template으로 본인 repo 생성("Use this template" — fork 아님) 후 클론
git clone https://github.com/<본인-핸들>/ops-agent-iac.git && cd ops-agent-iac

# (2) 최소 도구 + 자격증명 + 전용 SSH 키
#     brew 코어 terraform은 1.5.7에서 동결(라이선스) — 반드시 hashicorp/tap으로 설치
brew tap hashicorp/tap && brew install hashicorp/tap/terraform awscli gh
terraform version                # v1.10 이상 확인 (1.5.7이면 brew uninstall terraform 후 재설치)
# 자격증명이 처음이면: 콘솔 → IAM → Users → 본인 유저 → Security credentials → Create access key(CLI)
aws configure                    # 키 2개 + region(ap-northeast-2) + json 입력
                                 # 프로파일로 만들었다면: export AWS_PROFILE=fastcampus
aws sts get-caller-identity      # ← 성공해야 이후 모든 apply가 성공
gh auth login                    # repo 변수 등록·이후 PR/워크플로 조작에 필요
ssh-keygen -t ed25519 -f ~/.ssh/ops-agent-iac

# (3) bootstrap — 도구 검증 + state 버킷 + GitHub repo 변수 자동 등록
AWS_PROFILE=fastcampus AWS_REGION=ap-northeast-2 bash 2-0-setup/0-bootstrap.sh

# (4) CODEOWNERS의 오너 플레이스홀더(@wo-o) → 본인 핸들로 치환 후 commit/push
#     (치환하지 않으면 @wo-o는 본인 repo의 collaborator가 아니라서 GitHub이
#      CODEOWNERS를 통째로 무시한다 — 사람 승인 게이트가 조용히 꺼진다)
sed -i '' 's/@wo-o/@my-github-handle/g' .github/CODEOWNERS

# (5) repo 설정 확인 (bootstrap이 등록: AWS_ACCOUNT_ID=secret, AWS_REGION·PROJECT_NAME=variable)
gh secret list && gh variable list

# (6) 2-0-setup apply — VPC, OIDC 롤, read 경계, SSH 키/SG, 공유 모니터링,
#     hermes 호스트 1대(<project>-hermes), self-hosted ansible 러너
#     (.tf 디렉터리는 2-0-setup 바로 아래가 아니라 2-0-setup/1-foundation)
terraform -chdir=2-0-setup/1-foundation init
bash 2-0-setup/foundation.sh apply
# helper가 현재 리포의 실제 OIDC prefix를 아래 API로 읽어 exact-match trust에 쓰고,
# apply마다 새 runner registration token도 발급한다:
# gh api repos/$OWNER/$REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
# SSH 키(~/.ssh/ops-agent-iac.pub)와 허용 IP(공인 IP)는 자동으로 읽는다
# Grafana: terraform output grafana_url (본인 IP에서만, admin/admin → 즉시 변경)
#   로그: 플릿 nginx/app + 모니터링 스택 자체 로그가 Loki로 수집된다
cd ../..

# (7) 리포 거버넌스 1회 세팅 — repo auto-merge 허용 + ruleset(PR 필수 + guard + code-owner)
#     + environments
bash 2-0-setup/2-github/branch_ruleset.sh
bash 2-0-setup/2-github/destroy_approval.sh

# "이게 되네" — Mac에서 read 경계 롤 ARN 확인:
terraform -chdir=2-0-setup/1-foundation output -raw hermes_readonly_role_arn   # → arn:aws:iam::…:role/…-hermes-readonly
# 그 ARN을 들고 hermes 호스트의 SSH 세션 안에서:
aws sts assume-role --role-arn "<위 ARN>" --role-session-name smoke
# → Credentials 발급 = 연동 성립. read만 되고 write는 AccessDenied — 그게 요점

# (8) 3-hermes — ops 플러그인(read + write)을 hermes 호스트에 설치
#     전체 GitHub App·Slack·.env 절차: 2-0-setup/3-hermes/README.md
ssh -i ~/.ssh/ops-agent-iac ubuntu@<hermes 호스트 public IP>   # 1-foundation output hermes_host_public_ip
# 호스트에서 — 플러그인 설치
hermes plugins install wo-o/ops-agent-plugin
hermes gateway restart
# OPS_AWS_READ_ROLE = terraform output hermes_readonly_role_arn
exit  # 이후 명령은 다시 Mac에서 실행

# (9) PART 5 대시보드 provisioning — Hermes 기본 배선 뒤 실행
#     "Service Overview" 대시보드 + 플러그인 read 토큰이 여기서 provisioning된다
#     (인스턴스 단위 알람 룰·notification은 2-3-incident-response 실습에서 세팅)
cd 2-0-setup/4-grafana && terraform init && terraform apply
cd ../..
```

> **슬랙에 "Command Approval Required" 버튼이 뜨면**: 에이전트가 `ops_*` 도구가
> 아니라 raw 셸(aws CLI 등)을 실행하려는 것이다 — 기본은 **Deny**. 조회는
> ops read 도구가 정답 경로고, Deny하면 에이전트가 도구로 되돌아간다.
> Always Allow는 그 패턴을 `command_allowlist`에 영구 저장하므로 신중히.
> 상세: ops-agent-plugin의 `PLUGIN.md` "명령 승인" 절.

## 실습 흐름

dev/prod는 `modules/service`를 호출하는 같은 인프라(EC2 앱 + RDS + Bastion + ALB)다.
에이전트가 surface tfvars PR을 열면 흐름:

```
surface 파일 수정 PR → plan(값 검증) + guard 게이트
→ dev surface(무소유)=auto-merge → CI apply → 검증
   prod(소유)=code-owner 리뷰 대기 후 머지 → CI apply
```

- ansible 드릴은 CI가 아니라 **gha-runner(권장) 또는 본인 Mac에서 SSH로** 실행한다.
  동적 인벤토리(`inventory/aws_ec2.yml`)는 호스트를 **private IP**로 잡으므로 VPC 안의
  gha-runner 전용이다(`.github/workflows/ansible-ops.yml`이 이 경로 — Actions 탭에서
  workflow_dispatch로도 실행). VPC 밖(Mac)에서는 public IP 기반 fallback 인벤토리를
  생성해 쓴다:

```bash
# gha-runner (권장) — ansible-ops.yml workflow_dispatch, 또는 러너 SSH 세션에서:
cd ansible && ansible-playbook <playbook>.yml --limit env_dev [-e var=값]
# 인벤토리·키는 ansible/ansible.cfg가 잡는다 (inventory/aws_ec2.yml — private IP,
# Role/Environment 태그 기반 aws_ec2 동적 인벤토리, 파일 생성 단계 없음)
# --limit env_dev|env_prod 로 환경을 고른다. 롤링(TG 드레인→재시작→healthz→복귀)은
# rolling-restart 플레이북의 serial: 1이 보장한다

# 본인 Mac — public IP fallback 인벤토리를 만들어 실행 (2번째 인자 = env 스코프):
bash scripts/ansible-inventory.sh <project> dev > /tmp/inv.ini
ansible-playbook -i /tmp/inv.ini ansible/<playbook>.yml --limit env_dev
```

## 에이전트 write surface

각 시나리오는 `dev-*`/`prod-*` 키로 나뉜다(2-1-dev / 2-2-prod의 surface tfvars).
승인 경계는 CODEOWNERS 소유 여부 — dev surface(env.auto.tfvars 제외)는 무소유=auto,
prod source surface는 소유=code-owner 리뷰. 단, prod access 만료 회수는
`access-expiry.auto.tfvars.json` revocation 파일만 자동이다:

| surface | 조치 | 경계 |
|---|---|---|
| ec2-ssh | EC2 SSH 접근 | dev=auto · prod=code-owner(추가/연장) · 만료 회수=auto |
| db-access | RDS를 bastion SSH grant로 접근 (**prod는 expires_at 필수**, dev는 선택) | dev=auto · prod=code-owner(추가/연장) · 만료 회수=auto |
| disk | 볼륨 라이브 확대 + ansible growpart (**grow-only**) | dev=auto · prod=code-owner |
| dns | Cloudflare → ALB 레코드 | dev=auto · prod=code-owner |
| waf | 특정 IP 차단/챌린지 (block/challenge 커스텀 룰, 존 전역 — **prod 전용 surface**) | auto (incident 대응 — prod surface 중 유일한 예외) |
| service | A서비스 스택 세팅/삭제 (`service_enabled` — false=전체 destroy, 복구 불가) | dev=auto (삭제 포함) · prod=code-owner |

## ansible 등록부 (리포 루트 `ansible/`)

gha-runner에서 SSH 실행(`ansible-ops.yml`), `--limit env_dev|env_prod`로 환경 선택.
인벤토리는 Role/Environment 태그 기반 `aws_ec2` 동적 인벤토리(private IP — 러너 전용,
Mac은 `scripts/ansible-inventory.sh` fallback).

실행 allowlist는 `ansible/playbooks.yml` 등록부 하나다(환경 정본 브랜치 기준:
dev 실행=dev 등록분, prod 실행=main 등록분 — dev→main 승격 PR 승인이 곧 prod
실행 허용). 파라미터를 받는 플레이북은 `ansible/specs/<name>.yml` 스펙이 입력
계약을 선언하고, `ansible-ops.yml`의 generic 검증 엔진이 스펙 통과 값만
`-e @extra-vars.json`으로 전달한다. `specs/`는 dev 브랜치에서도 사람 소유
(CODEOWNERS)라 파라미터 조치 신규는 dev 진입부터 사람이 승인한다.

| 플레이북 | 하는 일 |
|---|---|
| rolling-restart | TG 드레인 → 재시작 → healthz → 복귀 |
| disk-grow | terraform 볼륨 확대 후 growpart+resize2fs로 파일시스템 확장 |
| security-patch | serial 롤링 패키지 패치 (+패키지 surface) |
| rds-temp-user | 만료(VALID UNTIL) 임시 postgres 유저 생성/삭제 |
| rds-readonly-user | dev 상시 readonly 계정 생성 (dev 전용) |
| monitoring-agents | node_exporter+promtail 설치 (2-3 실습 사전 준비) |
| instance-resize | 인스턴스 타입 롤링 변경 — 완료 후 같은 값 tfvars PR로 수렴 |

초기 서비스 세팅에 ansible은 쓰지 않는다 — 앱 기동·/data 마운트는 EC2 user_data가
부팅에서 완결한다(`modules/service/app.tf`). 위 플레이북은 운영 중 조치·실습용이다.

## IAM 롤 (2-0-setup 생성)

| 롤 | trust | 권한 |
|---|---|---|
| `<project>-plan` | PR sub | ReadOnlyAccess |
| `<project>-apply` | main push sub | PowerUser + `<project>-*` 한정 IAM |
| `<project>-hermes-readonly` | hermes 호스트 롤(이름 규약) + 본인 principal(선택) | ReadOnlyAccess + Cost Explorer read |

## 플러그인 & 스킬 (wo-o/ops-agent-plugin)

read 도구 + write 1경로(tfvars PR) + 등록부 기반 ansible 실행으로 구성.
스킬 3종:

- **ops-operating** — read-only 조회 (metric·log·리소스 상태)
- **ops-change** — 사용자 요청 기반 surface 변경 PR
- **ops-incident-response** — 알람 기반 자율 대응

전 리소스에 `default_tags`로 Project/Environment/ManagedBy가, 인스턴스에는
추가로 Role/Name이 붙는다(동적 인벤토리·대시보드·비용 추적의 기준).

## 비용·정리

- 상시: hermes 호스트 1대 + 모니터링 t3.small + ansible 러너 + dev/prod 시드.
  세션 사이에는 인스턴스 **stop**으로 절감.
- dev/prod 환경은 apply 중에만 과금(t3.micro/small, RDS·ALB 등) — **세션 종료 시
  destroy 전제**. RDS 삭제보호·백업은 실습이라 끈다.
- 과정 종료 순서: dev/prod tf-destroy → 2-0-setup을 **마지막**에
  `bash 2-0-setup/foundation.sh destroy`로 로컬 destroy
  (롤이 사라지면 CI 전체가 죽는다) → `bash 2-0-setup/teardown.sh`로 state 버킷 삭제.

## 알아둘 것

- **계정·repo는 1인 1개.** OIDC sub는 GitHub API가 반환하는
  `repo:<owner>/<repo>:...` 또는 immutable-ID 형식으로 잠기고 리소스
  이름이 `<project>-*` 규칙으로 고정되므로, 공용 계정/repo는 충돌한다. 프로젝트 이름
  기본값은 리포 디렉토리 이름이며 `PROJECT_NAME=<이름> bash 2-0-setup/0-bootstrap.sh`로
  재정의할 수 있다. `foundation.sh`는 실제 리포 owner/name을 별도로 자동 전달한다.
- **backend 수동 설정 없음.** dev/prod 디렉터리의 빈 S3 backend는 CI가 주입한다.
  2-0-setup만 로컬 state(gitignore — 잃지 않게 백업).
- **공인 IP가 바뀌면 SSH·Grafana가 "unreachable"로 끊긴다** (SG가 apply 당시
  IP로 고정). 복구는 `bash scripts/refresh-ip.sh` 한 번 — SG를
  현재 IP로 in-place 갱신한다(인스턴스 교체 없음).
- **리포는 public 권장** — Free 플랜에서 prod 승인 게이트(required reviewer)와
  guard 강제(ruleset)가 public 리포에서만 집행되고, GitHub-hosted 표준 러너의
  Actions 분도 무료다(실습 리포에 시크릿 없음 — secrets는 `gh secret`으로 별도 등록).
  private으로 쓰면 ruleset은 생성만 되고 집행되지 않으며(branch_ruleset.sh가
  감지·경고) auto-merge.yml의 check-run 폴링이 대체 게이트로 동작한다.
  required reviewer 게이트가 필요하면 public 전환 후
  `2-0-setup/2-github/destroy_approval.sh`를 재실행한다.
- **알려진 한계**: main-push sub는 어느 워크플로가 발급받았는지 구분하지
  못한다(보완 통제: CODEOWNERS + ruleset). NAT gateway가 없어 private subnet의
  RDS·인스턴스는 outbound 인터넷이 안 된다(의도된 제약).
