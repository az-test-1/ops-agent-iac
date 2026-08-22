#!/usr/bin/env bash
#
# GitHub 리포 설정과 일치하는 값으로 foundation을 apply/destroy한다.
# OIDC subject prefix는 이름으로 재구성하지 않고 GitHub API 응답을 그대로 전달한다.
#
# Usage:
#   bash 2-0-setup/foundation.sh apply [terraform options...]
#   bash 2-0-setup/foundation.sh destroy [terraform options...]
set -euo pipefail

ACTION="${1:-}"
case "$ACTION" in
  apply|destroy) shift ;;
  *)
    echo "usage: bash 2-0-setup/foundation.sh <apply|destroy> [terraform options...]" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NWO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
OWNER="${REPO_NWO%%/*}"
REPO="${REPO_NWO#*/}"
OIDC_SUBJECT_PREFIX="$(
  gh api "repos/$OWNER/$REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix
)"

case "$OIDC_SUBJECT_PREFIX" in
  repo:*/*) ;;
  *)
    echo "ERROR GitHub OIDC sub_claim_prefix 응답이 비었거나 잘못됨: $OIDC_SUBJECT_PREFIX" >&2
    exit 1
    ;;
esac

common_vars=(
  -var "github_owner=$OWNER"
  -var "github_repo=$REPO"
  -var "github_oidc_subject_prefix=$OIDC_SUBJECT_PREFIX"
)

if [ "$ACTION" = "apply" ]; then
  RUNNER_TOKEN="$(
    gh api -X POST "repos/$OWNER/$REPO/actions/runners/registration-token" --jq .token
  )"
  exec terraform -chdir="$ROOT/2-0-setup/1-foundation" apply \
    "${common_vars[@]}" -var "github_runner_token=$RUNNER_TOKEN" "$@"
fi

# Terraform은 destroy에서도 필수 input variable을 로드한다. 삭제되는 user_data에는
# 토큰을 쓰지 않으므로 비밀이 아닌 sentinel로 prompt만 막는다.
exec terraform -chdir="$ROOT/2-0-setup/1-foundation" destroy \
  "${common_vars[@]}" -var "github_runner_token=unused-during-destroy" "$@"
