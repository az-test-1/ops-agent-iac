# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
output "alb_dns_name" { value = module.service.alb_dns_name }
output "app_instance_ids" { value = module.service.app_instance_ids }
output "app_name_tag" { value = module.service.app_name_tag }
output "bastion_public_ip" { value = module.service.bastion_public_ip }
output "db_endpoint" { value = module.service.db_endpoint }
output "data_volume_ids" { value = module.service.data_volume_ids }
