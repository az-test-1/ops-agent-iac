# 사람이 소유하는 파일 — 에이전트는 *.tf를 절대 수정하면 안 된다.
#
# 2-06 WAF — 존 전역 Cloudflare WAF (2-2-prod 소유, 2026-07-20 통합).
#
# 왜 prod 소유인가: Cloudflare는 존당 http_request_firewall_custom 엔트리포인트
# 룰셋을 1개만 허용한다(2026-07-16 e2e C1-I8 — env마다 룰셋을 만들면 두 번째
# apply가 항상 실패). WAF 수정은 prod에서만 하기로 결정해(2026-07-20) 존 단위
# 별도 디렉터리(구 2-4-waf) 대신 2-2-prod가 존 전역 룰셋을 소유한다. 차단 효과는
# 존 전역 — dev 호스트에도 적용된다.
#
# 에이전트 write surface는 waf.auto.tfvars.json 하나. service_enabled와 무관하게
# 유지된다(서비스 스택을 내려도 차단 룰은 남는다).

locals {
  waf_cloudflare_ready = var.cloudflare_zone_id != "" && nonsensitive(var.cloudflare_api_token != "")
}

# 무료 Cloudflare 존은 rate limit(advanced engine)은 못 만들지만, 커스텀 방화벽 룰의
# 표현식에서 ip.src 매칭은 무료에서 된다 → 특정 IP를 block/챌린지한다. CIDR이면 in {},
# 단일 IP면 eq. path를 주면 그 IP의 그 경로로 좁힌다.
resource "cloudflare_ruleset" "waf" {
  count   = local.waf_cloudflare_ready && length(var.waf_rules) > 0 ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "${var.project}-waf-custom"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  dynamic "rules" {
    for_each = var.waf_rules
    content {
      action = rules.value.action
      description = "waf ${rules.key} (${rules.value.action} ip ${rules.value.ip}${
        rules.value.path != "" ? " path ${rules.value.path}" : ""
      })"
      expression = "(${join(" and ", compact([
        strcontains(rules.value.ip, "/") ? "ip.src in {${rules.value.ip}}" : "ip.src eq ${rules.value.ip}",
        rules.value.path != "" ? "http.request.uri.path eq \"${rules.value.path}\"" : "",
      ]))})"
    }
  }
}
