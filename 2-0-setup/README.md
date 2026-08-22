# 2-0-setup — 1회 부트스트랩 (사람이 로컬 apply)

상태: 사람 전용 루트. CI 매트릭스에서 의도적으로 제외되며(tf-plan/tf-apply의 path
필터에 없음 — 필터는 2-1-dev/**·2-2-prod/**만), 에이전트 write-surface도 없다. 이
실습만은 로컬 자격증명으로 사람이 직접 apply한다 — CI가 쓸 state 버킷·OIDC·롤을
만드는 루트라서 CI 안에서 돌 수 없다.

## 목표

이후 모든 실습(2-1-dev / 2-2-prod / 2-3-incident-response)이 공통으로 사용하는 고정
기반을 한 번에 만든다.

1. Terraform state 버킷 `<project>-state-<account>` — 버저닝 활성.
   TF 1.10+ 네이티브 S3 lockfile(`use_lockfile=true`)을 쓰므로 DynamoDB 테이블 없음.
   단, 이 버킷은 이 TF 루트가 아니라 `2-0-setup/0-bootstrap.sh`가 AWS CLI로 부트스트랩한다
   — 이 실습은 로컬 state를 쓰기 때문이다(아래 '부트스트랩 절차' 0단계 참고)
2. 공유 접근 프리미티브 — SSH key pair `<project>`(변수
   `ssh_public_key`로 본인 공개키 등록)와 SG `<project>`
   (trusted IP에서만 전체 포트 허용 — IP는 apply 시점에 자동 감지). 모든 실습
   인스턴스(dev/prod의 app·bastion, 모니터링 서버, ansible 러너, hermes 호스트 1대)에
   부착되며, EC2 접속과 ansible 실행이 전부 이 키의 SSH로 이뤄진다
3. 네트워크 — VPC `10.42.0.0/16`, 퍼블릭 서브넷 2개(AZ 분산), IGW. **NAT 없음**
   (비용 ~$32/mo 회피 — 인스턴스는 퍼블릭 IP + default-deny SG + 수강생 IP 한정 SSH)
4. GitHub OIDC provider + GHA 롤 2개 — trust sub는 전부 `StringEquals`,
   와일드카드 금지가 이 실습의 교육 포인트:

   | 롤 | trust sub | 권한 |
   |---|---|---|
   | `<project>-plan` | `<API sub_claim_prefix>:pull_request` | ReadOnlyAccess |
   | `<project>-apply` | `<API sub_claim_prefix>:ref:refs/heads/main` + `:ref:refs/heads/dev` | PowerUserAccess + `<project>-*` 이름 접두사 한정 IAM 인라인 |

   prefix는 GitHub API 정본이라 이름 기반/immutable-ID 형식을 모두 보존한다.
   어떤 sub를 발급받을 수 있는지는 GitHub이 결정한다(PR vs branch-push). plan은
   PR에서만, apply는 환경 브랜치(dev=2-1-dev, main=2-2-prod) 머지 후에만 assume된다
   — 즉 CI 밖에는 apply 경로가 없다.
   prod 변경 승인과 리소스 삭제 게이트는 IAM 롤이 아니라 **리포 거버넌스**(CODEOWNERS
   + branch ruleset의 사람 승인, destroy-approval environment)로 성립한다(아래
   '리포 거버넌스' 참고).

5. hermes 호스트 1대(`<project>-hermes`, t3.small) — 실습 전체에서 ops 에이전트가
   도는 상주 인스턴스. dev/prod 구분은 에이전트가 아니라 surface 이름(dev-*/prod-*)에
   대한 GitHub 경로 거버넌스로 강제된다. 이 루트가 EC2·IAM 역할·인스턴스 프로파일을
   함께 만든다(hermes.tf).
6. `<project>-hermes-readonly` — ops Hermes 플러그인의 read 경계.
   ReadOnlyAccess + Cost Explorer read. trust는 위에서 이 루트가 만든 hermes 호스트
   롤(`<project>-hermes`, `aws:PrincipalArn` 조건)과 수강생 본인의 IAM principal(변수, 선택).
7. 공유 모니터링 스택 `<project>-monitoring-server`(t3.small) — docker compose로
   Grafana/Prometheus/Loki/promtail을 돌린다(`monitoring.tf`).
   주소는 교체를 견디도록 고정돼 있다 — private IP는 `10.42.0.10`
   (`cidrhost(subnet, 10)`, 실습 플릿이 굽는 loki_url의 타깃), public은 EIP
   (Grafana URL·hermes 배선의 타깃). 인스턴스를 재구축해도 두 주소 모두
   유지되므로 플릿 재apply나 .env 갱신이 필요 없다. 단, Grafana DB는 새로
   시작하므로 grafana 디렉터리(대시보드·에이전트 토큰)와 `2-3-incident-response`(알람)를
   재-apply해 다시 만든다.
   Prometheus는 `Name` 태그(`<project>-*-app`)로 앱 fleet을 ec2_sd로 발견해 `:9100`을 scrape하고,
   promtail은 스택 자체 컨테이너 로그를 `job=monitoring`으로 자기 Loki에 적재한다
   — 스택 장애도 Grafana에서 조사. datasource(uid `prometheus`/`loki`)는 서버 부팅
   시 함께 provisioning된다. **대시보드는 이 서버가 아니라 `2-0-setup/4-grafana`
   디렉터리가(아래 'ops 플러그인 read 자격증명' 참고), 알람 룰(7종)·contact point·
   notification 정책은 `2-3-incident-response`가 grafana provider로 관리한다**
   — 서버는 그대로 두고 관측 콘텐츠만 재-apply할 수 있다. Grafana(:3000)·
   Prometheus(:9090)·Loki HTTP API(:3100)는 수강생 IP에서만 접근 가능하다
   (Loki는 UI 없음 — 브라우저 조회는 Grafana Explore, :3100은 API 직접 호출용).
8. self-hosted ansible 러너 `<project>-gha-runner`(label: `ansible`) — VPC 안에
   상주하며 `.github/workflows/ansible-ops.yml`의 잡(runs-on: `[self-hosted, ansible]`)이
   여기서 돌면서 리포 루트 `ansible/`의 플레이북을 실행 중인 인스턴스에 SSH로
   적용한다(runner.tf, 아래 '러너 활성화' 참고)

이 루트가 만드는 EC2는 공유 모니터링 서버 1대 + hermes 호스트 1대 +
ansible 러너 1대다. dev/prod의 app·RDS·bastion·ALB는 각각 2-1-dev / 2-2-prod가
CI apply로 세운다(이 루트가 만든 VPC·서브넷·SG·키를 태그 lookup으로 참조).

## 커리큘럼 항목

- GitHub·Terraform·AWS 환경 설정 — GitHub Actions를 위한 Terraform(OIDC
  롤) 세팅 + 수강생 SSH 접근 프리미티브(키·SG) + hermes 호스트 1대 + 에이전트
  read 경계(hermes-readonly). apply 후 hermes 호스트에서 read 연동("이게
  되네")을 확인한다
- 가드레일 설계의 토대: OIDC sub 클레임별 롤 분리(plan=PR / apply=main-push),
  "승인 게이트를 CI가 아니라 리포 거버넌스에 바인딩한다"는 원칙의 실물
- 이후 전 실습의 전제: state 버킷, VPC 태그 lookup, 수강생 SSH 키·SG, hermes
  호스트·러너, 플러그인 read 롤

## Slack 요청 예시 + 에이전트가 열 PR diff 예시

**해당 없음 — 이 실습은 에이전트 write-surface가 아니다.** `2-0-setup/`은
CODEOWNERS로 사람 전용이며, 에이전트가 이 디렉토리를 수정하는 PR은 리뷰에서
거부 대상이다. 에이전트와의 접점은 read뿐이다:

```
(Slack) @agent 우리 계정 OIDC 롤 4개 trust 조건이 설계대로인지 확인해줘
→ ops read 도구(ops_aws_get_service 등)가 <project>-hermes-readonly 롤로
  IAM/VPC를 조회해 요약 — 변경은 하지 않는다
```

참고로, 이 실습이 만든 경계가 이후 실습에서 어떻게 보이는지의 예: 에이전트가
`2-1-dev/`의 surface tfvars(예: `disk.auto.tfvars`)를 바꾸는 PR은 CODEOWNERS 무소유라
guard(plan) 통과 시 자동 머지·apply되지만, `2-2-prod/**`를 바꾸는 PR은 branch
ruleset의 require_code_owner_review에 걸려 사람 승인 없이는 머지되지 않는다. 예외는
machine-owned `2-2-prod/access-expiry.auto.tfvars.json` revocation 파일이다. prod
access 추가·연장은 source 파일에서 사람 승인을 받고, 지난 `expires_at` 회수만 이
파일로 자동 머지·apply된다. 어느 경로도 이 루트가 만든 plan/apply 롤과 리포
거버넌스에 의해 성립한다.

## 부트스트랩 절차

전제: 관리자급 로컬 AWS 자격증명, Terraform >= 1.10, gh CLI.

0단계 — 도구·자격증명 검증 + state 버킷 부트스트랩(멱등). 이 스크립트가 CI가 backend로
쓸 state 버킷 `<project>-state-<account>`를 만든다(이 TF 루트는 로컬 state라 이
버킷을 만들지 않는다):

```bash
AWS_PROFILE=fastcampus AWS_REGION=ap-northeast-2 bash 2-0-setup/0-bootstrap.sh
```

그다음 이 루트를 사람이 직접 apply한다:

```bash
terraform -chdir=2-0-setup/1-foundation init
gh auth login   # 러너 등록 토큰 발급용(repo admin 권한). 아직이면.

# github_oidc_subject_prefix = GitHub API의 실제 sub_claim_prefix — helper가 자동 조회.
# github_runner_token        = ~1시간·1회용 — helper가 apply마다 자동 발급.
# ssh_public_key      = 기본값이면 ~/.ssh/ops-agent-iac.pub 자동 읽기 — 보통 불필요
# trusted_ip          = 미지정 시 이 머신 공인 IP 자동 감지 (다를 때만 -var 'trusted_ip=<ip>/32')
bash 2-0-setup/foundation.sh apply
# 만드는 것: VPC·서브넷·SG·키·OIDC/plan/apply 롤·hermes-readonly·모니터링 서버·
# hermes 호스트 1대·ansible 러너(무조건, label=ansible).
```

helper는 `gh api repos/$OWNER/$REPO/actions/oidc/customization/sub --jq .sub_claim_prefix`
결과를 이름으로 재구성하지 않고 그대로 Terraform에 넘긴다. 따라서 기본
`repo:owner/repo`와 immutable-ID가 켜진 `repo:owner@id/repo@id` 모두 GitHub 토큰의
실제 `sub`와 IAM `StringEquals`가 정확히 일치한다.

### ansible 러너 (foundation에 무조건 포함)

위 apply가 self-hosted 러너(`ansible-ops.yml`이 `runs-on: [self-hosted, ansible]`로 쓰는
컨트롤 노드)를 함께 만든다. 등록 확인: GitHub repo Settings > Actions > Runners → label=ansible, status=online.

- `github_runner_token`은 Terraform 입력으로 **필수**이며 helper가 매 apply마다 새로 발급한다.
- 러너가 플릿에 SSH할 개인키는 `~/.ssh/ops-agent-iac`를 자동으로 읽는다(다른 키면 `-var 'fleet_ssh_private_key=...'`).
- 주의: 토큰이 user_data에 들어가므로 foundation을 다시 apply하면(새 토큰) 러너 인스턴스가
  교체되며 재등록된다. 재-apply도 같은 `foundation.sh apply`를 쓴다.
- 새 호스트는 고정 버전이 아니라 GitHub `actions/runner`의 latest stable release를
  조회해 설치한다.

(플러그인을 로컬에서 돌려볼 본인 principal은 `hermes_readonly_trust_principals`
변수로 추가할 수 있다 — Hermes 호스트 롤은 이름 규약으로 항상 trust에 포함되므로
기본값 `[]`로 충분하다.)

CI가 롤 ARN과 backend를 조립하는 데 쓰는 GitHub 설정은 2-0-setup/0-bootstrap.sh가
등록한다 (gh CLI 인증 시 자동, 아니면 bootstrap이 출력한 명령을 직접 실행):
- **secret** `AWS_ACCOUNT_ID` — public 리포에서 Actions 로그의 OIDC ARN에 계정 ID가
  마스킹되도록 secret으로 둔다. 워크플로는 `secrets.AWS_ACCOUNT_ID`를 읽는다.
- **variable** `AWS_REGION`, `PROJECT_NAME`.

`gh secret list`(AWS_ACCOUNT_ID 1개) + `gh variable list`(2개)로 확인한다.

### 리포 거버넌스 (ruleset + environment, 1회)

TF apply와 별개로, 리포 거버넌스는 `2-0-setup/2-github/`의 두 스크립트로 1회 세팅한다
(포크한 자기 리포에서 그대로 실행 — OWNER/REPO는 현재 클론에서 자동 유도):

```bash
bash 2-0-setup/2-github/branch_ruleset.sh   # main에 Repository Ruleset "main-guardrails"
bash 2-0-setup/2-github/destroy_approval.sh     # GitHub Environment "destroy-approval"
```

- `branch_ruleset.sh` — 기본 브랜치에 PR 필수 + required check `guard`(plan,
  strict=up-to-date) + `require_code_owner_review` + `non_fast_forward`(force push
  금지) + `deletion`(브랜치 삭제 금지)를 건다(멱등: PUT/POST). 이 ruleset이
  CODEOWNERS를 정책으로 만든다 — dev surface(`2-1-dev/*.auto.tfvars`, `env.auto.tfvars`
  제외)는 무소유라 guard 통과 시 자동 머지, prod source surface(`2-2-prod/**`에서
  `access-expiry.auto.tfvars.json`·WAF 예외 제외)·모든 `*.tf`·`/2-1-dev/env.auto.tfvars`는
  `@owner` 소유라 사람 승인이 필요하다.
- `destroy_approval.sh` — 리소스 삭제 승인용 `destroy-approval` environment를 만들고
  required reviewer를 리포 오너로 건다(멱등: PUT). `tf-destroy.yml`의 destroy 잡이
  이 environment로 게이트되어, 삭제 워크플로가 실행되기 전에 사람이 GitHub에서
  승인해야 한다(추가로 Slack 인프라팀 멘션 `@진`으로 알린다 — 기본값이며 수강생이
  자기 핸들로 교체).

주의:

- state는 **로컬**이며 gitignore 대상이다. `terraform.tfstate`를 잃으면 재부트스트랩은
  리소스 전수 `terraform import`가 된다 — 백업해 둘 것
- 기존 리포에 순서 개편(`3-grafana → 4-grafana`, `4-hermes → 3-hermes`)을
  반영한다면 Git이 옮기지 않는 ignored 로컬 산출물도 **첫 apply/실행 전에**
  새 경로로 복사한다. 대상은 `3-grafana/terraform.tfstate`,
  `3-grafana/terraform.tfstate.backup`, `4-hermes/.secrets/app.json`,
  `4-hermes/.secrets/app.pem`이다. 목적지에 이미 파일이 있으면 덮어쓰지 말고
  먼저 두 파일을 비교한다. `terraform -chdir=2-0-setup/4-grafana state list`로
  기존 리소스가 보이는 것을 확인할 때까지 기존 파일을 백업으로 유지한다.
- 포크해서 쓰는 경우 `-var github_owner=<본인 핸들>`을 반드시 넘겨야 한다.
  trust sub의 owner가 다르면 모든 CI 롤 assume이 AccessDenied로 죽는다

## ops 플러그인 read 자격증명 (사람-로컬 별도 디렉터리, 선택)

> Hermes 호스트에 Hermes 설치 + 플러그인 배포 + .env/SOUL 배선 + 검증 전체 절차는
> `2-0-setup/3-hermes/README.md` 참고. 아래는 그 중 read 자격증명(토큰) 발급 부분이다.

ops 플러그인의 Grafana read 배선도 UI 클릭 대신 IaC로 간다. 이 디렉토리 아래의
독립 terraform 디렉터리이고, 위 1-foundation처럼 사람이 로컬에서만 apply한다
(CI target allowlist 밖, 로컬 state).

Grafana — 대시보드 + Editor service account/토큰(조회 + 알람 silence)을 apply한다 (foundation apply로
서버가 뜨고 Grafana가 기동한 뒤). 서버 인프라와 분리돼 있어 서버는 그대로 두고
관측 콘텐츠만 재-apply할 수 있다. **알람 룰·contact point·notification 정책은 여기가
아니라 `2-3-incident-response`에서 세팅한다** (그 실습 README 참고):

```bash
cd 2-0-setup/4-grafana
terraform init && terraform apply
# admin 비밀번호를 UI에서 바꿨다면: -var 'grafana_auth=admin:<새 비밀번호>'

terraform output ops_grafana_url               # → OPS_GRAFANA_URL
terraform output ops_grafana_public_url        # → OPS_GRAFANA_PUBLIC_URL
terraform output -raw ops_grafana_token; echo  # → OPS_GRAFANA_TOKEN
```

PagerDuty — 실습 service + escalation policy + routing key는 커리큘럼 뒤쪽의
`3-1-pagerduty`로 옮겼다(critical 페이징은 2-3 알람 경로 위에 얹는 실습).
세팅·배선·read 토큰(`OPS_PAGERDUTY_TOKEN`) 발급 전부 `3-1-pagerduty/README.md` 참고.

Cloudflare — DNS·WAF·Analytics read 토큰 (플러그인 ops-cloudflare-read용, 필수 — 2-05/2-06 dns/waf 반영 조회 + 엣지 5xx 비율 조회):

> `dash.cloudflare.com/profile/api-tokens` → Create Custom Token으로 **최소권한
> read 토큰**을 발급한다. 전부 Zone 스코프, Specific zone(예: example.com):
> `Zone → DNS → Read` · `Zone → WAF → Read` · `Zone → Zone → Read` ·
> `Zone → Analytics → Read`(ops_cloudflare_get_analytics의 GraphQL 5xx 조회에 필수 —
> 빠지면 이 툴만 authz 에러, DNS/WAF 조회는 정상).
> apply용 write 토큰(DNS/WAF Edit)은 GitHub secret `CLOUDFLARE_API_TOKEN`에,
> read 토큰은 아래 Hermes `.env`에 넣는다(dns/waf surface는 2-1-dev / 2-2-prod의
> dns·waf.auto.tfvars로 변경). Zone ID는 read 토큰으로 조회 가능: `GET /client/v4/zones`.

### Hermes 호스트 `.env` 배선 (ops 플러그인 read 자격증명 종합)

이 루트가 만든 hermes 호스트(`<project>-hermes`)의 `~/.hermes/.env`에 아래 키를 넣으면
각 read 툴셋이 활성화된다. 값이 없으면 해당 툴셋은 자동 비활성(check gate).

```bash
# ops-obs-read (Grafana / Prometheus / Loki)
OPS_GRAFANA_URL=http://<monitoring-private-ip>:3000  # grafana output ops_grafana_url (같은 VPC private)
OPS_GRAFANA_PUBLIC_URL=http://<monitoring-public-ip>:3000  # grafana output ops_grafana_public_url (응답에 인용할 dashboard 링크 base)
OPS_GRAFANA_TOKEN=<Editor SA 토큰>                    # grafana output ops_grafana_token (조회+silence)
# ops-pagerduty-read
OPS_PAGERDUTY_TOKEN=<PagerDuty full-access key>       # 조회 + incident ack/snooze/resolve
OPS_PAGERDUTY_FROM_EMAIL=<PD 로그인 이메일>           # incident write 필수 From 헤더
# ops-cloudflare-read
OPS_CLOUDFLARE_READ_TOKEN=<Cloudflare read 토큰>
OPS_CLOUDFLARE_ZONE_ID=<zone id>
```

> hermes 호스트는 이 루트가 만든 VPC(`10.42.0.0/16`)·공유 SG 안에 있으므로 obs-read가
> Grafana(private IP:3000)를 같은 VPC 안에서 pull한다 — 공유 SG의 self 규칙(main.tf)이
> 실습 인프라 간 통신을 상시 허용하므로 별도 SG 개방이나 hermes 공인 IP 세팅이 필요 없다.
> (Grafana UI는 `trusted_ip`만 여는 별도 규칙으로 수강생 브라우저가 공인 IP:3000에 접근한다.)

### 에이전트 응답 언어 (한국어)

Hermes 에이전트의 코어 시스템 프롬프트는 `~/.hermes/SOUL.md`다. 언어 지시는 파일
**최상단**에 둔다(끝에 append하면 앞의 영어 기본 프롬프트에 앵커링돼 영어로 샌다).
전체 작성 예시와 gateway 재시작은 `ops-agent-plugin` README "응답 언어: 한국어
(SOUL.md)" 절을 따른다.

## 검증 포인트

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 1. state 버킷 버저닝
aws s3api get-bucket-versioning --bucket "<project>-state-${ACCOUNT}"   # → Enabled

# 2. OIDC provider + GHA 롤 2개(plan/apply) + readonly 롤 + hermes 호스트 롤
aws iam list-open-id-connect-providers
for r in <project>-plan <project>-apply <project>-hermes-readonly \
         <project>-hermes; do
  aws iam get-role --role-name "$r" \
    --query 'Role.AssumeRolePolicyDocument.Statement[].Condition' 
done
# → plan sub는 pull_request 하나, apply sub는 refs/heads/main + refs/heads/dev (+ destroy env, 전부 StringEquals)인지 확인
# → hermes-readonly trust에 hermes 호스트 롤 ARN이 들어 있는지 확인

# 3. VPC 태그 lookup — 이후 실습들이 쓰는 것과 동일한 조회
aws ec2 describe-vpcs --filters Name=tag:Name,Values=<project> \
  --query 'Vpcs[].CidrBlock'                                        # → 10.42.0.0/16
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=<vpc-id> Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[].AvailabilityZone'                               # → AZ 2개

# 4. 부정 테스트(개념): 로컬 자격증명으로 <project>-apply를 assume해 보면
#    실패한다 — trust가 OIDC 토큰의 main-push sub만 받기 때문. CI 밖에는 apply
#    경로가 없다는 것이 설계의 핵심
aws sts assume-role \
  --role-arn "arn:aws:iam::${ACCOUNT}:role/<project>-apply" \
  --role-session-name should-fail                                    # → AccessDenied 여야 정상

# 5. 공유 접근 프리미티브 — key pair + 공유 접근 SG (모든 실습 EC2가 이걸로 SSH)
aws ec2 describe-key-pairs --key-names "<project>"
aws ec2 describe-security-groups \
  --filters Name=group-name,Values=<project> \
  --query 'SecurityGroups[].IpPermissions[].IpRanges[].CidrIp'      # → 본인 공인 IP /32

# 6. 공유 모니터링 스택 — 인스턴스 + Grafana/Loki 엔드포인트
aws ec2 describe-instances \
  --filters Name=tag:Name,Values=<project>-monitoring-server \
            Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId'                    # → 인스턴스 1개
cd 2-0-setup/1-foundation
terraform output grafana_url     # → http://<public-ip>:3000 (var.trusted_ip에서만 접근)
terraform output loki_push_url   # → http://<private-ip>:3100/loki/api/v1/push

# 7. "이게 되네" — read 롤 assume. 롤 ARN은 이 디렉토리에서 확인한다:
terraform output -raw hermes_readonly_role_arn
#    그 ARN을 들고 "hermes 호스트의 SSH 세션 안에서" 실행:
aws sts assume-role \
  --role-arn "<위 output의 ARN>" \
  --role-session-name day2-smoke                                     # → Credentials 발급
# 발급된 임시 자격증명으로는 read만 된다(예: aws ec2 describe-vpcs).
# write(예: aws ec2 create-tags)는 AccessDenied — 그게 이 경계의 요점이다.
```

이후 실습 루트가 이 기반을 참조하는 표준 스니펫 (ID 하드코딩 금지, 태그 lookup):

```hcl
data "aws_vpc" "foundation" {
  filter {
    name   = "tag:Name"
    values = [var.project]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.foundation.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["public"]
  }
}
```

## 알려진 한계

- **main-push sub는 workflow를 구분하지 못한다.** `ref:refs/heads/main` 토큰은
  tf-apply.yml이 발급받았는지, main에 새로 추가된 악성 workflow가 발급받았는지
  IAM trust로는 식별 불가(OIDC 토큰에 workflow 클레임이 있긴 하나 sub 표준 형식에는
  없음). 보완 통제: `.github/`은 CODEOWNERS 사람 전용 + branch ruleset의
  리뷰 필수 — workflow 파일을 바꾸려면 먼저 사람 승인 PR을 통과해야 한다.
  prod 변경·리소스 삭제 게이트도 IAM이 아니라 CODEOWNERS + destroy-approval
  environment로 성립한다(main-push sub 하나만으로는 prod까지 못 민다)
- plan 롤의 ReadOnlyAccess는 계정 전체 read다(실습 단순화를 위한 관리형 정책
  선택). 민감 데이터가 있는 계정이라면 과도하다 — 실습 전용 계정 사용이 전제
- apply 롤 인라인 정책의 `iam:AttachRolePolicy`는 이름 접두사(`<project>-*`)로만
  제한된다 — 어떤 관리형 정책을 붙일지는 CODEOWNERS가 보호하는 `*.tf`가 결정.
  `iam:PolicyARN` 조건으로 더 조이는 것은 심화 과제

## destroy 절차 (로컬)

**경고: 이 실습의 destroy는 리포 전체의 마지막 단계다.** state 버킷에는 2-1-dev /
2-2-prod의 state가 들어 있고, 롤이 사라지면 CI 전체가 죽는다. 순서를 지킬 것:

```bash
# 1. 먼저 살아있는 실습(2-1-dev / 2-2-prod)을 tf-destroy.yml(workflow_dispatch)로 정리
#    (states/2-1-dev.tfstate·states/2-2-prod.tfstate가 리소스 0인 상태가 될 때까지).
#    tf-destroy는 destroy-approval environment 승인 게이트를 거친다.

# 2. 버저닝 버킷은 비우기 전에는 삭제되지 않는다(force_destroy=false, 의도적).
#    모든 버전 + delete marker를 제거:
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
b="<project>-state-${ACCOUNT}"
aws s3api delete-objects --bucket "$b" --delete "$(aws s3api list-object-versions \
  --bucket "$b" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"
aws s3api delete-objects --bucket "$b" --delete "$(aws s3api list-object-versions \
  --bucket "$b" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)"
# (해당 종류의 오브젝트가 하나도 없으면 delete-objects가 에러를 내는데, 무시해도 된다)

# 2b. state 버킷은 이 루트의 TF 리소스가 아니라 2-0-setup/0-bootstrap.sh가 CLI로 만든 것이라
#     terraform destroy 대상이 아니다 — 비운 뒤 직접 지운다. state 버킷의
#     비우기+삭제는 `bash 2-0-setup/teardown.sh`로도 할 수 있다.
aws s3api delete-bucket --bucket "<project>-state-${ACCOUNT}"

# 3. grafana provider를 쓰는 디렉터리들을 먼저 destroy한다 — provider가 살아있는
#    서버(:3000)에 접속해 알람·contact point(2-3-incident-response), 대시보드·SA
#    (4-grafana)를 지운다. foundation을 먼저 내리면 서버가 없어 이 destroy가 접속
#    불가로 실패하므로 순서를 지킬 것. (PagerDuty를 apply했다면 3-1-pagerduty도
#    PAGERDUTY_TOKEN을 export하고 destroy.)
terraform -chdir=2-3-incident-response destroy
cd 2-0-setup/4-grafana
terraform destroy

# 4. 마지막으로 foundation destroy — 모니터링 EC2·hermes 호스트·ansible 러너와
#    부수 seed 리소스가 함께 삭제된다.
cd ../..
bash 2-0-setup/foundation.sh destroy
```

상시 비용 참고: 이 루트를 유지하면 공유 모니터링 서버 t3.small(24/7, 월 ~$15) +
hermes 호스트 1대 t3.small(24/7) + 일부러 놀리는 시드 EIP(월 ~$3.6,
의도적) + 시드 EBS·스냅샷이 상시 과금된다(state 버킷 S3는 소량, VPC·IGW·IAM/OIDC는
무과금, NAT 없음). 강의 세션 사이에는 모니터링·hermes EC2를 stop하거나, 과정 종료
시 destroy한다.
