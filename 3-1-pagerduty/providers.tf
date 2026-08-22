# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
# CI 디렉터리 (main 브랜치 tf-plan/tf-apply, S3 state). provider는 PAGERDUTY_TOKEN
# 환경변수에서 read/write API key를 읽는다 — CI에서는 repo secret PAGERDUTY_TOKEN이
# 주입된다 (gh secret set PAGERDUTY_TOKEN).
terraform {
  required_version = ">= 1.10"
  required_providers {
    pagerduty = {
      source  = "PagerDuty/pagerduty"
      version = "~> 3.0"
    }
  }
}

provider "pagerduty" {}
