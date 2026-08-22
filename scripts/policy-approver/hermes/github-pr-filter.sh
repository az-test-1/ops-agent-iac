#!/usr/bin/env bash
# Webhook route filter for the Hermes-gateway variant of the policy approver.
# stdin: GitHub pull_request payload JSON. stdout: payload to continue with,
# empty output to drop the event (no agent session is started).
#
# This is only the cheap pre-LLM cut — signature (HMAC) was already validated
# by the gateway, and the real verdict is policy_approver.py --check-pr.
# Requires jq on the host.
set -euo pipefail

payload=$(cat)

jq -e '
  (.action == "opened" or .action == "synchronize")
  and (.pull_request.base.ref == "main")
  and ((.pull_request.user.type == "Bot")
       or (.pull_request.user.login | endswith("[bot]")))
  and ((.pull_request.body // "") | contains("alarm_id="))
' >/dev/null 2>&1 <<<"$payload" || exit 0

printf '%s' "$payload"
