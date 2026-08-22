# 사람이 소유하는 파일 — 에이전트는 *.tf를 절대 수정하면 안 된다.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # terraform을 돌리는 머신의 공인 IP 자동 감지용 (main.tf의 data.http.caller_ip)
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # foundation 리소스 표준 태그. Environment=shared(dev/prod 공용). hermes 호스트는
  # 리소스 레벨에서 Environment=dev/prod로 override한다.
  default_tags {
    tags = {
      Project     = local.project
      Environment = "shared"
      ManagedBy   = "terraform"
    }
  }
}

