# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# 이 디렉터리는 Grafana의 두 가지를 관리한다:
#   1) 관측 콘텐츠 — 대시보드 (observability.tf)
#   2) ops 플러그인 배선용 자격증명 — 아래 Editor SA + 토큰(조회 + silence)
# UI에서 수동으로 만드는 대신 이 디렉터리가 발급한다. 자격증명 결과는 outputs로 나가며
# ~/.hermes/.env의 OPS_GRAFANA_URL / OPS_GRAFANA_TOKEN에 넣는다.
# 알람 룰 / contact point / notification 정책은 2-3-incident-response가 관리한다.
#
# 선행 조건: 2-0-setup/1-foundation apply 완료 + 모니터링 서버의 Grafana 기동
# (부팅 직후라면 provider retries가 잠시 기다려 준다).

locals {
  # var.project가 비어 있으면 리포 루트 디렉토리 이름을 쓴다
  # (path.root = <repo>/2-0-setup/3-grafana → 두 단계 위).
  project = lower(var.project != "" ? var.project : basename(dirname(dirname(abspath(path.root)))))
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

# ops 플러그인의 Grafana 도구가 쓰는 자격증명. Editor 롤 — read(조회) 외에
# 에이전트가 알람 silence를 걸 수 있어야 해서다(ops_grafana_silence: Alertmanager
# silence API는 Viewer로는 403). silence는 만료 있는 런타임 상태라 Terraform
# 리소스가 없고(provider에는 mute_timing뿐) 플러그인의 bounded write 경로가
# 담당한다. Admin이 아니라 Editor인 이유: 데이터소스·유저·조직 관리 등
# 관리자 write는 계속 막는다.
resource "grafana_service_account" "hermes_read" {
  name = "${local.project}-hermes-read"
  role = "Editor"
}

# 만료 없음: 실습 수명이 계정 수명이다. 유출이 걱정되면 이 디렉터리를 destroy 후
# 재-apply하면 토큰이 회전된다.
resource "grafana_service_account_token" "hermes_read" {
  name               = "${local.project}-hermes-read"
  service_account_id = grafana_service_account.hermes_read.id
}
