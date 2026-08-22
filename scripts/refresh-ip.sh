#!/usr/bin/env bash
# refresh-ip.sh — 현재 공인 IP로 SSH 접근 SG를 갱신한다.
#
# 공유 접근 SG(<project>, 2-0-setup)는 apply 당시의 trusted IP로 고정된다. 동적
# IP라 주소가 바뀌면 SSH/ansible이 "unreachable"로 끊긴다(hermes 호스트·app·
# 러너 전부 이 SG를 쓴다). 이 스크립트는 그 SG의 ingress를 현재 IP로 in-place
# 갱신한다(인스턴스 교체 없음 — SG rule만 targeted apply).
#
#   AWS_PROFILE=fastcampus bash scripts/refresh-ip.sh [project]
set -euo pipefail
TF="${TF_BIN:-terraform}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${1:-$(basename "$ROOT" | tr '[:upper:]' '[:lower:]')}"
REPO_NWO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
OWNER="${REPO_NWO%%/*}"
REPO="${REPO_NWO#*/}"
OIDC_SUBJECT_PREFIX="$(
  gh api "repos/$OWNER/$REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix
)"
IP="$(curl -s https://checkip.amazonaws.com)"; echo "현재 공인 IP: ${IP}"

echo "== 2-0-setup: 공유 접근 SG(<project>) 갱신 =="
( cd "${ROOT}/2-0-setup/1-foundation" \
  && "${TF}" apply -auto-approve \
       -var "github_owner=${OWNER}" \
       -var "github_repo=${REPO}" \
       -var "github_oidc_subject_prefix=${OIDC_SUBJECT_PREFIX}" \
       -var "github_runner_token=unused-during-targeted-apply" \
       -var "project=${PROJECT}" \
       -target=aws_security_group.shared \
       -target=aws_vpc_security_group_ingress_rule.shared_trusted_all \
       -target=aws_vpc_security_group_ingress_rule.grafana )

# terraform.tfvars의 trusted_ip가 자동 감지보다 우선하므로, 감지 IP가 아니라
# 실제 적용된 output을 보여준다 (감지 IP 에코는 미적용 값 오인 사고가 있었다).
APPLIED="$("${TF}" -chdir="${ROOT}/2-0-setup/1-foundation" output -raw allowed_ip)"
echo "완료 — 공유 SG가 ${APPLIED} 로 갱신됨. SSH/ansible 재시도 가능."
