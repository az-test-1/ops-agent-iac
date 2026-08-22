# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# Hermes 에이전트 호스트 — 실습 전체에 1대. dev/prod 환경 구분은 에이전트가 아니라
# GitHub ruleset/CODEOWNERS의 경로(surface 이름 dev-* / prod-*)로 강제된다. 에이전트는
# 언제나 "PR을 연다"만 하고, dev surface면 자동 머지·prod surface면 사람 승인으로 갈린다.
# 따라서 한 호스트·한 플러그인이 두 환경 surface를 모두 다룬다(툴/스킬 이름 충돌 없음).
# Hermes 설치·키·플러그인 배포·설정은 전부 수동 실습. user_data는 프리앰블만
# (curl+git+gh+aws CLI, python3-pytest는 플러그인 테스트 검증용).
# 접근은 공유 접근 SG(trusted IP)로. read 권한은 <project>-hermes-readonly 롤 assume
# (플러그인 경로, main.tf가 이 호스트 롤을 신뢰). 호스트 롤 자체엔 read 정책이 없다 —
# 박스에서의 ad-hoc CLI 조회도 명시적 assume-role을 거친다(모든 읽기가 감사 이벤트를 남김).

data "aws_iam_policy_document" "hermes_assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hermes" {
  name               = "${local.project}-hermes"
  assume_role_policy = data.aws_iam_policy_document.hermes_assume_ec2.json
  tags               = { Name = "${local.project}-hermes" }
}

# read-only 롤 assume 권한(정확히 그 ARN 하나로 스코프). 플러그인은 이 경로를 쓴다.
data "aws_iam_policy_document" "hermes_assume_readonly" {
  statement {
    sid       = "AssumeHermesReadOnly"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.hermes_readonly.arn]
  }
}

resource "aws_iam_role_policy" "hermes_assume_readonly" {
  name   = "assume-hermes-readonly"
  role   = aws_iam_role.hermes.id
  policy = data.aws_iam_policy_document.hermes_assume_readonly.json
}

resource "aws_iam_instance_profile" "hermes" {
  name = "${local.project}-hermes"
  role = aws_iam_role.hermes.name
}

# 최소 부트스트랩(curl + git + gh)만. Hermes 설치·플러그인·키는 사람이 직접(수동 실습).
# 프로파일 배포와 키·설정(API 키, Slack, config)은 수동 실습 — 프리앰블까지만 자동한다.
resource "aws_instance" "hermes" {
  ami                         = data.aws_ssm_parameter.ubuntu2404_x86_64.insecure_value
  instance_type               = "t3.small" # ~/.hermes state/honcho에 t3.micro는 빠듯
  key_name                    = aws_key_pair.shared.key_name
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.shared.id]
  iam_instance_profile        = aws_iam_instance_profile.hermes.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    # Hermes 설치는 사람이 직접 한다(수동 실습). 여기선 프리앰블(curl+git+gh+aws CLI)만.
    apt-get update -y
    # python3-pytest: 플러그인 테스트 검증(setup-command-guide §7)용 — 플러그인 자체는 stdlib-only.
    apt-get install -y curl git unzip python3-pytest
    # gh는 Ubuntu 기본 repo에 없다 — 공식 GitHub CLI apt repo를 추가하고 설치한다.
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -y
    apt-get install -y gh
    # aws CLI v2 — 공식 인스톨러(docs.aws.amazon.com 기준). Ubuntu엔 apt 패키지 없음.
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws
    echo "${local.project} hermes: run 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash' to install Hermes, then deploy the plugin + keys/config." > /etc/motd
  EOF

  user_data_replace_on_change = true

  tags = {
    Name    = "${local.project}-hermes"
    Service = "hermes-agent"
  }
}

output "hermes_host_public_ip" {
  description = "Hermes 호스트 공인 IP (SSH로 접속해 플러그인·키·config 배포)."
  value       = aws_instance.hermes.public_ip
}

output "hermes_role_arn" {
  description = "Hermes 호스트 인스턴스 롤 ARN (hermes-readonly assume)."
  value       = aws_iam_role.hermes.arn
}
