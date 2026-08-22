# 환경 델타 — dev/prod 루트에서 유일하게 다른 구조 파일.
# 전체 델타 확인:  diff 2-1-dev/env.auto.tfvars 2-2-prod/env.auto.tfvars
# (에이전트 surface 아님 — CODEOWNERS로 사람 소유. 구조값이라 자동 머지 금지.)
environment          = "prod"
private_subnet_cidrs = ["10.42.160.0/20", "10.42.176.0/20"]

# 2-05 dns / 2-06 waf는 prod에서도 하는 필수 단계다(선택 아님). dev와 같은 Cloudflare
# zone을 쓰므로 값이 동일하다. 값이 비어 있으면 cloudflare_ready=false로 prod의 dns/waf가
# 조용히 no-op된다(app.tf). ⚠ 본인 zone id로 교체:
#   Cloudflare 대시보드 > 도메인 선택 > Overview 우하단 "Zone ID".
cloudflare_zone_id = "49fc3ed1af9740c3832dbfa596052106"
