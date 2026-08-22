# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# 사람-로컬 디렉터리 (2-0-setup과 동일: CI 밖, 로컬 state). Grafana HTTP API(:3000)에
# 직접 접속하므로 반드시 trusted_ip에서 apply해야 한다 — 모니터링 SG가 :3000을
# trusted IP에만 열기 때문에 CI 러너에서는 원천적으로 돌 수 없다.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# url은 data.aws_instance(태그 조회, main.tf)에서 오므로 plan 시점에 항상 known이다
# — 같은 디렉터리에서 서버를 만들며 provider가 그 IP를 참조하는 unknown-at-plan 문제를
# 피하려고 서버 생성(2-0-setup/1-foundation)과 이 디렉터리를 분리했다.
# retries: 2-0-setup/1-foundation apply 직후에는 Grafana 컨테이너가 아직 부팅 중일 수 있다.
provider "grafana" {
  url  = "http://${data.aws_instance.monitoring.public_ip}:3000"
  auth = var.grafana_auth

  retries    = 6
  retry_wait = 10
}
