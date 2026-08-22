# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
output "alb_dns_name" {
  description = "app ALB DNS 이름 — DNS(2-05) content로 쓰고, 브라우저/curl 대상."
  value       = var.service_enabled ? aws_lb.app[0].dns_name : null
}
output "app_instance_ids" {
  description = "앱 EC2 인스턴스 id 목록 — ALB 뒤 2대 (ansible growpart/patch 대상)."
  value       = aws_instance.app[*].id
}
output "app_name_tag" {
  description = "앱 Name 태그 프리픽스(<name>-app-<n>) — ansible/CI는 tag:Role=app으로 대상을 찾는다."
  value       = "${local.name}-app"
}
output "bastion_public_ip" {
  description = "bastion 공인 IP (2-03 grant 후 SSH 대상)."
  value       = var.service_enabled ? aws_instance.bastion[0].public_ip : null
}
output "db_endpoint" {
  description = "RDS 엔드포인트 (bastion에서 psql)."
  value       = var.service_enabled ? aws_db_instance.this[0].address : null
}
output "data_volume_ids" {
  description = "라이브 확대되는 데이터 볼륨 id 목록(인스턴스당 1개)."
  value       = aws_ebs_volume.data[*].id
}
