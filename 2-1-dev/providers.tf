# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다. dev/prod 동일.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.aws_region

  # 모든 리소스 표준 태그. Environment는 env.auto.tfvars가 정한다.
  default_tags {
    tags = {
      Project     = var.project != "" ? var.project : "ops-agent-iac"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# DNS(2-05)/WAF(2-06)용 — 실습 필수 단계. 토큰은 GitHub secret CLOUDFLARE_API_TOKEN으로
# 항상 주입한다. 미주입 시 리소스 0이라 provider를 호출하지 않는 fail-closed는 안전장치.
provider "cloudflare" {}
