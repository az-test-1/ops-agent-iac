#!/usr/bin/env bash
# daily-cost-report.sh — 어제 하루 AWS 비용을 서비스별로 조회해 리포트를 출력한다.
#
# 실습 대조용(no-agent 버전): hermes cron 한 줄("매일 AWS 비용을 조회해 비용
# 리포트를 작성해.")이 대신하는 일을 에이전트 없이 직접 구현한 것. 매일 돌리려면
# cron/launchd 등록이 따로 필요하고, Slack 전송까지 하려면 webhook 연동을 더
# 붙여야 한다.
#
#   로컬:          AWS_PROFILE=<profile> bash daily-cost-report.sh
#   Hermes 호스트: bash daily-cost-report.sh  (readonly 롤 자동 assume)
set -euo pipefail

# Hermes 호스트의 instance role(<project>-hermes)에는 CE 권한이 없다 —
# <project>-hermes-readonly를 assume해야 한다. OPS_AWS_READ_ROLE(~/.hermes/.env)이
# 있으면 그걸 쓰고, 없으면 caller가 *-hermes assumed-role일 때 자동 유도한다.
# 로컬(SSO 프로필 등)에서는 둘 다 해당 없어 그대로 직접 호출한다.
ROLE_ARN="${OPS_AWS_READ_ROLE:-}"
if [[ -z "$ROLE_ARN" ]]; then
  IDENTITY="$(aws sts get-caller-identity --query Arn --output text)"
  if [[ "$IDENTITY" == *":assumed-role/"*"-hermes/"* ]]; then
    ACCOUNT="${IDENTITY#arn:aws:sts::}"; ACCOUNT="${ACCOUNT%%:*}"
    NAME="${IDENTITY##*assumed-role/}"; NAME="${NAME%%/*}"
    ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${NAME}-readonly"
  fi
fi
if [[ -n "$ROLE_ARN" ]]; then
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
    aws sts assume-role --role-arn "$ROLE_ARN" \
      --role-session-name daily-cost-report \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text
  )
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
fi

# macOS(BSD date)와 Linux(GNU date) 겸용
START="$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)"
END="$(date +%F)"

# 크레딧이 있는 계정은 UnblendedCost가 서비스별로 상쇄되어 전부 ~0으로 보인다.
# SERVICE × RECORD_TYPE 이중 그룹핑으로 한 번에 조회한 뒤 사용액/크레딧을
# 분리해서 보여준다.
aws ce get-cost-and-usage \
  --time-period "Start=${START},End=${END}" \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE Type=DIMENSION,Key=RECORD_TYPE \
  | jq -r '
      def usd: . * 100 | round / 100;
      def rows: sort_by((.Metrics.UnblendedCost.Amount | tonumber) | if . < 0 then . else -. end)
        | .[]
        | (.Metrics.UnblendedCost.Amount | tonumber) as $amt
        | select(($amt | if . < 0 then -. else . end) >= 0.005)
        | "  \($amt | usd | tostring | .[0:8])\tUSD\t\(.Keys[0])";
      .ResultsByTime[0] as $day
      | ($day.Groups | map(select(.Keys[1] == "Credit" or .Keys[1] == "Refund"))) as $credits
      | ($day.Groups - $credits) as $usage
      | ($usage   | map(.Metrics.UnblendedCost.Amount | tonumber) | add // 0) as $u
      | ($credits | map(.Metrics.UnblendedCost.Amount | tonumber) | add // 0) as $c
      | "AWS 비용 리포트 (\($day.TimePeriod.Start))",
        "사용액:   \($u | usd) USD",
        (if ($credits | length) > 0 then
          "크레딧:   \($c | usd) USD",
          "실청구액: \($u + $c | usd) USD"
        else empty end),
        "",
        "[서비스별 사용액]",
        (if ($usage | length) > 0 then ($usage | rows) else "  (없음)" end),
        (if ($credits | length) > 0 then
          "",
          "[서비스별 크레딧]",
          ($credits | rows)
        else empty end)
    '
