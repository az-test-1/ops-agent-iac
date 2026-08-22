#!/usr/bin/env bash
#
# 2-0-setup/teardown.sh — 2-0-setup/0-bootstrap.sh가 만든 리소스를 삭제한다.
#
# 지우는 것:
#   - Terraform state 버킷 <project>-state-<account> (버전/삭제마커 전부 포함)
#
# 지우지 않는 것:
#   - 2-0-setup 리소스  → bash 2-0-setup/foundation.sh destroy
#   - 각 디렉터리 리소스        → tf-destroy.yml 워크플로 (또는 terraform destroy)
#   이 순서를 지킬 것: state 버킷을 먼저 지우면 각 디렉터리의 Terraform state가
#   사라져서 남은 리소스를 추적/삭제할 수 없게 된다. 이 스크립트는 버킷에
#   tfstate가 남아 있으면 경고를 띄운다.
#
# Usage:
#   AWS_PROFILE=fastcampus bash 2-0-setup/teardown.sh
#   PROJECT_NAME=my-own-name bash 2-0-setup/teardown.sh   # bootstrap 때 이름을 직접 정했다면
#
set -euo pipefail

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }

# bootstrap.sh와 동일한 규칙으로 프로젝트 이름을 정한다.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT_NAME:-$(basename "$repo_root" | tr '[:upper:]' '[:lower:]')}"

say "AWS 자격증명 확인"
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  warn "AWS 자격증명이 설정되지 않았거나 유효하지 않습니다. 설정 후 다시 실행해주세요."
  exit 1
fi
echo "  계정: ${ACCOUNT}   프로젝트: ${PROJECT}"

BUCKET="${PROJECT}-state-${ACCOUNT}"

say "삭제 대상 확인: s3://${BUCKET}"
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  echo "  버킷이 없습니다 — 삭제할 것이 없어 종료합니다."
  exit 0
fi

# 버킷에 tfstate가 남아 있으면 각 디렉터리/foundation 리소스가 아직 살아 있을 수 있다.
state_keys="$(aws s3api list-objects-v2 --bucket "$BUCKET" \
  --query "Contents[?ends_with(Key, '.tfstate')].Key" --output text 2>/dev/null | tr '\t' '\n' | command grep -v '^$' | command grep -v '^None$' || true)"
if [ -n "$state_keys" ]; then
  warn "버킷에 Terraform state 파일이 남아 있습니다:"
  echo "$state_keys" | sed 's/^/    /' >&2
  warn "해당 디렉터리 리소스가 아직 살아 있다면, 이 버킷을 지우기 전에 먼저"
  warn "tf-destroy.yml(또는 terraform destroy)로 정리해야 합니다."
  warn "지금 버킷을 지우면 남은 리소스를 Terraform으로 추적할 수 없게 됩니다."
fi

version_count="$(aws s3api list-object-versions --bucket "$BUCKET" \
  --query 'length([Versions, DeleteMarkers][] | [])' --output text 2>/dev/null || echo 0)"
[ "$version_count" = "None" ] && version_count=0
echo "  객체 버전 + 삭제마커: ${version_count}개"

printf '\n버킷 s3://%s 를 영구 삭제하려면 버킷 이름을 그대로 입력하세요 (그 외 입력 시 중단): ' "$BUCKET"
read -r answer
if [ "$answer" != "$BUCKET" ]; then
  echo "입력이 일치하지 않아 중단합니다. 아무것도 삭제되지 않았습니다."
  exit 1
fi

say "버킷 비우기 (모든 버전 + 삭제마커)"
# 버저닝 버킷은 `aws s3 rb --force`로 비워지지 않는다 — 버전을 직접 지운다.
while :; do
  batch="$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 1000 --output json \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
objs = [{"Key": v["Key"], "VersionId": v["VersionId"]}
        for k in ("Versions", "DeleteMarkers") for v in d.get(k) or []]
print(json.dumps({"Objects": objs[:1000], "Quiet": True}) if objs else "")
')"
  [ -z "$batch" ] && break
  aws s3api delete-objects --bucket "$BUCKET" --delete "$batch" >/dev/null
  echo "  ...삭제 진행 중"
done
echo "  버킷 비움 완료"

say "버킷 삭제"
aws s3api delete-bucket --bucket "$BUCKET"
echo "  s3://${BUCKET} 삭제 완료"

say "정리 완료"
cat <<EOF
남아 있을 수 있는 것(이 스크립트 범위 밖):
  - 2-0-setup 리소스: bash 2-0-setup/foundation.sh destroy
  - GitHub repo 설정:  gh secret delete AWS_ACCOUNT_ID  +  gh variable delete AWS_REGION / PROJECT_NAME
    (bootstrap이 AWS_ACCOUNT_ID는 secret으로, 나머지 둘은 variable로 등록했다)
EOF
