#!/usr/bin/env bash
# grafana-check.sh — 모니터링 상태 확인(read-only)을 service account 토큰으로 수행.
# 대시보드·알람은 IaC, 확인은 이 토큰(Editor)으로 — admin 불필요.
# 토큰: cd 2-0-setup/4-grafana && terraform output -raw ops_grafana_token
#   GRAFANA=http://<ip>:3000 GRAFANA_TOKEN=<위 토큰> bash scripts/grafana-check.sh
set -euo pipefail
GRAFANA="${GRAFANA:-http://localhost:3000}"
if [ -n "${GRAFANA_TOKEN:-}" ]; then A=(-H "Authorization: Bearer ${GRAFANA_TOKEN}")
else A=(-u "${GRAFANA_AUTH:-admin:admin}"); fi
echo "== health =="
curl -s "${A[@]}" "${GRAFANA}/api/health"; echo
echo "== 알람 룰 상태 =="
curl -s "${A[@]}" "${GRAFANA}/api/prometheus/grafana/api/v1/rules" | python3 -c '
import sys,json
for g in json.load(sys.stdin).get("data",{}).get("groups",[]):
  for r in g.get("rules",[]): print(" ", r.get("state","?"), "|", r.get("name"))'
echo "== 활성 사일런스 =="
curl -s "${A[@]}" "${GRAFANA}/api/alertmanager/grafana/api/v2/silences" | python3 -c '
import sys,json
xs=[s for s in json.load(sys.stdin) if s.get("status",{}).get("state")=="active"]
print("  (없음)" if not xs else "")
for s in xs:
  m=", ".join("{}={}".format(x.get("name"),x.get("value")) for x in s.get("matchers",[]))
  print(" ", s.get("id"), "|", m, "| ends", s.get("endsAt"))'
