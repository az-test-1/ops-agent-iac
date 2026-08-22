# setup — 일회성 부트스트랩 스크립트

수강생 로컬에서 **한 번만** 돌리는 세팅 스크립트 모음이다. 크게 두 갈래다:

- AWS/GitHub 기반 세팅 — `bootstrap.sh`(state 버킷 + 리포 변수),
  `branch_ruleset.sh`(main 보호), `destroy_approval.sh`(삭제 승인 게이트),
  `teardown.sh`(state 버킷 삭제).
- 에이전트 write 정체성 — `create_github_app.py` + `print_install_id.py`
  (에이전트가 PR을 봇 이름으로 열게 하는 GitHub App).

공유 인프라 자체(VPC·OIDC 롤·`<project>-hermes-readonly`·모니터링 스택·hermes 호스트·
ansible 러너)는 이 스크립트들이 아니라 `bash 2-0-setup/foundation.sh apply`가
만든다. 아래 부트스트랩 → foundation apply → App 배선 순서다.

## 0. state 버킷 + 리포 변수 (bootstrap.sh)

```bash
AWS_PROFILE=fastcampus AWS_REGION=ap-northeast-2 bash 2-0-setup/0-bootstrap.sh
PROJECT_NAME=my-own-name bash 2-0-setup/0-bootstrap.sh   # 이름을 직접 정할 때
```

- 사전 요구사항(terraform >= 1.10 / ansible / aws cli)을 확인·설치하고 AWS 자격증명을 검증한다.
- Terraform state S3 버킷 `<project>-state-<account>`를 **AWS CLI로** 만든다
  (버저닝 + 퍼블릭 접근 차단 + AES256 암호화, 멱등). 모든 디렉터리(2-N)가 이 버킷을
  S3 backend로 쓰므로, 첫 CI apply 전에 존재해야 해서 여기서 부트스트랩한다.
  `2-0-setup`은 이 버킷을 만들지 않는다.
- gh CLI가 인증돼 있으면 리포 시크릿/변수를 자동 등록한다:
  `AWS_ACCOUNT_ID`(secret — public 리포 로그 마스킹), `AWS_REGION`·`PROJECT_NAME`(variable).
  CI 워크플로가 이 값으로 배포 계정·리전·이름 프리픽스를 읽는다.
- `<project>` 프리픽스 기본값은 리포 루트 디렉토리 이름이고 `PROJECT_NAME`으로 바꾼다.
  같은 값이 모든 AWS 리소스 이름의 프리픽스가 된다(ALB 이름 32자 제한 때문에 2~24자).

## 1. foundation apply (2-0-setup/1-foundation)

`bootstrap.sh` 이후, 공유 인프라를 사람 로컬에서 apply한다:

```bash
terraform -chdir=2-0-setup/1-foundation init
bash 2-0-setup/foundation.sh apply
```

공유 SSH 키 + 접근 SG(`<project>`, trusted IP만), VPC 10.42.0.0/16 + 퍼블릭 서브넷 2개 + IGW,
GitHub OIDC provider + Actions 롤(plan=ReadOnly / apply=PowerUser), `<project>-hermes-readonly`
읽기 경계 롤, 공유 모니터링 서버(Prometheus/Loki/Grafana) 1대, hermes 호스트 1대
(<project>-hermes), self-hosted ansible 러너를 만든다.

## 2. 리포 거버넌스 (branch_ruleset.sh + destroy_approval.sh)

CODEOWNERS의 `<본인-핸들>`을 치환한 뒤(브랜치별 사본이 다르므로 **main·dev 두
브랜치에서 각각** 치환·커밋한다 — dev 사본만 modules/·2-1-dev/·ansible/ 소유를
해제한다), main 브랜치 보호와 삭제 승인 게이트를 건다:

```bash
bash 2-0-setup/2-github/branch_ruleset.sh   # main 보호 + guard 체크 + code-owner 리뷰
bash 2-0-setup/2-github/destroy_approval.sh     # 삭제 승인 게이트(destroy-approval)
```

- **branch_ruleset.sh** — main에 GitHub Repository Ruleset `main-guardrails`를 건다(멱등).
  PR 필수 + `guard`(plan) 체크 통과(strict=최신) + `require_code_owner_review` +
  브랜치 삭제·force-push 금지. ⚠ ruleset 집행은 public 리포=Free 가능 / private
  리포=Pro(개인)·Team(조직) 이상 — Free+private에서는 생성만 되고 집행되지 않으며
  (UI 배너로만 고지), 스크립트가 이 조합을 감지해 경고한다. Free 플랜이면 리포를
  public으로 둘 것(실습 리포에 시크릿 없음). repo admin(수강생)은 bypass 가능
  (비상용 escape hatch).
  CODEOWNERS가 자동 머지 vs 사람 승인 경계를 정한다: dev surface tfvars(env.auto.tfvars 제외)는
  무소유=자동 머지 / prod source surface(2-2-prod/**에서 WAF·access-expiry revocation
  예외 제외) + `*.tf` + `/2-1-dev/env.auto.tfvars`는 사람 승인.
- **destroy_approval.sh** — 리소스 삭제용 GitHub Environment `destroy-approval`을 만든다(멱등).
  required reviewer는 리포 오너. `tf-destroy.yml`의 destroy 잡이 이 environment로 게이트돼,
  Slack 인프라팀 멘션과 함께 사람 승인 전까지 삭제가 대기한다.

## 3. App 만들기 (클릭 한 번)

에이전트가 PR을 **자기 이름(봇)** 으로 열게 하려면 GitHub App이 필요하다.
App은 소유자의 브라우저 승인이 필수라 Terraform/토큰으로는 만들 수 없고, GitHub의
**App Manifest flow**로만 생성된다. 이 스크립트가 그 앞뒤를 자동화해 **클릭
한 번**으로 끝나게 한다.

```bash
# gh CLI 로그인 상태여야 함 (gh auth status)
python3 2-0-setup/2-github/create_github_app.py
```

- 브라우저가 열린다 → `Create GitHub App` 클릭 → `Create GitHub App for <you>` 클릭.
- 자격증명이 `./.secrets/app.pem` (private key) + `./.secrets/app.json` (app_id·slug)로
  저장된다. `.secrets/`는 gitignore 대상이다.
- 이름이 이미 쓰이고 있으면 rename을 요구한다 — `--name <unique>`로 재실행.

권한(고정): Contents(write) = 브랜치·tfvars 커밋, Pull requests(write) = PR 열기,
Metadata(read).

같은 App 자격증명을 리포 시크릿으로도 등록한다 — `access-expiry.yml`(만료 액세스 회수)이
이 App을 CI 봇 정체성으로 써서 revocation PR을 열어야 guard/tf-plan/auto-merge가
정상 트리거된다. prod access source 파일은 계속 CODEOWNER 승인 대상이고, 지난
`expires_at` 회수만 `access-expiry.auto.tfvars.json`에서 자동 머지된다:

```bash
gh secret set EXPIRY_APP_ID --body "$(jq -r '.app_id' .secrets/app.json)"
gh secret set EXPIRY_APP_PRIVATE_KEY < .secrets/app.pem
```

## 4. 앱 설치 (클릭 한 번)

스크립트가 끝나며 출력하는 설치 링크(`https://github.com/apps/<slug>/installations/new`)로
가서 **본인 리포만** 선택해 Install.

## 5. installation_id 확인

```bash
python3 2-0-setup/2-github/print_install_id.py
```

`.secrets/app.json`(app_id) + `.secrets/app.pem`으로 짧은 app JWT를 발급해 installation을
조회한다. 앱을 설치한 **뒤에** 실행한다. PyJWT가 필요하다(Hermes 에이전트 venv에는 이미 포함).

## 6. 에이전트에 배선

Hermes 호스트의 `~/.hermes/.env`:

```
OPS_GITHUB_APP_ID=<app_id>
OPS_GITHUB_PRIVATE_KEY_PATH=/absolute/path/to/.secrets/app.pem
OPS_GITHUB_INSTALLATION_ID=<installation_id>
OPS_GITHUB_REPO=<owner>/ops-agent-iac
```

이 값으로 change 툴셋이 **수명이 짧은 설치 토큰**을 발급해 PR을 봇 이름으로 연다.
GitHub 조회 툴(PR/런 상태)도 같은 App 토큰을 쓰므로 별도 토큰은 필요 없다.

## 정리 (teardown.sh)

```bash
AWS_PROFILE=fastcampus bash 2-0-setup/teardown.sh
PROJECT_NAME=my-own-name bash 2-0-setup/teardown.sh   # bootstrap 때 이름을 직접 정했다면
```

`bootstrap.sh`가 만든 state 버킷 `<project>-state-<account>`를 (모든 버전 + 삭제마커 포함)
삭제한다. 버킷 이름을 그대로 타이핑해야 진행되는 확인 프롬프트가 있다.

**순서 주의**: 버킷에 tfstate가 남아 있으면 각 디렉터리의 Terraform state가 사라져
남은 리소스를 추적·삭제할 수 없게 된다. 먼저 각 디렉터리 리소스를 `tf-destroy.yml`(또는
`terraform destroy`)로, `2-0-setup` 리소스를 `bash 2-0-setup/foundation.sh destroy`로
정리한 뒤 마지막에 이 스크립트를 돌린다(버킷에 tfstate가 남아 있으면 경고를 띄운다).
GitHub 리포 변수는 별도로 `gh variable delete` / `gh secret delete`.
