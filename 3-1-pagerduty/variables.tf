# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
variable "project" {
  description = "리소스 이름 프리픽스 (2-0-setup/1-foundation과 동일하게)."
  type        = string
  default     = "ops-agent-iac"
}

variable "oncall_user_email" {
  # CI에서는 repo variable PD_ONCALL_EMAIL이 TF_VAR_oncall_user_email로 주입된다 —
  # 개인 이메일을 리포에 커밋하지 않기 위한 경계(INFRA_SLACK_MENTION과 같은 패턴).
  description = "escalation policy 1차 담당자 이메일 (기존 PagerDuty 사용자 로그인 이메일)."
  type        = string
}
