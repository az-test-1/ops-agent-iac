#!/usr/bin/env bash
#
# 2-0-setup/0-bootstrap.sh — 새 수강생 환경을 위한 일회성 초기 설정.
#
#   1. 사전 요구사항 설치 / 확인 (terraform, aws cli)
#   2. AWS 자격증명 검증
#   3. AWS CLI로 Terraform state S3 버킷 생성 (idempotent)
#   4. GitHub 리포 변수 등록 (gh CLI 인증 시 자동; 아니면 명령 출력)
#
# state 버킷은 모든 루트(2-NN, 3-NN)가 S3 backend로 쓰는 것이다
# (CI가 init 때 bucket/key/region을 주입). 2-0-setup은 이걸 만들지
# 않는다 — 각 디렉터리의 첫 CI apply 전에 버킷이 이미 존재해야 하므로 여기서 CLI로
# 부트스트랩한다. 재실행해도 안전하다.
#
# 모든 리소스 이름은 프로젝트 이름을 프리픽스로 쓴다. 기본값은 리포 루트
# 디렉토리 이름이고, PROJECT_NAME 환경 변수로 바꿀 수 있다. 같은 값이
# GitHub 리포 변수 PROJECT_NAME → CI(dflook variables 입력) → Terraform var.project로 흐른다.
#
# Usage:
#   AWS_PROFILE=fastcampus AWS_REGION=ap-northeast-2 bash 2-0-setup/0-bootstrap.sh
#   PROJECT_NAME=my-own-name bash 2-0-setup/0-bootstrap.sh   # 이름을 직접 정할 때
#
# 삭제(청소)는 2-0-setup/teardown.sh 참고.
#
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-2}"

# 프로젝트 이름: PROJECT_NAME > 리포 루트 디렉토리 이름(소문자 변환).
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT_NAME:-$(basename "$repo_root" | tr '[:upper:]' '[:lower:]')}"
if ! printf '%s' "$PROJECT" | command grep -Eq '^[a-z0-9][a-z0-9-]{1,23}$'; then
  printf 'ERROR 프로젝트 이름 "%s"은 리소스 이름으로 쓸 수 없습니다(소문자/숫자/하이픈, 2~24자 — ALB 이름 32자 제한 때문).\n' "$PROJECT" >&2
  printf '      PROJECT_NAME=<이름> bash 2-0-setup/0-bootstrap.sh 로 직접 지정해주세요.\n' >&2
  exit 1
fi

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }

# ------------------------------------------------------- 1. 사전 요구사항
os="$(uname -s)"
install_hint() {
  local tool="$1"
  case "$os" in
    Linux)
      echo "  Linux에서 '$tool' 설치 방법:"
      case "$tool" in
        terraform) echo "    https://developer.hashicorp.com/terraform/install (apt: hashicorp repo)";;
        aws)       echo "    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html";;
      esac;;
    *) echo "  $os에서는 '$tool'을 수동으로 설치해주세요";;
  esac
}

ensure_tool() {
  local bin="$1" name="${2:-$1}"
  if command -v "$bin" >/dev/null 2>&1; then
    return 0
  fi
  say "$name 설치 중 (미설치 상태)"
  if [ "$os" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    case "$name" in
      terraform) brew tap hashicorp/tap >/dev/null 2>&1 || true; brew install hashicorp/tap/terraform ;;
      *)         brew install "$name" ;;
    esac
  else
    warn "이 시스템에서는 '$name'을 자동 설치할 수 없습니다."
    install_hint "$name"
    return 1
  fi
}

say "사전 요구사항 확인 (terraform / aws cli)"
missing=0
ensure_tool terraform terraform || missing=1
ensure_tool aws awscli          || missing=1
if [ "$missing" -ne 0 ]; then
  warn "위 도구들을 설치한 뒤 이 스크립트를 다시 실행해주세요."
  exit 1
fi
echo "  terraform: $(terraform version | head -1)"
echo "  aws:       $(aws --version 2>&1)"

# terraform >= 1.10 강제 — brew 코어 formula는 라이선스 변경으로 1.5.7에서
# 동결돼 있어, 그걸로 설치하면 모든 루트의 required_version에 걸린다.
tf_ver="$(terraform version | head -1 | sed 's/^Terraform v//')"
tf_major="${tf_ver%%.*}"
tf_minor_rest="${tf_ver#*.}"
tf_minor="${tf_minor_rest%%.*}"
if [ "$tf_major" -lt 1 ] || { [ "$tf_major" -eq 1 ] && [ "$tf_minor" -lt 10 ]; }; then
  warn "terraform v${tf_ver}는 이 리포의 요구 버전(>= 1.10)보다 낮습니다."
  warn "brew 코어 formula는 1.5.7에서 동결돼 있습니다 — 아래로 재설치하세요:"
  warn "  brew uninstall terraform && brew tap hashicorp/tap && brew install hashicorp/tap/terraform"
  exit 1
fi

# ---------------------------------------------------------- 2. 자격증명
say "AWS 자격증명 확인"
if ! aws sts get-caller-identity >/tmp/ta_ident.json 2>/tmp/ta_ident.err; then
  warn "AWS 자격증명이 설정되지 않았거나 유효하지 않습니다."
  cat >&2 <<'EOF'
  아래 방법 중 하나로 설정한 뒤 다시 실행해주세요:
    aws configure                       # 정적 액세스 키
    aws configure sso                   # IAM Identity Center (SSO) 설정 후:
    aws sso login --profile <본인 프로파일>
    export AWS_PROFILE=<본인 프로파일>
EOF
  exit 1
fi
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
echo "  계정: $ACCOUNT   리전: $REGION"

# --------------------------------------------------- 3. TF state 버킷
BUCKET="${PROJECT}-state-${ACCOUNT}"
say "Terraform state 버킷 확인/생성: s3://${BUCKET}"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "  이미 존재함 — 생성 건너뜀"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  echo "  생성 완료"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
echo "  버저닝 + 퍼블릭 접근 차단 + 암호화 적용 완료"

# ------------------------------------ 4. GitHub 리포 변수 (가능하면 자동 등록)
# CI 워크플로가 계정/리전/이름 프리픽스를 읽는 repo variable 3개. gh CLI가
# 인증돼 있고 리포 안에서 실행됐다면 여기서 바로 등록한다 — 아니면 아래
# "다음 단계"에 수동 명령을 출력한다 (등록을 건너뛰면 CI가 리포 이름으로
# 폴백하는데, PROJECT_NAME을 직접 정한 경우 버킷/롤 이름이 어긋나 CI가 죽는다).
GH_VARS_DONE=0
OIDC_PREFIX_DONE=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
   && gh repo view --json nameWithOwner >/dev/null 2>&1; then
  REPO_NWO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  OWNER="${REPO_NWO%%/*}"
  REPO="${REPO_NWO#*/}"
  if OIDC_SUBJECT_PREFIX="$(
    gh api "repos/$OWNER/$REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix
  )" && [ -n "$OIDC_SUBJECT_PREFIX" ]; then
    echo "  GitHub OIDC subject prefix: $OIDC_SUBJECT_PREFIX"
    OIDC_PREFIX_DONE=1
  else
    warn "GitHub OIDC sub_claim_prefix 조회 실패 — foundation apply 전에 gh 권한을 확인하세요."
  fi

  say "GitHub 리포 시크릿/변수 등록 (AWS_ACCOUNT_ID=secret, AWS_REGION·PROJECT_NAME=variable)"
  # AWS_ACCOUNT_ID는 secret으로 — public 리포에서 Actions 로그의 OIDC ARN에 계정 ID가
  # 노출되지 않도록 마스킹된다. 워크플로는 secrets.AWS_ACCOUNT_ID를 읽는다.
  if gh secret set AWS_ACCOUNT_ID --body "$ACCOUNT" \
     && gh variable set AWS_REGION --body "$REGION" \
     && gh variable set PROJECT_NAME --body "$PROJECT"; then
    echo "  등록 완료 (gh secret list / gh variable list 로 확인)"
    GH_VARS_DONE=1
  else
    warn "gh secret/variable set 실패 — 아래 1)의 명령을 직접 실행해주세요."
  fi

  # DB_PASSWORD는 데모 기본값으로 1차 등록 — secret으로 존재해야 Actions 로그에서
  # 마스킹된다(미등록이면 워크플로가 같은 값을 평문 폴백으로 찍는다). 재실행이
  # 학생이 교체해 둔 값을 덮지 않도록 이미 있으면 건너뛴다. 교체는 가이드 3장.
  if gh api "repos/$OWNER/$REPO/actions/secrets/DB_PASSWORD" >/dev/null 2>&1; then
    echo "  DB_PASSWORD 이미 등록됨 — 유지"
  elif gh secret set DB_PASSWORD --body 'AppDemoPw2026!'; then
    echo "  DB_PASSWORD 데모 기본값 등록 (교체: gh secret set DB_PASSWORD --body '<새 비밀번호>')"
  else
    warn "DB_PASSWORD 등록 실패 — gh secret set DB_PASSWORD 로 직접 등록해주세요."
  fi
else
  warn "gh CLI 미설치/미인증이거나 GitHub 리포 밖 — 리포 변수는 아래 1)의 명령으로 직접 등록해주세요."
fi

# ------------------------------------------------------------- 다음 단계
say "부트스트랩 완료"
cat <<EOF
프로젝트: ${PROJECT}   State 버킷: s3://${BUCKET} (${REGION})

다음 단계:
EOF
if [ "$GH_VARS_DONE" = "1" ]; then
  echo "  1) GitHub 변수/시크릿 — 등록 완료"
else
  cat <<EOF
  1) GitHub 변수/시크릿 등록:
       gh secret   set AWS_ACCOUNT_ID --body "${ACCOUNT}"
       gh variable set AWS_REGION     --body "${REGION}"
       gh variable set PROJECT_NAME   --body "${PROJECT}"
       gh secret   set DB_PASSWORD    --body 'AppDemoPw2026!'   # 데모 기본값 — 교체는 가이드 3장
EOF
fi
if [ "$OIDC_PREFIX_DONE" != "1" ]; then
  cat <<'EOF'
     foundation은 GitHub API의 OIDC subject prefix가 필수입니다:
       gh api repos/$OWNER/$REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
EOF
fi
cat <<EOF
  2) 공유 인프라 생성:
       terraform -chdir=2-0-setup/1-foundation init
       bash 2-0-setup/foundation.sh apply
  3) 리포 거버넌스:
       bash 2-0-setup/2-github/branch_ruleset.sh
       bash 2-0-setup/2-github/destroy_approval.sh

세부 절차·검증은 2-0-setup/README.md 참고.   정리: bash 2-0-setup/teardown.sh
EOF
