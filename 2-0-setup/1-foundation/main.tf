# 사람이 소유하는 파일 — 에이전트는 *.tf를 절대 수정하면 안 된다.
#
# 1회성 부트스트랩 루트(사람이 apply, 로컬 state, CI에서는 절대 안 돎):
#
#   1. S3 state 버킷          <project>-state-<account>   (버저닝; TF >= 1.10
#                             네이티브 S3 lockfile — DynamoDB 테이블 없음)
#   2. 공유 접근 프리미티브    key pair <project> + SG <project>
#                             (trusted IP에서만 전체 허용, IP는 apply 시점 자동 감지).
#                             이 리포의 모든 EC2는 SSM이 아니라 이 키+SG로 SSH
#                             접속하고, ansible은 self-hosted gha-runner에서(또는
#                             수강생 Mac에서) 이 키로 SSH 실행한다.
#   3. 네트워크               VPC 10.42.0.0/16, AZ에 걸친 퍼블릭 서브넷 2개, IGW.
#                             NAT gateway 없음(비용): 프라이빗 서브넷 대신 인스턴스에
#                             퍼블릭 IP + 공유 접근 SG 구성을 쓴다.
#   4. GitHub OIDC provider + GitHub Actions 롤 4개. 모든 trust sub 클레임이
#                             StringEquals — 와일드카드 없음. 어떤 job이 어떤 sub를
#                             발급받는지는 GitHub이 결정하므로(이벤트 종류 / protected
#                             environment), 승인 게이트는 단순한 리포 관습이 아니라
#                             IAM 레이어에서 바인딩된다:
#                               <project>-plan        sub=pull_request        ReadOnlyAccess
#                               <project>-apply       sub=ref:refs/heads/{main,dev} PowerUser + prefix 한정 IAM
#   5. <project>-hermes-readonly — ops Hermes 플러그인의 read 경계
#                             (ReadOnlyAccess + Cost Explorer read). trust는 이
#                             루트가 만드는 hermes 호스트 롤 + 수강생 본인의
#                             IAM principal(변수, 선택).
#   6. 공유 모니터링 스택     <project>-monitoring-server t3.small 1대
#                             (Prometheus/Loki/Grafana) + 미사용 리소스 시드
#                             — monitoring.tf 참고.
#   7. Hermes 에이전트 호스트  <project>-hermes (hermes.tf). 실습 전체에 1대 —
#                             dev/prod 구분은 GitHub 경로 거버넌스로 강제(surface 이름).
#   8. self-hosted 러너       <project>-gha-runner (runner.tf) — VPC 내 ansible 실행.
#
# 이 루트는 "GitHub·Terraform·AWS 환경 설정"에서 apply한다. 이 루트가 만드는 EC2는
# 공유 모니터링 서버 1대 + hermes 호스트 1대 + self-hosted ansible 러너다.

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # 모든 리소스 이름의 단일 소스. var.project가 비어 있으면 리포 루트 디렉토리
  # 이름을 쓴다(path.root = <repo>/2-0-setup/1-foundation → 두 단계 위).
  # 2-0-setup/0-bootstrap.sh와 CI(vars.PROJECT_NAME → TF_VAR_project)도 같은 값을 쓴다.
  project = lower(var.project != "" ? var.project : basename(dirname(dirname(abspath(path.root)))))

  # 리포 이름은 runner 등록 대상에 사용한다. OIDC subject는 GitHub 리포 설정에
  # 따라 owner/repo 이름 또는 immutable owner/repo ID를 포함할 수 있으므로 별도
  # var.github_oidc_subject_prefix를 GitHub API에서 읽어 그대로 쓴다.
  github_repo = var.github_repo != "" ? var.github_repo : local.project

  # 고정된 실습 네트워크(설계 상수이지 조정 노브가 아님).
  vpc_cidr            = "10.42.0.0/16"
  public_subnet_cidrs = ["10.42.0.0/20", "10.42.16.0/20"]

  # OIDC sub 클레임. prefix는 아래 API의 sub_claim_prefix가 유일한 정본이다:
  #   gh api repos/$OWNER/$REPO/actions/oidc/customization/sub --jq .sub_claim_prefix
  # 기본 형식 repo:<owner>/<repo>와 immutable-ID 형식
  # repo:<owner>@<id>/<repo>@<id>를 모두 그대로 보존한다. suffix만 여기서 붙여
  # IAM StringEquals가 GitHub이 실제 발급하는 전체 subject와 정확히 일치하게 한다.
  repo_claim       = var.github_oidc_subject_prefix
  sub_pull_request = "${local.repo_claim}:pull_request"
  sub_main_branch  = "${local.repo_claim}:ref:refs/heads/main"
  # 브랜치=환경 매핑: dev 브랜치 push가 2-1-dev를 apply하므로 dev sub도 신뢰한다.
  sub_dev_branch = "${local.repo_claim}:ref:refs/heads/dev"
  # environment를 선언한 잡(tf-destroy의 destroy-approval)은 sub가 ref가 아니라
  # environment:<name>으로 발급된다 — 이 sub를 신뢰에 넣지 않으면 tf-destroy가
  # 항상 AssumeRoleWithWebIdentity에서 죽는다.
  sub_destroy_env      = "${local.repo_claim}:environment:destroy-approval"
  github_oidc_audience = "sts.amazonaws.com"
}

# --- S3: terraform state 버킷 ----------------------------------------------
#
# state 버킷(<project>-state-<account>)은 여기서 만들지 않는다. 이 루트보다
# 먼저 2-0-setup/0-bootstrap.sh가 AWS CLI로 부트스트랩한다. 실습 루트들(2-NN/3-NN)이 첫
# CI apply 때 S3 backend로 이 버킷이 존재해야 하고, 이 루트 자체는 로컬 state를
# 쓰기 때문이다. 모든 실습 루트는 states/<dir>.tfstate 아래에 TF 1.10+ S3 네이티브
# lockfile(DynamoDB 없음)로 state를 저장한다. 없애려면 버전을 비우고 손으로 삭제한다(README).

# --- 공유 접근 프리미티브: SSH key pair + 접근 SG (둘 다 이름 <project>) ----------
#
# 이 리포의 모든 EC2 접속은 SSM이 아니라 SSH다. 실습 루트들(app 플릿,
# 모니터링 서버, gha-runner)은 아래 두 리소스를 이름/태그로 참조해 인스턴스에
# 부착한다:
#   - key pair  <project>   (본인 SSH 공개키)
#   - SG        <project>   (trusted IP에서만 전체 포트 허용)
# ansible은 self-hosted gha-runner(runner.tf)에서 이 키로 SSH 실행한다(수강생
# Mac 직접 실행도 가능). 허용 IP는 1-00-setup과 같은 패턴으로 apply 시점에 자동
# 감지하며, IP가 바뀌면 이 루트만 재-apply하면 모든 인스턴스 접근이 한 번에
# 갱신된다(공유 SG).

data "http" "caller_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  # var.trusted_ip 지정 시 그 값이 우선(예외 상황용), 기본은 자동 감지.
  trusted_ip = var.trusted_ip != "" ? var.trusted_ip : "${chomp(data.http.caller_ip.response_body)}/32"

  # SSH 공개키: 기본은 1주차 규약 경로(~/.ssh/ops-agent-iac.pub)를 직접 읽는다.
  ssh_public_key = var.ssh_public_key != "" ? var.ssh_public_key : trimspace(file(pathexpand("~/.ssh/ops-agent-iac.pub")))
}

resource "aws_key_pair" "shared" {
  key_name   = local.project
  public_key = local.ssh_public_key

  tags = { Name = local.project }
}

# 규칙은 전부 standalone 리소스로 관리한다(inline ingress/egress 금지). inline은
# 목록에 없는 규칙을 apply마다 지우므로, runner.tf의 fleet_ssh_from_runner처럼
# 다른 파일에서 이 SG에 추가한 규칙이 trusted_ip 갱신 apply 때마다 제거된다.
resource "aws_security_group" "shared" {
  name        = local.project
  description = "All traffic from the trusted IP only (SSH + service ports) - shared by every app instance"
  vpc_id      = aws_vpc.this.id

  tags = { Name = local.project }
}

resource "aws_vpc_security_group_ingress_rule" "shared_trusted_all" {
  security_group_id = aws_security_group.shared.id
  description       = "all traffic from the trusted IP only"
  ip_protocol       = "-1"
  cidr_ipv4         = local.trusted_ip
}

# 같은 VPC 안의 실습 인프라(hermes·monitoring·app fleet·runner·bastion)는 이 SG를
# 공유하며 서로 전부 통신한다. obs-read가 monitoring:3000을 private로 pull하고,
# promtail이 Loki:3100에 push하는 등 내부 통신은 실습 내내 상시 필요하므로 항상 열어둔다.
resource "aws_vpc_security_group_ingress_rule" "shared_lab_self" {
  security_group_id            = aws_security_group.shared.id
  description                  = "all traffic between shared-SG lab instances (same VPC)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.shared.id
}

# 아웃바운드 전체 허용. terraform의 aws_security_group은 생성 시 AWS 기본 allow-all
# egress를 제거하므로 명시해야 한다. hermes 호스트는 이 SG만 달고 있어서(모니터링·러너는
# 자기 SG에 egress 있음) 이게 없으면 apt·git·install.sh가 인터넷에 못 나간다.
resource "aws_vpc_security_group_egress_rule" "shared_all" {
  security_group_id = aws_security_group.shared.id
  description       = "all outbound (apt mirrors, github, install scripts)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- 네트워크: VPC + 퍼블릭 서브넷 2개 + IGW (NAT 없음) ---------------------------
#
# 의도적인 비용 중심 모델: map_public_ip_on_launch가 켜진 퍼블릭 서브넷,
# IGW 직결 egress, 인바운드는 security group으로 잠근다(서비스 간 통신은 각 실습의
# 전용 SG, 사람 접근은 위의 공유 접근 SG(<project>) — trusted IP 외 인바운드 0).
# NAT gateway는 이 커리큘럼에 필요하지도 않은데 월 ~$32만 더할 뿐이다.
#
# 실습 루트는 이것들을 ID가 아니라 태그로 조회한다:
#   VPC:     tag:Name    = <project>
#   서브넷:  vpc-id + map-public-ip-on-launch=true (태그 아님)

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.project
  }
}

resource "aws_subnet" "public" {
  count = length(local.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.project}-public-${count.index}"
    Tier = "public"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = local.project
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.project}-public"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- GitHub OIDC provider ------------------------------------------------------
#
# token.actions.githubusercontent.com용 provider는 계정당 하나. AWS는 2023년
# 중반부터 GitHub의 root CA를 직접 신뢰하므로, 아래에 고정된 thumbprint는 더
# 이상 검증에 쓰이지 않는다 — API/provider가 아직 받아주므로, 과거의 핀을
# 기록으로 남기는 의미로 유지한다.

# AWS 계정은 이 URL에 대해 provider를 단 하나만 가질 수 있다. 이 루트가 항상
# 만들고 관리한다(강의 결정). 대상 계정에 이미 하나 있다면, 끄지 말고 IMPORT할 것:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
# 주의: import 후에는 `terraform destroy`가 provider를 삭제한다 — 계정 내 다른
# CI와 공유 중이라면 먼저 `terraform state rm`할 것.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = [local.github_oidc_audience]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name = "github-actions-oidc"
  }
}

# --- 롤: <project>-plan (PR plan, 읽기 전용) ---------------------------
#
# pull_request sub 토큰에만 신뢰를 준다. dflook/terraform-plan은
# `terraform plan -lock=false`를 돌리므로(upstream에 하드코딩됨), 이 롤은 S3
# lockfile을 쓸 일이 전혀 없다 — ReadOnlyAccess가 state read와 모든 provider
# refresh를 커버한다.

data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.github_oidc_audience]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.sub_pull_request]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${local.project}-plan"
  description        = "GitHub OIDC role for ${local.project} PR plans (pull_request sub only, read-only)"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json

  tags = {
    Name = "${local.project}-plan"
  }
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- 롤: <project>-apply (main 브랜치 apply) --------------------------
#
# ref:refs/heads/main sub 토큰(머지된 코드)에만 신뢰를 준다. README에도 있는
# 알려진 한계: main push 토큰은 어떤 workflow가 발급했든 똑같이 보이므로, 이
# trust 정책은 tf-apply.yml인지 main에 push된 가상의 악성 workflow인지 구분하지
# 못한다. workflow 파일 자체가 통제 표면이다 — .github/는 CODEOWNERS 소유이고
# branch ruleset이 리뷰를 요구하므로, workflow를 바꾸려면 먼저 사람 승인 PR을
# 통과해야 한다.
#
# 권한: PowerUserAccess(IAM/계정 관리를 제외한 전부)에 더해, 실습이 정당하게
# 관리하는 IAM 객체(demo-app instance role/profile, provisionable의
# iam_readonly 롤)를 위한 prefix 한정 인라인 정책 — 전부 <project>-* 이름
# 접두사 아래로 강제한다.

data "aws_iam_policy_document" "apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.github_oidc_audience]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # main push(tf-apply, 2-2-prod) + dev push(tf-apply, 2-1-dev) +
      # destroy-approval environment(tf-destroy). 전부 StringEquals — 와일드카드
      # 없음. destroy 잡은 environment 게이트를 지나야 토큰을 받으므로 이 sub
      # 추가가 게이트를 약화시키지 않는다. dev 브랜치도 main과 같은 ruleset
      # (guard required check, force-push 금지)으로 보호된다.
      values = [local.sub_main_branch, local.sub_dev_branch, local.sub_destroy_env]
    }
  }
}

data "aws_iam_policy_document" "apply_iam_prefix" {
  # <project>-* 이름 롤의 전체 라이프사이클. 여기서 AttachRolePolicy는 prefix로만
  # 한정된다(<project>-* 롤에 어떤 관리형 정책이든 붙일 수 있음). 무엇을 붙일지
  # 결정하는 *.tf 파일이 CODEOWNERS로 보호되는 것이 보완 통제다. iam:PolicyARN
  # 조건으로 이걸 더 조이는 것은 09 실습에 남긴 하드닝 과제다.
  statement {
    sid = "RolesUnderPrefix"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.project}-*"]
  }

  statement {
    sid = "InstanceProfilesUnderPrefix"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${local.account_id}:instance-profile/${local.project}-*"]
  }

  # PassRole은 같은 prefix에 더해 EC2로도 한정된다(이 커리큘럼에서 pass 대상은
  # instance profile뿐이다).
  statement {
    sid       = "PassOnlyPrefixedRolesToEc2"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.project}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # 새 계정에서 ASG/ALB를 처음 만들면 이 service-linked 롤들이 암묵적으로
  # 생성된다. PowerUserAccess는 iam:*를 제외하므로 딱 그것만 허용한다 — 실습이
  # 쓰는 두 서비스 이름으로 한정한다.
  statement {
    sid     = "ServiceLinkedRolesForAsgAlb"
    actions = ["iam:CreateServiceLinkedRole"]
    resources = [
      "arn:aws:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/*",
      "arn:aws:iam::${local.account_id}:role/aws-service-role/elasticloadbalancing.amazonaws.com/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "autoscaling.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "${local.project}-apply"
  description        = "GitHub OIDC role for ${local.project} main-branch applies (also non-prod destroy)"
  assume_role_policy = data.aws_iam_policy_document.apply_trust.json

  tags = {
    Name = "${local.project}-apply"
  }
}

resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "apply_iam_prefix" {
  name   = "iam-project-prefix"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_iam_prefix.json
}

# --- 롤: <project>-hermes-readonly (ops 플러그인) -------------------------
#
# Hermes ops 플러그인은 자체 AWS 키를 절대 갖지 않는다: 이 루트가 만든 hermes 호스트
# (또는 로컬 테스트 시 본인 IAM principal)가 이 롤을 assume하므로, 도구(또는
# 프롬프트 인젝션된 모델)가 무엇을 시도하든 read 경계는 IAM 레이어에서 유지된다.
# ReadOnlyAccess에 더해 명시적인 Cost Explorer read(ops_aws_get_cost_summary).
#
# trust는 principal 나열 대신 "account root + aws:PrincipalArn 조건" 패턴을 쓴다.
# principal에 롤 ARN을 직접 넣으면 IAM이 정책 저장 시점에 그 롤의 존재를 검증하고
# 내부적으로 unique id로 고정하므로, (a) 1-00보다 먼저 apply하면 실패하고 (b) 호스트
# 롤을 지웠다 다시 만들면 trust가 조용히 깨진다. 조건 방식은 둘 다 없다 — 같은
# 계정 안에서 ARN이 일치하는 principal만 통과하고, apply 순서 제약도 사라진다.

locals {
  # 실습 전체에 하나뿐인 hermes 호스트 롤이 이 read 롤을 assume할 수 있어야 한다.
  hermes_host_role_arn = "arn:aws:iam::${local.account_id}:role/${local.project}-hermes"
}

data "aws_iam_policy_document" "hermes_readonly_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values = concat(
        [local.hermes_host_role_arn],
        var.hermes_readonly_trust_principals,
      )
    }
  }
}

data "aws_iam_policy_document" "hermes_cost_explorer_read" {
  statement {
    sid = "CostExplorerRead"
    actions = [
      "ce:Get*",
      "ce:Describe*",
      "ce:List*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "hermes_readonly" {
  name               = "${local.project}-hermes-readonly"
  description        = "Read boundary for the ops Hermes plugin (ReadOnlyAccess + Cost Explorer read); trusted to the Hermes host role (by name) and the student's own IAM principals"
  assume_role_policy = data.aws_iam_policy_document.hermes_readonly_trust.json

  tags = {
    Name = "${local.project}-hermes-readonly"
  }
}

resource "aws_iam_role_policy_attachment" "hermes_readonly" {
  role       = aws_iam_role.hermes_readonly.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "hermes_cost_explorer_read" {
  name   = "cost-explorer-read"
  role   = aws_iam_role.hermes_readonly.id
  policy = data.aws_iam_policy_document.hermes_cost_explorer_read.json
}
