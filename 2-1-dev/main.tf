# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# 환경 루트 = modules/service 인스턴스. 베이스 인프라 정의는 모듈이 갖고, 여기선
# 환경 델타(env.auto.tfvars: environment / private_subnet_cidrs)와 에이전트
# surface(tfvars)를 넘긴다. dev/prod 루트의 공통 .tf는 동일하고, 구조 차이는
# env.auto.tfvars 델타 + prod 전용 waf.tf(존 전역 WAF — 2026-07-20 통합)뿐이다.

module "service" {
  source = "../modules/service"

  project     = var.project
  environment = var.environment

  # 이 환경 전용 RDS private subnet (VPC 공유 → 겹침 금지). env.auto.tfvars에서 주입.
  private_subnet_cidrs = var.private_subnet_cidrs

  # 에이전트 surface (tfvars → 변수 → 모듈)
  service_enabled     = var.service_enabled
  ec2_instance_type   = var.ec2_instance_type
  db_instance_class   = var.db_instance_class
  ec2_ssh_allowlist   = var.ec2_ssh_allowlist
  db_grants           = var.db_grants
  data_volume_size_gb = var.data_volume_size_gb
  dns_records         = var.dns_records

  # 사람 소유 값
  db_engine_version    = var.db_engine_version
  db_allocated_storage = var.db_allocated_storage
  db_password          = var.db_password
  app_version          = var.app_version
  cloudflare_zone_id   = var.cloudflare_zone_id
  cloudflare_api_token = var.cloudflare_api_token
}
