#!/usr/bin/env bash
#
# 2-0-setup/2-github/destroy_approval.sh — 리소스 삭제 승인용 GitHub Environment(destroy-approval) 생성.
#
# tf-destroy.yml의 destroy 잡과 tf-apply.yml의 approve-destroy 잡(service_enabled=false
# 삭제성 apply)이 environment: destroy-approval로 게이트된다. 여기에
# required reviewer(리포 오너)를 걸면, 삭제가 실행되기 전에 사람이 GitHub
# UI에서 승인해야 한다.
#
# 플랜/가시성 제약(중요):
#   - required reviewers 보호규칙: public 리포는 무료, private 리포는 GitHub Enterprise 필요
#     (Free/Pro/Team의 private에서는 미지원 — HTTP 422).
#   - environment 생성 자체: private 리포는 Pro/Team/Enterprise 필요(Free는 미지원).
#   이 스크립트는 위 제약에 걸리면 죽지 않고, 가능한 데까지 만든 뒤 안내한다.
#
# 멱등(PUT). OWNER/REPO는 현재 클론에서 자동 유도되므로 fork한 자기 리포에서 그대로 실행.
set -euo pipefail

REPO_FULL=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=$(gh repo view --json owner --jq .owner.login)
OWNER_ID=$(gh api "/users/${OWNER}" --jq .id)
VISIBILITY=$(gh repo view --json visibility --jq .visibility)
BASE="/repos/${REPO_FULL}/environments/destroy-approval"

echo "Environment 'destroy-approval' 설정: ${REPO_FULL} (${VISIBILITY})"

# 1) required reviewer(오너) 포함 시도 — public 또는 Enterprise면 성공.
if out=$(gh api --method PUT "$BASE" --input - 2>&1 <<JSON
{"wait_timer":0,"reviewers":[{"type":"User","id":${OWNER_ID}}],"deployment_branch_policy":null}
JSON
); then
  echo "완료 — tf-destroy·삭제성 tf-apply는 이제 ${OWNER} 승인 전까지 대기한다."
  exit 0
fi

echo "  ! required reviewers 규칙 적용 실패: $(printf '%s' "$out" | tail -n1)" >&2

# 2) 실패(대개 Free/Pro/Team + private) — 보호규칙 없는 순수 환경만 만든다(게이트 미적용).
#    wait_timer도 보호규칙이라 Free/private에선 422 → body를 비워 protection rule 없이 생성.
if out2=$(gh api --method PUT "$BASE" --input - 2>&1 <<JSON
{}
JSON
); then
  cat >&2 <<MSG
  → 환경 'destroy-approval'은 생성됐지만 승인 게이트(required reviewers)는 미적용이다.
    이유: GitHub Free/Pro/Team의 ${VISIBILITY} 리포는 required reviewers 보호규칙 미지원
          (public 리포는 무료 / private은 GitHub Enterprise 필요).
    해결: (a) 리포를 public 전환 후 이 스크립트 재실행, 또는 (b) GitHub Enterprise.
    영향: tf-destroy·삭제성 tf-apply가 사람 승인 없이 실행될 수 있으니, 그때까진 삭제를 신중히 트리거.
MSG
  exit 0
fi

# 3) 환경 생성도 실패 — Free의 private 리포는 environments 자체가 미지원.
cat >&2 <<MSG
  ✗ 환경 생성 실패: $(printf '%s' "$out2" | tail -n1)
    GitHub Free의 private 리포는 environments 자체가 미지원이다.
    → 리포를 public 전환하거나 GitHub Pro/Team 이상으로 올린 뒤 재실행할 것.
MSG
exit 1
