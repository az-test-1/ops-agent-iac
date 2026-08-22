# 3-1-pagerduty — PagerDuty escalation policy·service·integration을 IaC로 관리.
#
# 별도 root 모듈이다: PagerDuty provider는 init 시 토큰을 검증(API 호출)하므로,
# 토큰이 없는 대다수 수강생의 다른 실습 apply를 막지 않도록 분리돼 있다.
# 커리큘럼상 2-3(알람 → 에이전트 대응) 뒤의 실습 — Slack/Hermes 라우팅이 이미
# 도는 상태에서 "런북이 포기한 사건만 페이징"을 얹는다.
#
# 전제: 활성 PagerDuty 플랜이 필요하다. 트라이얼이 만료됐거나 플랜이 없으면
# 정상 발급한 key도 REST API에서 401(빈 body, x-request-id만)을 반환해 init이
# provider 검증에서 실패한다 — 키/헤더 문제가 아니라 계정 구독 tier 문제다.
#
# PagerDuty 계정(활성 플랜)이 있는 경우에만 적용한다. 적용은 CI(main 브랜치)로:
#
#   gh secret set PAGERDUTY_TOKEN            # UI 발급 read/write key (1회)
#   gh variable set PD_ONCALL_EMAIL --body '<본인 PD 로그인 이메일>'
#   gh workflow run tf-apply.yml --ref main -f target=3-1-pagerduty
#
# 이후 이 디렉터리 변경은 main으로의 PR → plan(guard) → 머지 → 자동 apply.
# routing_key 조회(Hermes 플러그인 OPS_PAGERDUTY_ROUTING_KEY 배선용):
#   terraform -chdir=3-1-pagerduty init \
#     -backend-config="bucket=<project>-state-<account>" \
#     -backend-config="key=states/3-1-pagerduty.tfstate" \
#     -backend-config="region=ap-northeast-2" -backend-config="use_lockfile=true"
#   terraform -chdir=3-1-pagerduty output -raw routing_key
#
# 흐름: escalation policy(1차 담당=이메일 사용자) → service → Events API v2
# integration. output routing_key는 Grafana가 아니라 Hermes 플러그인
# (OPS_PAGERDUTY_ROUTING_KEY)에 배선한다 — 알람은 Slack 단일 통지이고, 페이지는
# 에이전트가 런북 서킷 브레이커에서 ops_pagerduty_page_oncall을 호출할 때만 나간다.

data "pagerduty_user" "oncall" {
  email = var.oncall_user_email
}

resource "pagerduty_escalation_policy" "this" {
  name      = "${var.project}-escalation"
  num_loops = 2

  rule {
    escalation_delay_in_minutes = 10
    target {
      type = "user_reference"
      id   = data.pagerduty_user.oncall.id
    }
  }
}

resource "pagerduty_service" "this" {
  name                    = var.project
  description             = "FastCampus IaC app fleet escalations (agent page_oncall -> PagerDuty)"
  escalation_policy       = pagerduty_escalation_policy.this.id
  alert_creation          = "create_alerts_and_incidents"
  auto_resolve_timeout    = 14400 # 4h
  acknowledgement_timeout = 1800  # 30m
}

resource "pagerduty_service_integration" "grafana" {
  # 제네릭 Events API v2 integration. 벤더 참조 대신 type을 쓴다:
  # pagerduty_vendor 데이터소스는 substring 매칭이라 "Events API v2"가
  # "PRTG Notification For PagerDuty Events API v2" 같은 엉뚱한 벤더를 잡는다.
  # 발신자(Hermes 플러그인)는 routing key로 events.pagerduty.com에 POST하므로
  # 벤더는 무의미하다. 리소스 라벨 "grafana"는 배선 이력의 잔재지만 라벨 변경은
  # integration 재생성 = routing key 회전이라 유지한다.
  name    = "ops-agent (Events API v2)"
  service = pagerduty_service.this.id
  type    = "events_api_v2_inbound_integration"
}

output "routing_key" {
  description = "Hermes 플러그인 OPS_PAGERDUTY_ROUTING_KEY에 배선할 Events API v2 routing key (ops_pagerduty_page_oncall 전용)."
  value       = pagerduty_service_integration.grafana.integration_key
  sensitive   = true
}
