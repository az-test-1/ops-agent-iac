# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# app: EC2 ×2(public, 앱) + ALB + RDS(private, PostgreSQL) + Bastion(RDS 접근).
#          service_enabled 게이트로 통째로 뜨고(2-01) 내려간다(2-09).
#
#   인터넷 ──80──▶ ALB ──8080──▶ EC2 ×2(앱, public subnet, AZ 분산) ──5432──▶ RDS(private)
#                                    ▲                              ▲
#                              SSH(2-02)                      bastion(2-03 grant)
#
# 에이전트 표면(각 시나리오):
#   2-02 ec2_ssh_allowlist  → EC2 SG SSH ingress
#   2-03 db_grants          → bastion SSH grant (그다음 psql로 RDS)
#   access_expiry_revocations → 만료된 SSH/RDS 접근 자동 회수
#   2-04 data_volume_size_gb→ EC2 데이터 볼륨 라이브 확대 + ansible growpart
#   2-05 dns_records        → Cloudflare DNS(ALB 연결)
#   2-06 waf는 2-2-prod가 소유(존 전역, prod 전용 — 존당 엔트리포인트 룰셋 1개 제약)

locals {
  project = lower(var.project != "" ? var.project : basename(dirname(abspath(path.root))))
  name    = "${local.project}-${var.environment}"
  enabled = var.service_enabled ? 1 : 0

  # 앱 EC2 대수. ALB 뒤에 2대를 AZ 분산 배치한다(단일 인스턴스 SPOF 제거).
  app_count = var.service_enabled ? 2 : 0
  # 인스턴스 i가 들어갈 public subnet(정렬 후 라운드로빈). 데이터 볼륨 AZ도 여기서
  # 파생한다 — 인스턴스 속성(AZ)을 참조하면 app_version bump로 인스턴스가 교체될 때
  # AZ가 unknown이 되어 볼륨까지 재생성 대상이 되므로 subnet 기준으로 고정한다.
  public_subnet_ids = sort(data.aws_subnets.public.ids)
  app_subnet_ids    = [for i in range(local.app_count) : local.public_subnet_ids[i % length(local.public_subnet_ids)]]

  private_subnet_cidrs = var.private_subnet_cidrs

  # access-expiry는 원본 grant 파일을 삭제하지 않고 tombstone 상태만 갱신한다. 그
  # cidr과 expires_at이 현재 grant와 둘 다 정확히 같을 때만 제외하므로, 사람이 같은
  # 키를 새 CIDR/만료시각으로 수정하면 기존 tombstone은 더 이상 영향을 주지 않는다.
  active_ec2_ssh_allowlist = {
    for k, v in var.ec2_ssh_allowlist : k => v
    if !(try(var.access_expiry_revocations.ec2_ssh_allowlist[k].cidr, null) == v.cidr && try(var.access_expiry_revocations.ec2_ssh_allowlist[k].expires_at, null) == try(v.expires_at, ""))
  }
  active_db_grants = {
    for k, v in var.db_grants : k => v
    if !(try(var.access_expiry_revocations.db_grants[k].cidr, null) == v.cidr && try(var.access_expiry_revocations.db_grants[k].expires_at, null) == try(v.expires_at, ""))
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

data "aws_vpc" "foundation" {
  filter {
    name   = "tag:Name"
    values = [local.project]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.foundation.id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

data "aws_subnet" "chosen" {
  id = sort(data.aws_subnets.public.ids)[0]
}

# 앱 인스턴스별 subnet의 AZ 조회용(데이터 볼륨 AZ 매칭).
data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

data "aws_ssm_parameter" "ubuntu2404_x86_64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_security_group" "shared" {
  name   = local.project
  vpc_id = data.aws_vpc.foundation.id
}

# 모니터링 서버 SG(2-0-setup, <project>-monitoring-server-sg). 별도 디렉터리라 data로
# 조회한다. fleet 서버는 기본으로 이 SG에서 오는 접근을 허용해야 Prometheus가
# node_exporter(:9100)를 scrape할 수 있다(모니터링 서버가 이 SG를 달고 뜬다).
data "aws_security_group" "monitoring" {
  name   = "${local.project}-monitoring-server-sg"
  vpc_id = data.aws_vpc.foundation.id
}

# self-hosted ansible 러너 SG(2-0-setup/1-foundation, <project>-gha-runner). 별도
# 디렉터리라 data로 조회한다. 앱 EC2는 shared SG(runner→22 규칙 포함)를 달고 있어
# 러너가 SSH로 붙지만, bastion은 shared SG가 없다 — rds-temp-user/security-patch가
# bastion에 붙으려면 bastion SG에도 러너 소스 22 규칙이 있어야 한다.
data "aws_security_group" "runner" {
  name   = "${local.project}-gha-runner"
  vpc_id = data.aws_vpc.foundation.id
}

# =============================================================================
# private subnet + RDS subnet group (RDS는 서로 다른 AZ 서브넷 2개 필요)
# =============================================================================
resource "aws_subnet" "private" {
  count                   = local.enabled * length(local.private_subnet_cidrs)
  vpc_id                  = data.aws_vpc.foundation.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-private-${count.index}", Tier = "private" }
}

resource "aws_route_table" "private" {
  count  = local.enabled
  vpc_id = data.aws_vpc.foundation.id
  tags   = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "private" {
  count          = local.enabled * length(local.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

resource "aws_db_subnet_group" "this" {
  count      = local.enabled
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = local.name }
}

# =============================================================================
# Security groups
# =============================================================================
# ALB: 인터넷 80 인바운드
resource "aws_security_group" "alb" {
  count       = local.enabled
  name        = "${local.name}-alb"
  description = "app public ALB"
  vpc_id      = data.aws_vpc.foundation.id
  tags        = { Name = "${local.name}-alb" }
}
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count             = local.enabled
  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP from anywhere"
}
resource "aws_vpc_security_group_egress_rule" "alb_all" {
  count             = local.enabled
  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# EC2(앱): ALB→8080, SSH는 ec2_ssh_allowlist(2-02) + egress all
resource "aws_security_group" "ec2" {
  count       = local.enabled
  name        = "${local.name}-ec2"
  description = "app EC2"
  vpc_id      = data.aws_vpc.foundation.id
  tags        = { Name = "${local.name}-ec2" }
}
resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  count                        = local.enabled
  security_group_id            = aws_security_group.ec2[0].id
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "app port from ALB"
}
resource "aws_vpc_security_group_egress_rule" "ec2_all" {
  count             = local.enabled
  security_group_id = aws_security_group.ec2[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
# fleet 기본값: 모니터링 서버가 node_exporter(:9100)를 바로 scrape할 수 있게 개방.
# (로그 promtail은 fleet→Loki push라 egress로 나가므로 별도 ingress 불필요.)
resource "aws_vpc_security_group_ingress_rule" "ec2_metrics_from_monitoring" {
  count                        = local.enabled
  security_group_id            = aws_security_group.ec2[0].id
  referenced_security_group_id = data.aws_security_group.monitoring.id
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
  description                  = "node_exporter scrape from monitoring server"
}
# 2-02 표면: EC2 SSH 접근
# for_each 키는 논리 이름이 아니라 cidr. 이름만 바뀌면 destroy+create 대신 description
# in-place 변경이 된다 — destroy와 create는 병렬 노드라 같은 내용(cidr+port)의 rule을
# AWS가 InvalidPermission.Duplicate(400)로 거부하는 race가 있다(run 29471699428).
resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  for_each          = var.service_enabled ? { for k, v in local.active_ec2_ssh_allowlist : v.cidr => merge(v, { name = k }) } : {}
  security_group_id = aws_security_group.ec2[0].id
  cidr_ipv4         = each.value.cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = trimspace("SSH ${each.value.name} ${each.value.description}")
}

# Bastion: SSH는 db_grants(2-03) 경유, egress all(→ RDS)
resource "aws_security_group" "bastion" {
  count       = local.enabled
  name        = "${local.name}-bastion"
  description = "app bastion (RDS access). SSH only via db_grants."
  vpc_id      = data.aws_vpc.foundation.id
  tags        = { Name = "${local.name}-bastion" }
}
resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  count             = local.enabled
  security_group_id = aws_security_group.bastion[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
# 2-03 표면: bastion SSH grant (ec2_ssh와 같은 이유로 cidr 키)
resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  for_each          = var.service_enabled ? { for k, v in local.active_db_grants : v.cidr => merge(v, { name = k }) } : {}
  security_group_id = aws_security_group.bastion[0].id
  cidr_ipv4         = each.value.cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "bastion SSH ${each.value.name} until ${each.value.expires_at}"
}
# ansible 러너가 bastion에 SSH로 붙게 한다(rds-temp-user는 bastion 경유, security-patch는
# role_bastion 포함). bastion은 shared SG가 없어 러너 규칙을 별도로 단다.
resource "aws_vpc_security_group_ingress_rule" "bastion_ssh_from_runner" {
  count                        = local.enabled
  security_group_id            = aws_security_group.bastion[0].id
  referenced_security_group_id = data.aws_security_group.runner.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "SSH from the ansible runner (rds-temp-user / security-patch via bastion)"
}

# DB: bastion에서 오는 5432만
resource "aws_security_group" "db" {
  count       = local.enabled
  name        = "${local.name}-db"
  description = "RDS ingress: 5432 from bastion only"
  vpc_id      = data.aws_vpc.foundation.id
  tags        = { Name = "${local.name}-db" }
}
resource "aws_vpc_security_group_ingress_rule" "db_from_bastion" {
  count                        = local.enabled
  security_group_id            = aws_security_group.db[0].id
  referenced_security_group_id = aws_security_group.bastion[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from bastion (2-03 DB access)"
}

# 앱 EC2 → RDS 5432 (앱이 실제로 DB를 쓴다).
resource "aws_vpc_security_group_ingress_rule" "db_from_ec2" {
  count                        = local.enabled
  security_group_id            = aws_security_group.db[0].id
  referenced_security_group_id = aws_security_group.ec2[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from app EC2"
}

# =============================================================================
# EC2 앱 인스턴스 + 데이터 볼륨 + ALB/TG
#
# 무중단 배포(blue-green): 인스턴스가 교체될 때
#   ① 새 인스턴스+볼륨+TG 등록 생성(create_before_destroy — 구 2대는 계속 서빙)
#   ② terraform_data.app_ready 게이트가 새 타겟이 ALB에서 healthy가 될 때까지 대기
#   ③ 게이트 통과 후에야 구 TG 등록 해제 → 구 인스턴스·볼륨 파괴
# 게이트가 실패(새 버전이 healthy 불가)하면 apply가 실패하고 구 2대가 그대로 남는다.
# 트레이드오프: 데이터 볼륨도 인스턴스와 세대교체된다(/data는 bump마다 초기화 —
# 앱은 /data를 쓰지 않고 2-04 실습은 라이브 확장 시연이라 영향 없음). 공유 볼륨
# 유지는 불가능: attachment에 CBD가 강제 전파되어 같은 볼륨 이중 attach로 깨진다.
#
# 교체 트리거: app_version bump → user_data 변경(user_data_replace_on_change).
# ec2_instance_type 변경은 provider 기본 동작(in-place stop/start)을 따른다 — 두 대가
# 병렬로 정지하므로 순단. 무중단 변경은 ansible instance-resize(롤링) 후 tfvars 동기화.
# =============================================================================
resource "aws_instance" "app" {
  count         = local.app_count
  ami           = data.aws_ssm_parameter.ubuntu2404_x86_64.insecure_value
  instance_type = var.ec2_instance_type
  key_name      = local.project
  subnet_id     = local.app_subnet_ids[count.index]

  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.ec2[0].id, data.aws_security_group.shared.id]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # app_version이 user_data의 git clone --branch 태그에 들어간다. replace_on_change로
  # 버전 bump 시 인스턴스를 재생성해야 새 코드가 clone된다 — 없으면 재시작만 되고
  # cloud-init user script는 per-instance라 재실행 안 돼 구버전이 계속 서빙된다.
  user_data                   = local.app_user_data
  user_data_replace_on_change = true

  tags = {
    Name    = "${local.name}-app-${count.index}"
    Service = local.name
    Role    = "app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 독립 데이터 볼륨(2-04): 인스턴스당 1개. size 증가는 terraform 라이브 확대,
# fs는 ansible growpart. AZ는 인스턴스가 아니라 subnet에서 파생(위 locals 참고).
# replace_triggered_by: 인스턴스가 교체되면 볼륨도 함께 세대교체된다(무중단 배포
# 주석 참고). 인스턴스 속성(AZ 등)을 직접 참조하지 않으므로 size-only 변경은
# 여전히 in-place 라이브 확대다.
resource "aws_ebs_volume" "data" {
  count             = local.app_count
  availability_zone = data.aws_subnet.public[local.app_subnet_ids[count.index]].availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${local.name}-data-${count.index}" }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [aws_instance.app[count.index].id]
  }
}
# force_detach: 구세대 볼륨은 서빙 중인 구 인스턴스에서 마운트된 채 강제 분리된다.
# stop_instance_before_detaching을 쓰면 게이트 통과 전에 구 인스턴스가 정지되어
# 무중단이 깨지고, force 없이는 마운트된 볼륨 detach가 영원히 끝나지 않는다.
# 구 볼륨은 어차피 직후 파괴되므로 강제 분리로 인한 데이터 위험은 없다.
resource "aws_volume_attachment" "data" {
  count        = local.app_count
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.data[count.index].id
  instance_id  = aws_instance.app[count.index].id
  force_detach = true

  lifecycle { create_before_destroy = true }
}

resource "aws_lb_target_group" "app" {
  count       = local.enabled
  name        = "${local.name}-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.foundation.id
  target_type = "instance"
  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = { Name = "${local.name}-tg" }
}
resource "aws_lb_target_group_attachment" "app" {
  count            = local.app_count
  target_group_arn = aws_lb_target_group.app[0].arn
  target_id        = aws_instance.app[count.index].id
  port             = 8080

  lifecycle { create_before_destroy = true }
}

# 무중단 배포 게이트: 새 인스턴스가 ALB 타겟으로 healthy가 될 때까지 apply를 멈춘다.
# 이 리소스가 구 TG 등록(aws_lb_target_group_attachment)에 depends_on으로 걸려 있어,
# CBD 순서상 구 등록 해제·구 인스턴스 파괴가 게이트 통과 뒤로 밀린다.
# CI(dflook 컨테이너)에는 aws CLI가 없어 curl --aws-sigv4(env 자격증명)로 조회하고,
# 로컬 apply(aws CLI 존재)에서는 CLI 경로를 쓴다.
resource "terraform_data" "app_ready" {
  count            = local.app_count
  triggers_replace = [aws_instance.app[count.index].id]

  depends_on = [aws_lb_target_group_attachment.app]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      TG_ARN='${aws_lb_target_group.app[0].arn}'
      TARGET_ID='${aws_instance.app[count.index].id}'
      REGION=$(echo "$TG_ARN" | cut -d: -f4)
      DEADLINE=$(( $(date +%s) + 600 ))
      echo "waiting for $TARGET_ID to become healthy in ALB target group..."
      while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        if command -v aws >/dev/null 2>&1; then
          STATE=$(aws elbv2 describe-target-health --region "$REGION" \
            --target-group-arn "$TG_ARN" --targets "Id=$TARGET_ID" \
            --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo unknown)
        else
          if [ -z "$${AWS_ACCESS_KEY_ID:-}" ]; then
            echo "no aws CLI and no env credentials — cannot check target health" >&2
            exit 1
          fi
          # 주의: $${VAR:+-H "..."} 한 줄 확장은 내부 따옴표가 재해석되지 않아
          # 헤더 인자가 조각나므로(서명 깨짐) 배열로 조립한다.
          TOKEN_ARGS=()
          [ -n "$${AWS_SESSION_TOKEN:-}" ] && TOKEN_ARGS=(-H "x-amz-security-token: $AWS_SESSION_TOKEN")
          XML=$(curl -sS "https://elasticloadbalancing.$REGION.amazonaws.com/" \
            --aws-sigv4 "aws:amz:$REGION:elasticloadbalancing" \
            --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
            "$${TOKEN_ARGS[@]}" \
            --data-urlencode "Action=DescribeTargetHealth" \
            --data-urlencode "Version=2015-12-01" \
            --data-urlencode "TargetGroupArn=$TG_ARN" \
            --data-urlencode "Targets.member.1.Id=$TARGET_ID" || true)
          STATE=$(printf '%s' "$XML" | sed -n 's:.*<State>\(.*\)</State>.*:\1:p' | head -1)
        fi
        if [ "$${STATE:-}" = "healthy" ]; then
          echo "target $TARGET_ID is healthy"
          exit 0
        fi
        echo "target $TARGET_ID state=$${STATE:-unknown}, retrying in 15s..."
        sleep 15
      done
      echo "timed out (600s) waiting for $TARGET_ID to become healthy" >&2
      exit 1
    EOT
  }

  lifecycle { create_before_destroy = true }
}
resource "aws_lb" "app" {
  count              = local.enabled
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = data.aws_subnets.public.ids
  tags               = { Name = "${local.name}-alb" }
}
resource "aws_lb_listener" "app" {
  count             = local.enabled
  load_balancer_arn = aws_lb.app[0].arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# =============================================================================
# RDS (private) + Bastion (public)
# =============================================================================
resource "aws_db_instance" "this" {
  count          = local.enabled
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  db_name           = "appdb"
  username          = "dbadmin"

  # 단순화: Secrets Manager 안 쓰고 평문 데모 비밀번호(var.db_password). 앱이
  # user_data로 같은 값을 받아 psycopg2로 직접 붙는다.
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.db[0].id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = { Name = local.name }
}

resource "aws_instance" "bastion" {
  count                  = local.enabled
  ami                    = data.aws_ssm_parameter.ubuntu2404_x86_64.insecure_value
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.chosen.id
  key_name               = local.project
  vpc_security_group_ids = [aws_security_group.bastion[0].id]

  # psql만 설치해 둔다. dev 상시 readonly 계정은 여기서 만들지 않는다 —
  # 세팅 apply 후 ansible(rds-readonly-user)이 생성한다(부팅 1회 user_data는
  # RDS 대기 타임아웃 시 조용히 실패하고 재실행 경로가 없었다, 2026-08-01 이관).
  # prod는 상시 계정 없음(rds-temp-user만)이 계약 — 과거 user_data는 공용
  # module이라 prod bastion에도 readonly를 만들었다.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y postgresql-client
  EOT

  tags = {
    Name = "${local.name}-bastion"
    Role = "bastion"
  }
}
