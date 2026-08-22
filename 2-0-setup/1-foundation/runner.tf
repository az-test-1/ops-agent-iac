# runner.tf — self-hosted GitHub Actions runner (label: ansible)
#
# ansible를 CI에서 돌리는 컨트롤 노드다. VPC 안에 상주하며, .github/workflows/ansible-ops.yml
# 잡이 runs-on: [self-hosted, ansible]로 여기서 돌면서 리포 루트의
# ansible/ 플레이북(disk-grow.yml / security-patch.yml)을 실행 중인 인스턴스에
# SSH로 붙어 수행한다. (SSM이 아니라 SSH를 쓰는 이 리포 방침을 따른다.)
#
# 러너는 무조건 생성된다(선택 아님). SSM·장수 PAT 안 쓰고, foundation helper가 apply
# 때 등록 토큰과 GitHub OIDC subject prefix를 API에서 읽어 Terraform에 넘긴다:
#   bash 2-0-setup/foundation.sh apply
#   - github_runner_token  — 러너 등록 토큰(~1시간 유효, 필수). PAT를 tfstate에 안 남긴다.
#   - fleet_ssh_private_key — 기본은 ~/.ssh/ops-agent-iac 자동 읽기(다른 키면 -var).
#   러너 EC2 프로비저닝(상시 t3.small, 과금) → 부팅 시 자동 등록. GitHub repo
#   Settings > Actions > Runners에서 label=ansible, status=Idle 확인.
#   주의: 토큰이 user_data에 들어가므로, foundation을 다시 apply하면(새 토큰) 러너가
#   교체되며 재등록된다(항상 등록 상태 유지). 재-apply도 foundation helper를 쓴다.
#
# 보안: ansible-ops.yml은 push(main)/workflow_dispatch/workflow_run만 트리거로 쓴다
# (머지된 코드) — fork PR 코드가 self-hosted 러너에서 실행되지 않는다.

variable "github_runner_token" {
  description = "러너 registration-token(~1시간 유효). 발급: gh api -X POST /repos/<owner>/<repo>/actions/runners/registration-token --jq .token. 필수(default 없음) — apply에 안 넘기면 terraform이 값을 물어본다. 러너는 무조건 생성·등록되며, 장수 PAT를 tfstate에 남기지 않는 방식."
  type        = string
  sensitive   = true
}

variable "fleet_ssh_private_key" {
  description = "러너가 플릿에 SSH할 PRIVATE key. 기본 \"\"이면 ~/.ssh/ops-agent-iac를 자동으로 읽는다(보통 지정 불필요). 다른 키를 쓸 때만 내용을 직접 넘긴다."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  runner_count = 1 # 러너는 무조건 생성(선택 아님). [0] 주소 유지로 기존 state 그대로.
  # 러너가 등록할 대상 repo = owner/name (기존 github_owner + github_repo 변수 재사용).
  runner_repo = "${var.github_owner}/${var.github_repo != "" ? var.github_repo : local.project}"
  # 러너가 플릿에 SSH할 개인키: 기본은 규약 경로(~/.ssh/ops-agent-iac) 자동 읽기,
  # var.fleet_ssh_private_key를 주면 그 값이 우선한다(다른 키/CI 주입용).
  fleet_ssh_private_key = var.fleet_ssh_private_key != "" ? var.fleet_ssh_private_key : file(pathexpand("~/.ssh/ops-agent-iac"))
}

# --- IAM: modify-volume + describe (시크릿은 tf var 주입, SSM 미사용) ---------
data "aws_iam_policy_document" "runner_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  count              = local.runner_count
  name               = "${local.project}-gha-runner"
  assume_role_policy = data.aws_iam_policy_document.runner_trust.json
  tags               = { Name = "${local.project}-gha-runner" }
}

data "aws_iam_policy_document" "runner_policy" {
  # 라이브 볼륨 확대 + 대상 인스턴스/볼륨 조회. Describe*는 resource-level 스코프를
  # 지원하지 않아 "*"다(계정이 데모 전용이라 허용). 시크릿은 SSM이 아니라 tf var로
  # 주입하므로 ssm 권한은 없다. DescribeInstances는 aws_ec2 동적 인벤토리도 쓴다.
  statement {
    sid       = "LiveVolumeGrow"
    actions   = ["ec2:ModifyVolume", "ec2:DescribeVolumes", "ec2:DescribeVolumesModifications", "ec2:DescribeInstances"]
    resources = ["*"]
  }
  # rolling-restart(2-3): TG 드레인 → 재시작 → 복귀. 러너가 localhost aws CLI로
  # elbv2 describe/(de)register/wait(=DescribeTargetHealth)를 호출한다. 이 권한이
  # 없으면 첫 태스크(TG ARN 조회)에서 AccessDenied로 죽는다.
  statement {
    sid = "RollingRestartTargetGroup"
    actions = [
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = ["*"]
  }
  # instance-resize: TG 드레인 후 stop → 타입 변경 → start를 러너 aws CLI로 수행한다.
  # 타입 허용목록(t3.micro|t3.small)은 workflow choice input과 플레이북 assert가
  # 강제한다. Describe와 같은 이유로 "*"(데모 전용 계정).
  statement {
    sid       = "InstanceResize"
    actions   = ["ec2:StopInstances", "ec2:StartInstances", "ec2:ModifyInstanceAttribute"]
    resources = ["*"]
  }
  # rds-temp-user(2-03): ansible-ops.yml이 러너에서 RDS 엔드포인트를 describe해
  # bastion에 넘긴다(유저 발급 자체는 psql). describe만 필요.
  statement {
    sid       = "RdsEndpointLookup"
    actions   = ["rds:DescribeDBInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "runner" {
  count  = local.runner_count
  name   = "${local.project}-gha-runner"
  role   = aws_iam_role.runner[0].id
  policy = data.aws_iam_policy_document.runner_policy.json
}

resource "aws_iam_instance_profile" "runner" {
  count = local.runner_count
  name  = "${local.project}-gha-runner"
  role  = aws_iam_role.runner[0].name
}

# --- SG: 러너는 아웃바운드만(SSH out to fleet, HTTPS out to GitHub/AWS) --------
resource "aws_security_group" "runner" {
  count       = local.runner_count
  name        = "${local.project}-gha-runner"
  description = "Self-hosted ansible runner - egress only (initiates SSH to fleet)"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.project}-gha-runner" }
}

resource "aws_vpc_security_group_egress_rule" "runner_all" {
  count             = local.runner_count
  security_group_id = aws_security_group.runner[0].id
  description       = "all egress (SSH to fleet, HTTPS to GitHub/AWS)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# 플릿(공유 접근 SG)에 러너 SG 소스로 SSH(22)를 연다 — 러너가 앱 인스턴스에
# ansible로 붙을 수 있게. (공유 SG는 원래 trusted IP만 허용하므로 추가 규칙.)
resource "aws_vpc_security_group_ingress_rule" "fleet_ssh_from_runner" {
  count                        = local.runner_count
  security_group_id            = aws_security_group.shared.id
  description                  = "SSH from the ansible runner (live disk-grow / patch)"
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.runner[0].id
}

# --- 러너 인스턴스 -----------------------------------------------------------
resource "aws_instance" "runner" {
  count         = local.runner_count
  ami           = data.aws_ssm_parameter.ubuntu2404_x86_64.insecure_value
  instance_type = "t3.small"
  key_name      = aws_key_pair.shared.key_name
  subnet_id     = aws_subnet.public[0].id

  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.runner[0].id, aws_security_group.shared.id]
  iam_instance_profile        = aws_iam_instance_profile.runner[0].name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_base64            = base64gzip(local.runner_user_data)
  user_data_replace_on_change = true

  tags = { Name = "${local.project}-gha-runner" }
}

locals {
  runner_user_data = <<-EOT
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ansible jq curl git unzip python3-boto3 python3-botocore
    # aws CLI v2 (Ubuntu 24.04 noble엔 awscli apt 패키지 없음 — 공식 인스톨러)
    curl -sSL --retry 3 -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/awscliv2.zip /tmp/aws
    # aws_ec2 동적 인벤토리 + AWS 모듈용 컬렉션
    sudo -u ubuntu ansible-galaxy collection install amazon.aws >/dev/null 2>&1 || true

    REPO="${local.runner_repo}"

    # <project> SSH 개인키를 tf var로 주입(base64로 안전 전달). -x 로그에 키가
    # 찍히지 않게 set +x로 감싼다.
    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    set +x
    echo "${base64encode(local.fleet_ssh_private_key)}" | base64 -d > /home/ubuntu/.ssh/ops-agent-iac
    set -x
    chmod 600 /home/ubuntu/.ssh/ops-agent-iac
    chown ubuntu:ubuntu /home/ubuntu/.ssh/ops-agent-iac

    # GitHub Actions 최신 stable 러너 설치. 새 호스트가 오래된 고정 버전을 다시
    # 설치하지 않도록 공식 releases API의 latest tag를 부팅 시점에 해석한다.
    RUNNER_TAG="$(curl -fsSL --retry 3 \
      https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name')"
    case "$${RUNNER_TAG}" in
      v[0-9]*.[0-9]*.[0-9]*) ;;
      *) echo "GitHub Actions runner latest tag 확인 실패: $${RUNNER_TAG}" >&2; exit 1 ;;
    esac
    RUNNER_VER="$${RUNNER_TAG#v}"
    install -d -o ubuntu -g ubuntu /opt/actions-runner
    cd /opt/actions-runner
    curl -fsSL --retry 3 -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v$${RUNNER_VER}/actions-runner-linux-x64-$${RUNNER_VER}.tar.gz"
    tar xzf runner.tar.gz
    chown -R ubuntu:ubuntu /opt/actions-runner

    # 등록 토큰(tf var, gh로 발급)으로 unattended 등록(label: ansible).
    # 토큰이 비면 등록을 건너뛴다(러너는 설치됨). -x 로그 마스킹.
    set +x
    REG_TOKEN="${var.github_runner_token}"
    if [ -n "$REG_TOKEN" ]; then
      sudo -u ubuntu ./config.sh --unattended --replace \
        --url "https://github.com/$${REPO}" \
        --token "$${REG_TOKEN}" \
        --name "$(hostname)-ansible" \
        --labels ansible \
        --work _work
      set -x
      ./svc.sh install ubuntu
      ./svc.sh start
    else
      set -x
      echo "github_runner_token 비어 있음 — gh로 발급해 -var로 넘길 것"
    fi
  EOT
}

output "gha_runner_public_ip" {
  description = "Public IP of the self-hosted GitHub Actions (ansible) runner (SSH debug)."
  value       = local.runner_count > 0 ? aws_instance.runner[0].public_ip : null
}
