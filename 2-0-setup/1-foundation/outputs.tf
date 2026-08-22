# 사람이 소유하는 파일 — 에이전트는 *.tf를 절대 수정하면 안 된다.

output "account_id" {
  description = "모든 것이 부트스트랩된 AWS 계정 ID. 이 값을 GitHub 리포 변수 AWS_ACCOUNT_ID로 설정한다."
  value       = data.aws_caller_identity.current.account_id
}

output "state_bucket_name" {
  description = "CI가 모든 실습 루트의 backend로 주입하는 S3 버킷(key states/<dir>.tfstate, use_lockfile=true). 이 루트가 아니라 2-0-setup/0-bootstrap.sh가 생성한다."
  value       = "${local.project}-state-${data.aws_caller_identity.current.account_id}"
}

output "shared_key_name" {
  description = "모든 실습 EC2에 부착되는 SSH key pair 이름(<project>). 실습 루트는 이름 규약으로 참조한다."
  value       = aws_key_pair.shared.key_name
}

output "shared_sg_id" {
  description = "trusted IP에서만 전체 허용하는 공유 SG. 실습 루트는 tag:Name=<project>로 조회해 인스턴스에 부착한다."
  value       = aws_security_group.shared.id
}

output "allowed_ip" {
  description = "공유 접근 SG·Grafana가 허용하는 유일한 소스 CIDR(자동 감지 또는 var.trusted_ip). SSH가 안 되면 현재 IP와 비교 — 다르면 이 루트 재-apply."
  value       = local.trusted_ip
}

output "vpc_id" {
  description = "실습 VPC(10.42.0.0/16). 실습 루트는 ID가 아니라 tag:Name=<project>로 조회한다."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 2개(AZ 분산). 실습 루트는 tag:Project=<project> + tag:Tier=public로 조회한다."
  value       = aws_subnet.public[*].id
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider(token.actions.githubusercontent.com)."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arn" {
  description = "<project>-plan — PR plan(pull_request sub, ReadOnlyAccess)."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "<project>-apply — main 브랜치 apply, 비-prod destroy."
  value       = aws_iam_role.apply.arn
}

output "hermes_readonly_role_arn" {
  description = "<project>-hermes-readonly — ops 플러그인이 assume하는 read 경계 롤 ARN. ~/.hermes/.env의 OPS_AWS_READ_ROLE에 넣는다."
  value       = aws_iam_role.hermes_readonly.arn
}

# --- 공유 모니터링 스택 (monitoring.tf) ----------------------------------

output "monitoring_private_ip" {
  description = "공유 모니터링 서버의 프라이빗 IP. 실습 루트는 이 output을 직접 소비하지 않고 tag:Name=<project>-monitoring-server로 조회한다."
  value       = aws_instance.monitoring.private_ip
}

output "monitoring_public_ip" {
  description = "공유 모니터링 서버의 퍼블릭 IP(이 IP의 Grafana는 var.trusted_ip에서만 접근 가능)."
  value       = aws_eip.monitoring.public_ip
}

output "grafana_url" {
  description = "Grafana UI(var.trusted_ip에서만 접근 가능; 기본 로그인 admin/admin — 최초 로그인 시 반드시 변경할 것)."
  value       = "http://${aws_eip.monitoring.public_ip}:3000"
}

output "loki_push_url" {
  description = "각 실습 fleet의 promtail이 앱 로그(job=app)를 보내는 Loki push 엔드포인트(프라이빗, VPC 내부)."
  value       = "http://${aws_instance.monitoring.private_ip}:3100/loki/api/v1/push"
}
