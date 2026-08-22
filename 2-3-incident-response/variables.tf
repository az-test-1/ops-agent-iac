# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.

variable "project" {
  description = "모든 리소스 이름의 프리픽스. 기본값 \"\"이면 리포 루트 디렉토리 이름을 자동으로 쓴다 — 2-0-setup/1-foundation과 같은 값이어야 모니터링 서버 태그 조회가 맞아떨어진다."
  type        = string
  default     = ""

  validation {
    condition     = var.project == "" || can(regex("^[a-z0-9][a-z0-9-]{1,23}$", var.project))
    error_message = "project는 소문자/숫자/하이픈만, 2~24자여야 한다 (2-0-setup/1-foundation과 동일 규칙)."
  }
}

variable "aws_region" {
  description = "모니터링 서버가 있는 AWS 리전 (2-0-setup/1-foundation과 동일해야 한다)."
  type        = string
  default     = "ap-northeast-2"
}

variable "grafana_auth" {
  description = <<-EOT
    Grafana provider 인증 — "user:password" 형식 또는 admin 권한 API 키.
    기본값은 스택 초기 로그인 값 admin:admin이다. Grafana UI에서 admin 비밀번호를
    바꿨다면 반드시 -var 'grafana_auth=admin:<새 비밀번호>'로 함께 넘겨야 한다.
  EOT
  type        = string
  default     = "admin:admin"
  sensitive   = true
}

# --- Notification 채널 (alerting.tf가 contact point/정책으로 provisioning) ----------
# 예전에는 2-0-setup/3-grafana가 받았지만, "알람이 에이전트/사람에게 도착하는" 배선은
# 이 실습(incident-response)의 주제라 여기로 옮겼다. 전부 기본값 ""이면 해당 채널을 건너뛴다.

variable "slack_webhook_url" {
  description = <<-EOT
    Grafana 알람을 게시할 Slack incoming webhook URL. 설정하면 Grafana가 Slack
    contact point + 개선된 메시지 템플릿(심각도/인스턴스/대응/런북)을 provisioning하고,
    에이전트가 있는 alert 채널로 알람을 올린다. 봇 메시지를 에이전트가 처리하려면
    Hermes 호스트에 SLACK_ALLOW_BOTS=all을 둘 것. ""이면 Slack 라우팅을 건너뛴다.
    일회용 값 사용 — 이 디렉터리의 state에 남는다.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# pagerduty_routing_key 변수는 제거됐다 — Grafana는 PagerDuty로 자동 페이지하지
# 않는다(Slack 단일 통지). 3-1-pagerduty output(routing_key)은 Hermes 플러그인의
# OPS_PAGERDUTY_ROUTING_KEY로 배선돼, 런북 서킷 브레이커의 ops_pagerduty_page_oncall
# (Events API v2)만 온콜을 페이지한다.
