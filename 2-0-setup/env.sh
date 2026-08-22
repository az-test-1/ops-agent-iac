#!/usr/bin/env bash
# hermes 호스트 ~/.hermes/.env 에 붙여넣을 기본 값을 terraform output +
# 2-github/.secrets/app.json(6-2 GitHub App 산출물)에서 뽑아 출력한다.
#
#     bash env.sh          # 또는  ./env.sh
#
# 출력된 KEY=VALUE 를 복사해 hermes 호스트의 ~/.hermes/.env 에 붙여넣으면 된다.
# terraform output은 로컬 state만 읽으므로 AWS 자격증명 불필요. foundation이
# apply돼 있어야 AWS read role 값이 나온다(미apply면 안내 후 종료).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out() { terraform -chdir="$here/$1" output -raw "$2" 2>/dev/null || true; }

ROLE="$(out 1-foundation hermes_readonly_role_arn)"

if [ -z "${ROLE}" ]; then
  echo "출력값 없음 — foundation을 먼저 apply해야 한다." >&2
  echo "  terraform -chdir=$here/1-foundation apply" >&2
  exit 1
fi

# GitHub App 값 (6-2 산출물). create_github_app.py 를 리포 루트에서 돌리면
# <repo>/.secrets, 문서대로 2-github 에서 돌리면 2-github/.secrets 에 생긴다 —
# 어디서 실행했든 찾히도록 두 위치를 순서대로 탐색한다.
APPJSON=""
for cand in "$here/../.secrets/app.json" "$here/2-github/.secrets/app.json"; do
  [ -f "$cand" ] && { APPJSON="$cand"; break; }
done
gj() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$APPJSON" "$1" 2>/dev/null || true; }
APP_ID="$(gj app_id)"
INSTALL_ID="$(gj installation_id)"
GH_OWNER="$(gj owner)"
GH_REPO="$(gj repo)"

# ===== 아래를 복사해 hermes ~/.hermes/.env 에 붙여넣기 =====
cat <<ENV
OPS_PROJECT_PREFIX=ops-agent-iac
OPS_AWS_READ_ROLE=${ROLE}
ENV

if [ -n "$APP_ID" ] && [ -n "$INSTALL_ID" ] && [ -n "$GH_OWNER" ] && [ -n "$GH_REPO" ]; then
  cat <<ENV
# --- write (6-2 GitHub App 산출물: ${APPJSON}) ---
OPS_GITHUB_APP_ID=${APP_ID}
OPS_GITHUB_PRIVATE_KEY_PATH=/home/ubuntu/.hermes/app.pem
OPS_GITHUB_INSTALLATION_ID=${INSTALL_ID}
OPS_GITHUB_REPO=${GH_OWNER}/${GH_REPO}
ENV
else
  cat <<'ENV'
# --- write: GitHub App 값 없음(6-2 미완료). 아래를 2-github 디렉토리에서 순서대로
#     실행한 뒤 이 스크립트를 재실행하면 OPS_GITHUB_* 4줄이 채워져 나온다:
#       cd 2-0-setup/2-github
#       python3 create_github_app.py   # 브라우저에서 앱 생성 -> 리포에 Install
#       python3 print_install_id.py    # 설치 후 실행 (PyJWT 필요)
#       cd - >/dev/null && bash 2-0-setup/env.sh   # 4줄 확인
# --- ---
ENV
fi
