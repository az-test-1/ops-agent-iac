# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# app = EC2(public) + RDS(private) + Bastion + ALB. 에이전트의 write 표면은
# 아래 *.auto.tfvars(.json) 변수뿐이고, 나머지 인프라는 전부 사람 소유 .tf다.
# 각 표면이 하나의 시나리오다:
#   2-01 service.auto.tfvars        → service_enabled / ec2_instance_type / db_instance_class
#   2-02 ec2-ssh.auto.tfvars.json   → ec2_ssh_allowlist   (EC2 SSH 접근)
#   2-03 db-access.auto.tfvars.json → db_grants           (RDS 접근, bastion 경유)
#   2-04 disk.auto.tfvars           → data_volume_size_gb (EC2 데이터 볼륨, ansible growpart)
#   2-05 dns.auto.tfvars.json       → dns_records         (ALB에 연결)
#   2-06 waf는 2-2-prod가 소유(존 전역, prod 전용 surface — 2026-07-20 결정) — dev surface 아님

variable "project" {
  description = "리소스 이름 프리픽스. 빈 값이면 리포 루트 이름. CI가 PROJECT_NAME 주입."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS 리전. GitHub repo 변수 AWS_REGION과 동기화."
  type        = string
  default     = "ap-northeast-2"
}

# --- 2-01 service.auto.tfvars: 서비스 프로비저닝 게이트 + 사이즈 --------------
variable "service_enabled" {
  description = "app 프로비저닝 게이트. false면 EC2/RDS/Bastion/ALB 아무것도 안 만든다(2-09 삭제 = false 또는 tf-destroy)."
  type        = bool
  default     = true
}

variable "ec2_instance_type" {
  description = "app EC2 인스턴스 타입."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t3.micro", "t3.small"], var.ec2_instance_type)
    error_message = "ec2_instance_type은 t3.micro 또는 t3.small이어야 한다(비용 상한)."
  }
}

variable "db_instance_class" {
  description = "RDS 인스턴스 클래스."
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = contains(["db.t3.micro", "db.t3.small"], var.db_instance_class)
    error_message = "db_instance_class는 db.t3.micro 또는 db.t3.small이어야 한다."
  }
}

# --- 2-02 ec2-ssh.auto.tfvars.json: EC2 SSH 접근 -----------------------------
variable "ec2_ssh_allowlist" {
  description = "EC2에 SSH(22)를 여는 CIDR 맵. 논리 이름 → {cidr}. 기본 default-deny."
  type = map(object({
    cidr        = string
    expires_at  = optional(string, "")
    description = optional(string, "")
  }))
  default = {}

  validation {
    condition = alltrue([
      for g in var.ec2_ssh_allowlist :
      can(cidrhost(g.cidr, 0)) && tonumber(split("/", g.cidr)[1]) >= 24
    ])
    error_message = "모든 ec2_ssh_allowlist cidr은 /24 이상이어야 한다(0.0.0.0/0·넓은 대역 금지)."
  }
  # expires_at이 있으면 반드시 파싱 가능한 ISO8601 UTC여야 한다. 형식이 깨진 값은
  # access-expiry 스윕(expire_access.py)이 회수하지 못해(파싱 실패 시 유지) 사실상
  # 영구 개방이 되므로 plan 시점에 막는다 — db_grants와 동일 기준.
  validation {
    condition = alltrue([
      for g in var.ec2_ssh_allowlist :
      trimspace(g.expires_at) == "" || can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", g.expires_at))
    ])
    error_message = "ec2_ssh_allowlist의 expires_at은 비우거나 ISO8601 UTC(예: 2026-07-15T00:00:00Z) 형식이어야 한다."
  }
}

# --- 2-03 db-access.auto.tfvars.json: RDS 접근(bastion SSH 경유) --------------
variable "db_grants" {
  description = "bastion에 SSH를 여는 임시 grant 맵(그다음 psql로 RDS). 논리 이름 → {cidr, expires_at?}. prod는 expires_at 필수(access-expiry 워크플로가 자동 회수), dev는 상시 접근이라 만료 생략 가능(비면 영구 grant)."
  type = map(object({
    cidr        = string
    expires_at  = optional(string, "")
    description = optional(string, "")
  }))
  default = {}

  # dev는 만료 없는 상시 grant 허용, prod는 expires_at 필수(dev=느슨/prod=엄격).
  # access-expiry 스윕(expire_access.py)은 빈 expires_at을 영구 grant로 보고 유지한다.
  validation {
    condition = alltrue([
      for g in var.db_grants :
      can(cidrhost(g.cidr, 0)) && (var.environment != "prod" || trimspace(g.expires_at) != "")
    ])
    error_message = "모든 db_grants는 유효한 cidr을 요구하고, prod에서는 비어있지 않은 expires_at(ISO8601 UTC)도 필수다."
  }
  # expires_at이 있으면 반드시 파싱 가능한 ISO8601 UTC여야 한다. 형식이 깨진 값은
  # access-expiry 스윕이 회수하지 못해(파싱 실패 시 유지) 사실상 영구 grant가 되므로
  # plan 시점에 막는다. 빈 값(dev 영구 grant)은 위 규칙에서 이미 허용/거부된다.
  validation {
    condition = alltrue([
      for g in var.db_grants :
      trimspace(g.expires_at) == "" || can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", g.expires_at))
    ])
    error_message = "db_grants의 expires_at은 ISO8601 UTC(예: 2026-07-15T00:00:00Z) 형식이어야 한다."
  }
}

# --- 2-04 disk.auto.tfvars: EC2 데이터 볼륨 크기 -----------------------------
variable "data_volume_size_gb" {
  description = "EC2에 붙는 독립 데이터 볼륨 크기(GiB). 올리면 terraform이 EBS를 라이브 확대(교체 없음), ansible growpart가 파일시스템 확장."
  type        = number
  default     = 10

  validation {
    condition     = var.data_volume_size_gb >= 1 && var.data_volume_size_gb <= 100
    error_message = "data_volume_size_gb는 1..100 GiB."
  }
}

# --- 2-05 dns.auto.tfvars.json: DNS 레코드(ALB 연결) -------------------------
variable "dns_records" {
  description = "Cloudflare DNS 레코드 맵. 논리 이름 → {type, name, content}. ALB에 연결하려면 CNAME + content=ALB DNS."
  type = map(object({
    type    = string
    name    = string
    content = string
    proxied = optional(bool, false)
  }))
  default = {}

  # 다른 surface와 동일하게 값 경계를 plan 시점에 강제한다(guard 게이트). type은
  # enum, name·content는 비어있지 않아야 한다. 에이전트가 임의 타입·빈 레코드를
  # auto-merge로 실제 존에 만들지 못하게 한다.
  validation {
    condition     = alltrue([for r in var.dns_records : contains(["A", "AAAA", "CNAME", "TXT"], r.type)])
    error_message = "dns_records의 type은 A, AAAA, CNAME, TXT 중 하나여야 한다."
  }
  validation {
    condition     = alltrue([for r in var.dns_records : trimspace(r.name) != "" && trimspace(r.content) != ""])
    error_message = "dns_records의 name과 content는 비어 있으면 안 된다."
  }
}


# --- 사람 소유(에이전트 표면 아님) ------------------------------------------
variable "db_engine_version" {
  type    = string
  default = "16"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_password" {
  description = "RDS master 비밀번호(단순화 — Secrets Manager 미사용). 데모 편의값. CI는 repo secret에서 TF_VAR_db_password로 주입 가능."
  type        = string
  default     = "AppDemoPw2026!"
  sensitive   = true
}

variable "app_version" {
  description = "앱 코드 리포(wo-o/ops-agent-app)에서 clone할 git 태그. 브랜치가 아닌 태그 pin으로 부팅 재현성 확보."
  type        = string
  default     = "v6"

  validation {
    condition     = can(regex("^v[0-9]+$", var.app_version))
    error_message = "app_version은 릴리스 태그여야 한다(예: v1, v2). 브랜치명 금지 — 재현성 위해 태그 pin."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id (2-05 DNS / 2-06 WAF — 실습 필수 단계). dev/prod env.auto.tfvars에 항상 설정한다. 미설정 시 리소스 0으로 plan만 통과하는 fail-closed는 배선 실패 대비 안전장치."
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API 토큰(2-05 DNS / 2-06 WAF — 실습 필수). GitHub secret CLOUDFLARE_API_TOKEN을 반드시 설정하면 CI가 TF_VAR_cloudflare_api_token으로 주입한다. 미설정 시 리소스 0(count/for_each=0)이라 apply가 깨지지 않는 fail-closed는 배선 실패 대비 안전장치. 값이 있으면 실제 Cloudflare에 반영."
  type        = string
  default     = ""
  sensitive   = true
}

# --- 환경 델타 (env.auto.tfvars가 주입 — dev/prod 유일한 구조 차이) -----------
variable "environment" {
  description = "환경 이름(dev/prod). env.auto.tfvars에서 주입."
  type        = string
}

variable "private_subnet_cidrs" {
  description = "이 환경 전용 RDS private subnet CIDR 2개. dev/prod가 VPC를 공유하므로 겹치면 안 된다."
  type        = list(string)
}
