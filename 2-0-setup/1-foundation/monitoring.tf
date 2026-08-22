# 사람이 소유하는 파일 — 에이전트는 *.tf를 절대 수정하면 안 된다.
#
# 공유 모니터링 스택 + 미사용 리소스 시드 — 2-0-setup(2주차 환경 설정)의
# 일부다. 1주차(1-00 Hermes 호스트)에는 아무것도 필요 없고, 이 스택은 2주차에
# foundation과 함께 apply돼 모든 실습이 공유한다.
#
# t3.small 한 대가 docker compose로 Grafana + Prometheus + Loki + promtail을 돌린다.
# Prometheus는 Name=<project>-*-app-* 로 앱 플릿 인스턴스를 발견한다 — 모든 실습에
# 걸쳐 — 그래서 어떤 실습의 fleet든 뜨면 자동으로 scrape 풀에 합류한다. fleet의
# promtail(ansible/monitoring-agents.yml)은 앱 로그(job=app)를 Loki로 보낸다.
# 이 서버는 인프라(스택 컨테이너 + datasource)만 담당한다. 대시보드는
# 2-0-setup/4-grafana가, 알람 룰 / contact point / notification 정책은
# 2-3-incident-response가 grafana provider로 관리한다 — 서버는 그대로 두고
# 관측 콘텐츠만 재-apply할 수 있다.
# Lambda 없음, 브리지 서버 없음, 딱 EC2 인스턴스 하나.
#
# 여기에 더해: ops_aws_find_unused_candidates 드릴용으로 일부러 놀리는
# 미사용 리소스 시드(미연결 볼륨, 놀고 있는 EIP, 고아 SG, 스냅샷, 미사용 IAM 롤).
# keep 태그가 붙은 볼륨 하나도 포함한다(false-positive 훈련용). 이들은 apply
# 시점에 age 0이라 실제 "N일 미사용 + grace 기간" 휴리스틱은 라이브로 시연할 수
# 없다 — 대신 README가 이를 다룬다.

locals {
  # 모니터링 서버의 Name 태그. 아래 Prometheus relabel 룰이 이 서버를 자기 자신의
  # ec2_sd 발견 대상에서 자연 제외된다(Name 패턴 불일치 — node_exporter도
  # 안 돌림). 특정 실습에 종속되지 않음: 스택은 공유된다.
  monitoring_name = "${local.project}-monitoring-server"
}

# 최신 Ubuntu 24.04 LTS (Noble) x86_64 AMI — Canonical 퍼블릭 SSM 파라미터로 조회
# (AMI 조회일 뿐, 인스턴스 관리에 SSM을 쓰는 것이 아니다).
data "aws_ssm_parameter" "ubuntu2404_x86_64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# --- 모니터링 서버 security group ---------------------------------------
# Grafana(:3000) / Prometheus(:9090) / Loki(:3100)는 trusted IP에서 접근 가능하다
# (자동 감지된 local.trusted_ip). Loki의 push 포트(:3100)는 추가로 실습 VPC CIDR
# 전체에 열려 있어 어떤 실습의 fleet promtail이든 로그를 보낼 수 있다(스택이
# 공유되므로 단일 fleet의 SG를 참조할 수 없다). 사람 접근(SSH 포함)은 인스턴스에
# 함께 부착되는 공유 접근 SG(main.tf, 이름 <project>)가 담당한다.

resource "aws_security_group" "monitoring" {
  name        = "${local.monitoring_name}-sg"
  description = "Shared monitoring stack (Grafana from trusted_ip, Loki push from any app fleet in-VPC)"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.monitoring_name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "grafana" {
  security_group_id = aws_security_group.monitoring.id

  cidr_ipv4   = local.trusted_ip
  from_port   = 3000
  to_port     = 3000
  ip_protocol = "tcp"
  description = "Grafana UI from the trusted IP only"

  tags = { Name = "${local.monitoring_name}-grafana-3000" }
}

# obs-read(Grafana:3000 pull)는 별도 SG 규칙이 필요 없다. Hermes 호스트는 이 루트의
# 같은 VPC + shared SG를 달고 있어(hermes.tf), monitoring private IP:3000에 shared SG의
# self-rule(main.tf)로 직접 닿는다. Grafana UI는 위 grafana 규칙(trusted_ip)으로 수강생
# 브라우저만 접근한다. OPS_GRAFANA_URL은 private IP를 가리킨다(4-grafana ops_grafana_url).

resource "aws_vpc_security_group_ingress_rule" "prometheus" {
  security_group_id = aws_security_group.monitoring.id

  cidr_ipv4   = local.trusted_ip
  from_port   = 9090
  to_port     = 9090
  ip_protocol = "tcp"
  description = "Prometheus UI from the trusted IP only"

  tags = { Name = "${local.monitoring_name}-prometheus-9090" }
}

# Loki는 별도 UI가 없다 — :3100은 HTTP API(/ready, /loki/api/v1/query 등)이며
# Grafana Explore가 주 조회 경로다. trusted IP에서 API 직접 호출용으로만 연다.
resource "aws_vpc_security_group_ingress_rule" "loki_from_trusted" {
  security_group_id = aws_security_group.monitoring.id

  cidr_ipv4   = local.trusted_ip
  from_port   = 3100
  to_port     = 3100
  ip_protocol = "tcp"
  description = "Loki HTTP API from the trusted IP only"

  tags = { Name = "${local.monitoring_name}-loki-3100-trusted" }
}

resource "aws_vpc_security_group_ingress_rule" "loki_from_vpc" {
  security_group_id = aws_security_group.monitoring.id

  cidr_ipv4   = local.vpc_cidr
  from_port   = 3100
  to_port     = 3100
  ip_protocol = "tcp"
  description = "Loki push API from any app fleet promtail (in-VPC only)"

  tags = { Name = "${local.monitoring_name}-loki-3100" }
}

resource "aws_vpc_security_group_egress_rule" "monitoring_all" {
  security_group_id = aws_security_group.monitoring.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
  description = "image pulls, ec2_sd API calls, node_exporter scrapes, webhook posts to Hermes"

  tags = { Name = "${local.monitoring_name}-egress-all" }
}

# --- 모니터링 서버 IAM 롤 ----------------------------------------------
# 접속은 SSH(공유 접근 SG + <project> 키)이므로 SSM 정책은 없다.
# 이 롤의 유일한 용도는 Prometheus ec2_sd가 태그로 fleet 인스턴스를 발견하는 데
# 필요한 read 권한이다.

data "aws_iam_policy_document" "monitoring_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = local.monitoring_name
  description        = "Instance role for the shared monitoring server"
  assume_role_policy = data.aws_iam_policy_document.monitoring_trust.json

  tags = { Name = local.monitoring_name }
}

data "aws_iam_policy_document" "ec2_sd_read" {
  statement {
    sid = "PrometheusEc2ServiceDiscovery"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeAvailabilityZones",
    ]
    resources = ["*"] # 두 액션 모두 리소스 수준 범위 지정을 지원하지 않는다
  }
}

resource "aws_iam_role_policy" "ec2_sd_read" {
  name   = "prometheus-ec2-sd-read"
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.ec2_sd_read.json
}

resource "aws_iam_instance_profile" "monitoring" {
  name = local.monitoring_name
  role = aws_iam_role.monitoring.name
}

# --- 모니터링 서버 user_data ----------------------------------------------
# 부트 스크립트 하나, config management 없음: docker + 고정 버전 compose 플러그인을
# 설치하고, 스택 config 전체(compose 파일, Prometheus config, Grafana
# provisioning)를 쓰고 시작한다. 버전은 일부러 고정했다. 여기서 무엇이든 편집하면
# 인스턴스가 교체된다(user_data_replace_on_change).

locals {
  # 주의: 이 스크립트에 리터럴 "${"를 넣지 말 것 — HCL heredoc이다.
  # 셸 파라미터 확장은 $${VAR}로 쓴다. 남아 있는 ${...}는 전부 의도적인
  # Terraform interpolation이다.
  monitoring_user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    # --- Docker + compose 플러그인 (버전 고정) ---------------------------------
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable --now docker

    COMPOSE_VERSION=2.35.1
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -sSL --retry 3 -o /usr/local/lib/docker/cli-plugins/docker-compose \
      "https://github.com/docker/compose/releases/download/v$${COMPOSE_VERSION}/docker-compose-linux-x86_64"
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose

    mkdir -p /opt/monitoring/grafana/provisioning/datasources

    # --- Grafana root_url ------------------------------------------------
    # 미설정이면 알림(Slack 등) 속 링크(제목·silence)가 localhost:3000으로 렌더링된다.
    # 부팅 시점 공인 IP를 IMDS에서 받아 .env로 넘긴다 — compose가 프로젝트 디렉토리의
    # .env에서 GRAFANA_ROOT_URL을 읽어 컨테이너 env로 주입한다.
    IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
    PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4)
    echo "GRAFANA_ROOT_URL=http://$${PUBLIC_IP}:3000" > /opt/monitoring/.env

    # --- docker compose 스택 ---------------------------------------------
    # Loki는 이미지 기본 config(filesystem 저장, auth 없음)를 유지하고 일부러
    # ephemeral로 둔다 — 실습 로그 히스토리는 컨테이너 재시작을 넘겨 살아남을 필요가
    # 없다. Grafana/Prometheus 데이터는 named volume에 저장된다.
    cat >/opt/monitoring/docker-compose.yml <<'COMPOSE'
    services:
      prometheus:
        image: prom/prometheus:v3.4.1
        restart: unless-stopped
        volumes:
          - /opt/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
          - prometheus-data:/prometheus
        ports:
          - "9090:9090"

      loki:
        image: grafana/loki:3.4.1
        restart: unless-stopped
        ports:
          - "3100:3100"

      # 모니터링 스택 자신의 컨테이너 로그(grafana/loki/prometheus)를 자기 Loki로
      # 적재한다(job=monitoring) — 스택이 이상할 때 SSH 없이 Grafana에서 원인을 본다.
      promtail:
        image: grafana/promtail:3.4.1
        restart: unless-stopped
        depends_on:
          - loki
        volumes:
          - /opt/monitoring/promtail.yaml:/etc/promtail/config.yml:ro
          - /var/lib/docker/containers:/var/lib/docker/containers:ro
          - /var/run/docker.sock:/var/run/docker.sock:ro

      grafana:
        image: grafana/grafana:12.0.2
        restart: unless-stopped
        environment:
          - GF_SERVER_ROOT_URL=$${GRAFANA_ROOT_URL}
        depends_on:
          - prometheus
          - loki
        volumes:
          - /opt/monitoring/grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
          - grafana-data:/var/lib/grafana
        ports:
          - "3000:3000"

    volumes:
      prometheus-data:
      grafana-data:
    COMPOSE

    # --- promtail: 모니터링 스택 컨테이너 로그 -> 로컬 Loki -------------------
    cat >/opt/monitoring/promtail.yaml <<'PTAIL'
    server:
      http_listen_port: 9080

    positions:
      filename: /tmp/positions.yaml

    clients:
      - url: http://loki:3100/loki/api/v1/push

    scrape_configs:
      - job_name: monitoring-stack
        docker_sd_configs:
          - host: unix:///var/run/docker.sock
            refresh_interval: 15s
        relabel_configs:
          - source_labels: ['__meta_docker_container_name']
            regex: '/(.*)'
            target_label: container
          - target_label: job
            replacement: monitoring
    PTAIL

    # --- Prometheus: Name=<project>-*app* 기반 ec2_sd 발견 -------------------
    # 이 프로젝트의 앱 인스턴스(Name에 "app" 포함)를 전부 발견한다(어떤 실습의
    # fleet든 뜨면 자동으로 scrape 풀에 합류). SG가 이 서버의 :9100 접근을 허용한
    # 타깃만 실제로 scrape된다 — 다른 fleet은 "monitoring에서 scrape" SG를 붙이지
    # 않는 한 DOWN으로 표시된다. 자격증명은 instance 롤이다(IMDSv2, 컨테이너가
    # 접근할 수 있게 hop limit 2).
    cat >/opt/monitoring/prometheus.yml <<'PROM'
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ["localhost:9090"]

      - job_name: node
        ec2_sd_configs:
          - region: ${var.aws_region}
            port: 9100
            filters:
              - name: tag:Role
                values: [app]
              - name: instance-state-name
                values: [running]
        relabel_configs:
          # 이 프로젝트의 앱 플릿(Name=<project>-*-app-*)만 발견한다. 모니터링 서버·
          # Hermes 호스트는 이 패턴에 매칭되지 않아 자연히 제외된다(node_exporter 없음).
          - source_labels: [__meta_ec2_tag_Name]
            target_label: name
    PROM

    # --- Grafana datasource ------------------------------------------------
    # uid를 일부러 고정: grafana 디렉터리(observability.tf)의 대시보드·알람이 이 uid를 참조한다.
    cat >/opt/monitoring/grafana/provisioning/datasources/datasources.yaml <<'DS'
    apiVersion: 1

    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true

      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki:3100
    DS

    docker compose -f /opt/monitoring/docker-compose.yml up -d
  EOT
}

# --- 모니터링 서버 인스턴스 -----------------------------------------------

# 고정 public IP: hermes 호스트(.env OPS_GRAFANA_URL)와 수강생 브라우저가 쓰는
# Grafana 주소가 인스턴스 교체에도 바뀌지 않게 한다. 2024-02부터 public IPv4는
# 자동 할당이든 EIP든 동일 과금($0.005/h)이라 attach 상태에서는 추가 비용이 없다
# (인스턴스 stop 중에는 EIP 유휴 과금이 생기는 것만 유의).
resource "aws_eip" "monitoring" {
  domain = "vpc"
  tags   = { Name = "${local.monitoring_name}-eip" }
}

resource "aws_eip_association" "monitoring" {
  instance_id   = aws_instance.monitoring.id
  allocation_id = aws_eip.monitoring.id
}

resource "aws_instance" "monitoring" {
  ami           = data.aws_ssm_parameter.ubuntu2404_x86_64.insecure_value
  instance_type = "t3.small" # 세 컨테이너를 무리 없이 돌리는 가장 작은 타입

  key_name  = aws_key_pair.shared.key_name
  subnet_id = aws_subnet.public[0].id
  # 고정 private IP (10.42.0.10): 실습 플릿이 apply 시점에 굽는 loki_url과
  # grafana 디렉터리 배선이 인스턴스 교체 후에도 그대로 유효하도록 주소를 고정한다.
  # (subnet CIDR의 10번째 호스트 — AWS 예약분 .0~.3/.15 밖)
  private_ip                  = cidrhost(aws_subnet.public[0].cidr_block, 10)
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.monitoring.id, aws_security_group.shared.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name

  # hop limit 2의 IMDSv2: Prometheus 컨테이너가 ec2_sd를 위해 docker 브리지를
  # 통해 instance 롤 자격증명에 접근해야 한다.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # gzip+base64로 압축해 넘긴다(cloud-init이 자동 해제). 대시보드·알람이 grafana 디렉터리로
  # 빠져 user_data는 작아졌지만, 여유를 위해 압축은 유지한다.
  user_data_base64            = base64gzip(local.monitoring_user_data)
  user_data_replace_on_change = true

  # 실습 대상 ansible 실행(tag:Name=<project>-*-app-* 인벤토리)이 이 공유 서버를 절대 건드리지
  # 않도록 별개의 Service 값을 준다. Prometheus ec2_sd는 Name regex로 이 서버를
  # 제외하므로, 메트릭 발견은 이 태그 값의 영향을 받지 않는다.
  tags = {
    Name = local.monitoring_name
  }
}

# --- 미사용 리소스 시드 ------------------------------------------------------
# ops_aws_find_unused_candidates 드릴용으로 일부러 놀리는 리소스.
# 전부 apply 시점에 age 0이라 실제 "N일 이상 미사용 후 grace 기간" 휴리스틱은
# 라이브로 발화할 수 없다 — 도구는 이들을 후보(CANDIDATE)로 보고하고 README가
# age/grace 로직을 설명한다. keep=true 태그가 붙은 볼륨은 도구가 반드시 제외해야
# 한다(false-positive 훈련: keep 태그는 사람이 이미 남겨두기로 결정했다는 뜻).

resource "aws_ebs_volume" "seed_unattached_a" {
  availability_zone = aws_subnet.public[0].availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${local.project}-seed-vol-a" }
}

resource "aws_ebs_volume" "seed_unattached_keep" {
  availability_zone = aws_subnet.public[0].availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.project}-seed-vol-keep"
    keep = "true" # unused-candidates 도구는 keep 태그가 붙은 리소스를 건너뛰어야 한다
  }
}

resource "aws_ebs_snapshot" "seed" {
  volume_id = aws_ebs_volume.seed_unattached_a.id

  tags = { Name = "${local.project}-seed-snapshot" }
}

resource "aws_eip" "seed_idle" {
  domain = "vpc" # 절대 연결 안 함 — 일부러 놀리는 퍼블릭 IPv4로 시간당 ~$0.005 과금됨

  tags = { Name = "${local.project}-seed-eip" }
}

resource "aws_security_group" "seed_orphan" {
  name        = "${local.project}-seed-orphan"
  description = "Deliberately unattached SG (unused-resource seed, never referenced)"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.project}-seed-orphan" }
}

resource "aws_iam_role" "seed_unused" {
  name        = "${local.project}-seed-role"
  description = "Deliberately unused IAM role (unused-resource seed, no policies, never assumed)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${local.project}-seed-role" }
}
