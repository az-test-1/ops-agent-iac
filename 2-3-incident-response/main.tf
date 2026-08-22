# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# 이 디렉터리는 "알람이 오게끔" 하는 세팅 전부를 관리한다 — 알람 룰 / contact point /
# notification 정책 (alerting.tf). 예전에는 2-0-setup/3-grafana에 있었지만,
# "관측된 알람에서 시작해 에이전트가 진단·조치한다"가 이 실습의 주제라서 알람 배선을
# 실습과 같은 디렉터리로 옮겼다 — 2-0-setup은 서버·대시보드·토큰 같은 관측 기반만 남는다.
#
# 선행 조건: 2-0-setup/1-foundation apply로 모니터링 서버가 떠 있고 Grafana(:3000)가
# 기동한 상태 + 2-1-dev(또는 2-2-prod) apply로 관측 대상 앱 fleet이 떠 있는 상태.
# datasource(uid=prometheus / loki)는 서버 부팅 시 file provisioning으로 만들며
# (2-0-setup/1-foundation monitoring.tf), 알람 룰이 그 uid를 문자열로 참조한다.

locals {
  # var.project가 비어 있으면 리포 루트 디렉토리 이름을 쓴다
  # (path.root = <repo>/2-3-incident-response → 한 단계 위).
  project = lower(var.project != "" ? var.project : basename(dirname(abspath(path.root))))
}

# 공유 모니터링 서버(2-0-setup/1-foundation monitoring.tf가 생성) — 실습 루트와
# 동일하게 고정 Name 태그로 조회한다. IP는 리포에 커밋되지 않는다.
data "aws_instance" "monitoring" {
  filter {
    name   = "tag:Name"
    values = ["${local.project}-monitoring-server"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# 알람 룰 전용 폴더. 대시보드 폴더(uid=<project>, 2-0-setup/3-grafana 소유)와 분리 —
# 이 디렉터리를 destroy해도 대시보드는 남는다.
resource "grafana_folder" "alerts" {
  title = "${local.project}-alerts"
  uid   = "${local.project}-alerts"
}
