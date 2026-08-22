# 환경 델타 — dev/prod 루트에서 유일하게 다른 구조 파일.
# 전체 델타 확인:  diff 2-1-dev/env.auto.tfvars 2-2-prod/env.auto.tfvars
# (에이전트 surface 아님 — CODEOWNERS로 사람 소유. 구조값이라 자동 머지 금지.)
environment          = "dev"
private_subnet_cidrs = ["10.42.128.0/20", "10.42.144.0/20"]

# ⚠ 본인 Cloudflare zone id로 교체해야 2-05 dns / 2-06 waf surface가 apply된다.
#   위치: Cloudflare 대시보드 > 도메인 선택 > Overview 우하단 "Zone ID".
#   비워두면 cloudflare_ready=false로 dns/waf가 조용히 no-op된다(app.tf).
cloudflare_zone_id = "49fc3ed1af9740c3832dbfa596052106"
