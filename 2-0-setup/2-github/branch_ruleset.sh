#!/usr/bin/env bash
#
# 2-0-setup/2-github/branch_ruleset.sh
#
# 기본 브랜치 보호를 GitHub **Repository Ruleset**으로 적용한다. rulesets의 이점:
#   - 여러 ruleset 레이어링·집계, tag/다중 패턴, per-ruleset bypass list 지원.
#
# ⚠ 플랜 제약: ruleset "집행"은 public 리포=Free 가능 / private 리포=Pro(개인)·
#   Team(조직) 이상 필요. Free 플랜 + private에서는 API 생성이 성공하고
#   enforcement=active로 조회되지만 실제로는 집행되지 않는다(Settings > Rules
#   상단 배너로만 고지). 이 스크립트는 마지막에 그 조합을 감지해 경고한다.
#   실습 리포에는 시크릿이 없으므로 Free 플랜이면 리포를 public으로 두는 것을 권장.
#
# 적용 규칙:
#   - pull_request: 승인 0 + code-owner 리뷰 필수 + push 시 stale 리뷰 dismiss
#     (승인 카운트가 0이라 무소유 경로 PR은 승인 없이 통과하고, 소유 경로만
#      require_code_owner_review에 걸린다 — CODEOWNERS 헤더의 auto vs human 설계)
#   - required_status_checks: "guard" (strict=up-to-date)
#   - non_fast_forward(force push 금지) + deletion(브랜치 삭제 금지)
#   - bypass: repo admin(수강생)은 우회 가능(레거시 enforce_admins=false와 동일한
#     escape hatch). 실팀이면 bypass_actors를 비운다.
#
# 멱등: 같은 이름의 ruleset이 있으면 PUT으로 갱신, 없으면 POST로 생성.
#
# 전제조건: repo admin으로 인증된 gh CLI.

set -euo pipefail

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated - run 'gh auth login'" >&2; exit 1; }

REPO_FULL="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

# dev surface auto 경로(auto-merge.yml의 `gh pr merge --auto`)가 동작하려면 repo 설정의
# "Allow auto-merge"가 켜져 있어야 한다. template으로 생성한 repo는 이 설정을 상속하지
# 않으므로 여기서 멱등하게 켠다 — 안 켜면 봇 PR의 auto-merge 활성화가 즉시 실패한다.
echo "Enabling repo setting: allow_auto_merge"
gh api --method PATCH "repos/${REPO_FULL}" -F allow_auto_merge=true >/dev/null

# 브랜치=환경 매핑: dev 브랜치(→2-1-dev apply)가 없으면 main에서 만든다.
# 이 경로는 비상용 fallback — dev 브랜치엔 CODEOWNERS의 dev 전용 사본(modules/·
# 2-1-dev/·ansible/ 소유 해제 블록)이 있어야 하는데, main에서 만든 dev엔 그 블록이
# 없다. 정상 경로는 리포 생성 시 --include-all-branches로 template의 dev를 복사하는 것.
if ! gh api "repos/${REPO_FULL}/git/ref/heads/dev" >/dev/null 2>&1; then
  echo "Creating dev branch from main (branch-per-environment)"
  MAIN_SHA="$(gh api "repos/${REPO_FULL}/git/ref/heads/main" --jq .object.sha)"
  gh api --method POST "repos/${REPO_FULL}/git/refs" \
    -f ref=refs/heads/dev -f sha="${MAIN_SHA}" >/dev/null
  cat >&2 <<'MSG'
  ⚠ dev 브랜치를 main 사본으로 새로 만들었다. dev 브랜치 CODEOWNERS에는 dev 전용
    소유 해제 블록(/modules/ /2-1-dev/ /ansible/)이 있어야 에이전트의 dev 코드 PR이
    auto-merge된다 — template의 dev 사본이 아니면 이 블록이 없다.
    확인: git show dev:.github/CODEOWNERS | tail -3
    없으면 template(원본 리포)의 dev 브랜치 CODEOWNERS를 dev에 가져올 것.
MSG
fi

# ruleset payload — main(~DEFAULT_BRANCH)과 dev에 같은 규칙을 건다. dev 브랜치
# push가 곧 2-1-dev apply 경로라서, 룰셋 없이는 PR·guard 없이 dev 환경이 바뀐다.
# require_code_owner_review로 CODEOWNERS를 게이트화(사람 전용 surface 보호).
apply_ruleset() {
  local name="$1" include_ref="$2"
  echo "Applying ruleset '${name}': ${REPO_FULL} (${include_ref})"

  local payload
  payload="$(jq -n --arg name "${name}" --arg include "${include_ref}" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: [$include], exclude: [] } },
    rules: [
      { type: "deletion" },
      { type: "non_fast_forward" },
      { type: "pull_request", parameters: {
          required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: true,
          require_last_push_approval: false,
          required_review_thread_resolution: false
      }},
      { type: "required_status_checks", parameters: {
          strict_required_status_checks_policy: true,
          required_status_checks: [ { context: "guard" } ]
      }}
    ],
    bypass_actors: [
      { actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always" }
    ]
  }')"

  # 기존 ruleset id 조회(멱등 갱신)
  local existing_id
  existing_id="$(gh api "repos/${REPO_FULL}/rulesets" --jq \
    ".[] | select(.name==\"${name}\") | .id" 2>/dev/null | head -1 || true)"

  if [ -n "${existing_id}" ]; then
    echo "updating existing ruleset id=${existing_id}"
    echo "${payload}" | gh api --method PUT "repos/${REPO_FULL}/rulesets/${existing_id}" \
      --header "Accept: application/vnd.github+json" --input - >/dev/null
  else
    echo "creating new ruleset"
    echo "${payload}" | gh api --method POST "repos/${REPO_FULL}/rulesets" \
      --header "Accept: application/vnd.github+json" --input - >/dev/null
  fi
}

apply_ruleset "main-guardrails" "~DEFAULT_BRANCH"
apply_ruleset "dev-guardrails" "refs/heads/dev"

echo ""
echo "OK - ruleset summary:"
gh api "repos/${REPO_FULL}/rulesets" --jq \
  '.[] | select(.name=="main-guardrails" or .name=="dev-guardrails") | {name, enforcement, target, id}'

# 집행 여부 감지 — Free 플랜 + private 리포는 ruleset이 생성만 되고 집행되지 않는다
# (enforcement=active로 조회돼도 미집행, UI 배너로만 고지). API에 "집행 중" 신호가
# 없으므로 visibility + 소유자 플랜으로 판별해 경고한다(destroy_approval.sh와 같은 패턴).
VISIBILITY="$(gh api "repos/${REPO_FULL}" --jq .visibility)"
if [ "${VISIBILITY}" != "public" ]; then
  OWNER="${REPO_FULL%%/*}"
  OWNER_TYPE="$(gh api "repos/${REPO_FULL}" --jq .owner.type)"
  if [ "${OWNER_TYPE}" = "User" ]; then
    PLAN="$(gh api user --jq '.plan.name' 2>/dev/null || echo unknown)"
  else
    PLAN="$(gh api "orgs/${OWNER}" --jq '.plan.name' 2>/dev/null || echo unknown)"
  fi
  case "${PLAN}" in
    pro|team|business|enterprise) ;;
    *) cat >&2 <<MSG

  ⚠ 이 리포는 ${VISIBILITY}이고 소유자 플랜이 '${PLAN}'이다.
    GitHub Free의 private 리포에서는 ruleset이 생성만 되고 집행되지 않는다 —
    guard required check / code-owner 리뷰 / force-push·삭제 금지가 전부 무효다
    (리포 Settings > Rules 상단 배너로 확인 가능).
    해결: (a) 리포를 public으로 전환(권장 — 실습 리포에 시크릿 없음), 또는
          (b) GitHub Pro(개인) / Team(조직) 업그레이드.
MSG
    ;;
  esac
fi
