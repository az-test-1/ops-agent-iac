# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.

output "ops_grafana_url" {
  description = "~/.hermes/.env의 OPS_GRAFANA_URL 값. obs-read는 같은 VPC private IP로 Grafana를 pull한다(공인 IP hairpin·SG 수동 개방 불필요). 수강생 브라우저 접속용 공인 URL은 1-foundation의 grafana_url output."
  value       = "http://${data.aws_instance.monitoring.private_ip}:3000"
}

output "ops_grafana_public_url" {
  description = "~/.hermes/.env의 OPS_GRAFANA_PUBLIC_URL 값. 에이전트 응답에 인용되는 dashboard 링크의 base — private IP 링크는 수강생 브라우저에서 안 열린다(접근은 여전히 var.trusted_ip로 제한)."
  value       = "http://${data.aws_instance.monitoring.public_ip}:3000"
}

output "ops_grafana_token" {
  description = "~/.hermes/.env의 OPS_GRAFANA_TOKEN 값(Editor SA 토큰 — 조회 + 알람 silence). `terraform output -raw ops_grafana_token`으로 꺼낸다. 주의: 로컬 tfstate에 평문으로 저장된다 — state 파일을 커밋/공유하지 말 것(.gitignore가 이미 막는다)."
  value       = grafana_service_account_token.hermes_read.key
  sensitive   = true
}
