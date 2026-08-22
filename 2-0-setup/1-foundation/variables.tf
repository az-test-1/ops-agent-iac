# 사람이 소유하는 파일 — 에이전트는 *.tf를 절대 수정하면 안 된다.
#
# AWS 계정 ID는 변수로도 두지 않고 하드코딩도 하지 않는다: apply 시점에
# data.aws_caller_identity(main.tf 참고)에서 읽으므로, 같은 코드가 어떤
# 수강생 계정이든 그대로 부트스트랩한다.

variable "project" {
  description = <<-EOT
    모든 리소스 이름의 프리픽스(state 버킷, VPC 태그, OIDC 롤,
    IAM prefix 가드 등 전부 "<project>-..."로 명명된다). 기본값 ""이면 리포
    루트 디렉토리 이름을 자동으로 쓴다 — 2-0-setup/0-bootstrap.sh가 같은 규칙으로
    버킷을 만들고 GitHub 리포 변수 PROJECT_NAME으로도 등록하므로(gh CLI 인증
    시 자동, 아니면 출력된 명령을 직접 실행), 셋이 같은 값을 보게 된다.
    CI는 dflook variables 입력으로 이 값을 주입한다. foundation.sh는 프로젝트
    이름과 무관하게 실제 GitHub owner/repo와 OIDC subject prefix를 API에서 읽어
    github_repo/github_oidc_subject_prefix로 함께 전달한다.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.project == "" || can(regex("^[a-z0-9][a-z0-9-]{1,23}$", var.project))
    error_message = "project는 소문자/숫자/하이픈만, 2~24자여야 한다 (S3 버킷 이름 규칙 + ALB 이름 32자 제한: <project>-<N-NN>-fe가 32자를 넘으면 안 된다)."
  }
}

variable "aws_region" {
  description = "모든 것이 도는 AWS 리전. GitHub 리포 변수 AWS_REGION과 일치해야 한다(workflow도 기본값이 ap-northeast-2다)."
  type        = string
  default     = "ap-northeast-2"
}

variable "github_owner" {
  description = "이 리포의 fork/인스턴스를 소유한 GitHub owner(사용자 또는 org). self-hosted runner 등록 대상에 사용한다. foundation.sh가 현재 리포에서 읽어 전달하며, 특정 핸들을 기본값으로 두지 않는다."
  type        = string
}

variable "github_repo" {
  description = "GitHub 리포지토리 이름. self-hosted runner 등록 대상에 사용한다. 기본값(빈 문자열)이면 project 이름(= 리포 디렉토리 이름)을 그대로 쓴다 — 리포를 다른 이름으로 fork했을 때만 지정하면 된다."
  type        = string
  default     = ""
}

variable "github_oidc_subject_prefix" {
  description = <<-EOT
    GitHub이 이 리포의 OIDC sub 앞부분으로 실제 발급하는 값. 반드시
    `gh api repos/$OWNER/$REPO/actions/oidc/customization/sub --jq .sub_claim_prefix`
    결과를 그대로 넘긴다. 일반 repo:<owner>/<repo>와 immutable-ID가 포함된
    repo:<owner>@<id>/<repo>@<id> 형식을 모두 지원하며, IAM trust는 이 prefix에
    event/ref/environment suffix를 붙여 StringEquals로 정확히 일치시킨다.
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^:]+/[^:]+$", var.github_oidc_subject_prefix))
    error_message = "github_oidc_subject_prefix는 GitHub API가 반환한 repo:<owner>/<repo> 또는 repo:<owner>@<id>/<repo>@<id> 형식이어야 한다."
  }
}

variable "hermes_readonly_trust_principals" {
  description = <<-EOT
    <project>-hermes-readonly 롤을 assume할 수 있는 "추가" IAM principal ARN 목록.
    이 루트가 만드는 hermes 호스트 롤(<project>-hermes)은 이름 규약으로 항상
    trust에 포함되므로 지정할 필요가 없다 — ops 플러그인을 로컬(본인 Mac)에서
    돌려볼 때만 본인 IAM user/role ARN을 넣는다
    (예: arn:aws:iam::<account-id>:user/<you>).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for p in var.hermes_readonly_trust_principals :
      can(regex("^arn:aws:iam::[0-9]{12}:(root$|user/|role/)", p))
    ])
    error_message = "각 항목은 IAM principal ARN이어야 한다: arn:aws:iam::<account-id>:root, :user/<name> 또는 :role/<name>."
  }
}

# --- 공유 접근 프리미티브 + 공유 모니터링 스택 -----------------------------
# 수강생별 값: 본인 fork에서 아래 기본값을 직접 편집해 설정한다.
# variables.tf는 사람이 소유하는 파일(CODEOWNERS "*.tf")이므로, 이 변경은 항상
# code-owner 리뷰를 거친다 — 에이전트를 통해서는 절대 이뤄지지 않는다.

variable "ssh_public_key" {
  description = <<-EOT
    key pair <project>에 등록할 본인 SSH 공개키 내용. 기본값 ""이면
    1주차에 만든 규약 경로 ~/.ssh/ops-agent-iac.pub 파일을 자동으로 읽는다 —
    보통 지정할 필요가 없다. 이 리포의 모든 실습 EC2가 이 키로 SSH 접속된다.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.ssh_public_key == "" || can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ", var.ssh_public_key))
    error_message = "ssh_public_key는 \"\"(자동: ~/.ssh/ops-agent-iac.pub) 또는 OpenSSH 공개키 한 줄이어야 한다."
  }
}

variable "trusted_ip" {
  description = <<-EOT
    공유 접근 SG(<project>, 모든 실습 EC2 부착)와 모니터링 Grafana(:3000)가 허용하는
    유일한 소스 IP(IPv4 CIDR). 기본값 ""이면 terraform을 돌리는 이 머신의 공인
    IP를 apply 시점에 자동 감지해 쓴다(1-00-setup과 동일한 패턴) — 보통은 지정할
    필요가 없다. IP가 바뀌면 이 루트만 재-apply하면 된다. 0.0.0.0/0 금지.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.trusted_ip == "" || can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/(2[3-9]|3[0-2])$", var.trusted_ip))
    error_message = "trusted_ip은 \"\"(자동 감지) 또는 prefix 길이 23~32의 IPv4 CIDR이어야 한다(예: 203.0.113.7/32)."
  }
}

# Notification 채널 변수(slack_webhook_url)는 2-3-incident-response로 옮겼다.
# contact point·notification 정책이 알람 룰과 함께 그 디렉터리(alerting.tf)에서 관리된다.
# PagerDuty routing key(3-1-pagerduty output)는 Grafana가 아니라 Hermes 플러그인
# (OPS_PAGERDUTY_ROUTING_KEY, 에이전트 에스컬레이션 페이지 전용)에 배선한다.
