#!/usr/bin/env bash
# hermes 호스트 ~/.hermes/.env 에 붙여넣을 값을 terraform output +
# 4-hermes/.secrets/app.json(6-2 GitHub App 산출물)에서 뽑아 출력한다.
#
#     bash env.sh          # 또는  ./env.sh
#
# 출력된 KEY=VALUE 를 복사해 hermes 호스트의 ~/.hermes/.env 에 붙여넣으면 된다.
# terraform output은 로컬 state만 읽으므로 AWS 자격증명 불필요. foundation·grafana가
# apply돼 있어야 값이 나온다(미apply면 안내 후 종료).
#
# 주의: OPS_GRAFANA_TOKEN 은 실제 비밀값이 그대로 출력된다(복사 목적). 화면 공유 중이면 조심.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out() { terraform -chdir="$here/$1" output -raw "$2" 2>/dev/null || true; }

GURL="$(out 3-grafana ops_grafana_url)"
GPUB="$(out 3-grafana ops_grafana_public_url)"
GTOKEN="$(out 3-grafana ops_grafana_token)"
ROLE="$(out 1-foundation hermes_readonly_role_arn)"

if [ -z "${GURL}${GTOKEN}${ROLE}" ]; then
  echo "출력값 없음 — foundation/grafana를 먼저 apply해야 한다." >&2
  echo "  terraform -chdir=$here/1-foundation apply && terraform -chdir=$here/3-grafana apply" >&2
  exit 1
fi

# GitHub App 값 (6-2 산출물) — 2-github 스크립트를 4-hermes에서 실행했을 때의 산출 경로
APPJSON="$here/4-hermes/.secrets/app.json"
gj() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$APPJSON" "$1" 2>/dev/null || true; }
APP_ID="$(gj app_id)"
INSTALL_ID="$(gj installation_id)"
GH_OWNER="$(gj owner)"
GH_REPO="$(gj repo)"

# ===== 아래를 복사해 hermes ~/.hermes/.env 에 붙여넣기 =====
cat <<ENV
OPS_PROJECT_PREFIX=ops-agent-iac
OPS_GRAFANA_URL=${GURL}
OPS_GRAFANA_PUBLIC_URL=${GPUB}
OPS_GRAFANA_TOKEN=${GTOKEN}
OPS_AWS_READ_ROLE=${ROLE}
ENV

if [ -n "$APP_ID" ] && [ -n "$INSTALL_ID" ] && [ -n "$GH_OWNER" ] && [ -n "$GH_REPO" ]; then
  cat <<ENV
# --- write (6-2 GitHub App 산출물: 4-hermes/.secrets/app.json) ---
OPS_GITHUB_APP_ID=${APP_ID}
OPS_GITHUB_PRIVATE_KEY_PATH=/home/ubuntu/.hermes/app.pem
OPS_GITHUB_INSTALLATION_ID=${INSTALL_ID}
OPS_GITHUB_REPO=${GH_OWNER}/${GH_REPO}
ENV
else
  cat <<'ENV'
# --- write: GitHub App 값 없음 — 6-2(create_github_app.py + print_install_id.py)
#     완료 후 env.sh를 재실행하면 OPS_GITHUB_* 4줄이 채워져 나온다 ---
ENV
fi

cat <<'ENV'
# --- 아래는 산출물이 아님 — UI에서 수동 발급해 채운다 ---
# OPS_CLOUDFLARE_READ_TOKEN=<Cloudflare read token>   # 필수 (dns/waf 조회 + 엣지 5xx; 토큰에 Analytics:Read 포함)
# OPS_CLOUDFLARE_ZONE_ID=<zone id>                    # 필수
# OPS_PAGERDUTY_TOKEN=<PagerDuty full-access key (UI: Integrations > API Access Keys)>  # 선택 (활성 PD 플랜 필요; incident ack/snooze/resolve까지 쓰므로 full-access)
# OPS_PAGERDUTY_FROM_EMAIL=<PD 로그인 이메일>  # incident write의 REST 필수 From 헤더
# OPS_INFRA_SLACK_MENTION=<@Slack user ID>  # prod 삭제 승인 실멘션 — repo variable INFRA_SLACK_MENTION과 동일 값
ENV
