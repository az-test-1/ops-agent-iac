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
    이 값은 SA "생성"에만 쓰이는 admin 자격증명이고, 플러그인에 들어가는 것은
    output의 read-only SA 토큰이다 — admin 비밀번호를 .env에 넣지 말 것.
  EOT
  type        = string
  default     = "admin:admin"
  sensitive   = true
}

# Notification 채널 변수(slack_webhook_url)는 알람 룰·contact point·notification
# 정책과 함께 2-3-incident-response로 옮겼다 (Slack 단일 통지 — PD 자동 페이지 없음).
