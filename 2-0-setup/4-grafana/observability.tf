# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# Grafana 대시보드를 grafana provider로 관리한다. 예전에는 모니터링 서버
# user_data(2-0-setup/1-foundation monitoring.tf)에 파일 provisioning으로 구워
# 넣었지만, "무엇을 보는가"는 서버 인프라와 별개라서 이 디렉터리로 분리했다 — 서버는
# 그대로 두고 콘텐츠만 재-apply할 수 있다.
#
# 알람 룰 / contact point / notification 정책은 여기가 아니라
# 2-3-incident-response가 관리한다 — "알람이 오게끔" 하는 배선은 알람 대응
# 실습의 시작점이라 그 실습 디렉터리로 옮겼다.
#
# 선행 조건: foundation apply로 모니터링 서버가 떠 있고 Grafana(:3000)가 기동한 상태.
# datasource(uid=prometheus / loki)는 여전히 서버 부팅 시 file provisioning으로 만들며
# (monitoring.tf), 아래 대시보드가 그 uid를 문자열로 참조한다.

# --- 실습 폴더 -------------------------------------------------------------
resource "grafana_folder" "this" {
  title = local.project
  uid   = local.project
}

# --- Service Overview 대시보드 --------------------------------------------
# 패널 JSON은 dashboards/service-overview.json에 그대로 둔다(코드에서 분리해 diff·편집
# 용이). datasource는 패널 내부에서 uid=prometheus / loki로 고정 참조한다.
resource "grafana_dashboard" "service_overview" {
  folder      = grafana_folder.this.uid
  overwrite   = true
  config_json = file("${path.module}/dashboards/service-overview.json")
}
