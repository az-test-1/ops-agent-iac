# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# Grafana 알람 콘텐츠(알람 룰 / contact point / notification 정책)를 grafana provider로
# 관리한다. "무엇에 알람을 걸고 어디로 보내는가"는 이 실습(알람 → 진단 → 조치)의
# 시작점이라 여기서 세팅한다. 대시보드·datasource·서버는 2-0-setup 소유 — 이 디렉터리를
# 재-apply/destroy해도 관측 기반은 그대로다.

# --- 알람 룰 --------------------------------------------------------------
# 5종: Prometheus(node_exporter) CPU/메모리/디스크/up==0 + Loki(promtail) app
# ERROR(5xx). 전부 인스턴스 단위 평가(쿼리가 인스턴스별 시리즈를 반환 → 시리즈마다
# 별도 alert instance, 요약에 인스턴스 이름 박힘). noDataState=OK: 0으로 스케일된
# fleet은 사고가 아니라 유효한 실습 상태. for=1m + eval 30s: 장애 주입 → 발화 시연을
# 빠르게(게이지 룰 기준 최대 ~1분 30초). CPU 룰만 rate 창을 [2m]로 좁혀 이동평균
# 램프업 지연을 줄인다 — 운영이라면 [5m]/for=5m 이상이 맞지만 여기선 시연 속도가 목적.
# 각 룰은 A(쿼리)→B(reduce last)→C(threshold) 3단이며 condition=C. B/C는
# expression 데이터소스(__expr__).
#
# 알람은 트리거 + 컨텍스트(summary)만 전달한다. 조치는 알람에 인라인으로 넣지 않는다 —
# 에이전트가 read tools로 진단한 뒤 스스로 조치를 고르게 하는 것이 이 실습의 목적이다.
# 알람 → 조치 라우팅(진단 게이트 포함)의 정본은 ops-agent-plugin
# skills/ops-incident-response/SKILL.md §2 — 알람 문구가 조치를 지시하지 않는다.
locals {
  alert_rules = [
    {
      name      = "[monitoring] instance CPU high"
      ds        = "prometheus"
      expr      = "100 - (avg by (instance, name, service) (rate(node_cpu_seconds_total{mode=\"idle\"}[2m])) * 100)"
      op        = "gt"
      threshold = 80
      severity  = "critical"
      summary   = "{{ $labels.name }} ({{ $labels.instance }}) CPU above 80% for 1m"
    },
    {
      name      = "[monitoring] instance memory high"
      ds        = "prometheus"
      expr      = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100"
      op        = "gt"
      threshold = 80
      severity  = "critical"
      summary   = "{{ $labels.name }} ({{ $labels.instance }}) memory above 80% for 1m"
    },
    {
      name      = "[monitoring] instance /data disk high"
      ds        = "prometheus"
      expr      = "(1 - (node_filesystem_avail_bytes{mountpoint=\"/data\"} / node_filesystem_size_bytes{mountpoint=\"/data\"})) * 100"
      op        = "gt"
      threshold = 80
      severity  = "warning"
      summary   = "{{ $labels.name }} ({{ $labels.instance }}) /data volume above 80% used for 1m"
    },
    {
      name      = "[monitoring] app 5xx/ERROR surge (per host)"
      ds        = "loki"
      expr      = "sum by (host, service) (count_over_time({job=\"app\"} |~ ` ERROR ` [2m]))"
      op        = "gt"
      threshold = 10
      severity  = "critical"
      # 윈도우 2m: 발화·해소 지연의 지배 항 — 5m이면 해소 판정에 마지막 오류 후 ~6.5분이
      # 걸린다(윈도우+for+평가). 병렬 30회 주입 기준 2m 안에 임계(10줄/호스트) 충분.
      summary = "{{ $labels.host }}: more than 10 app ERROR lines in 2m — LOG-based 5xx detection (the ALB /healthz check stays green during the /troublemaker fault)"
    },
    {
      name      = "[monitoring] instance scrape down (up==0)"
      ds        = "prometheus"
      expr      = "min by (instance, name, service) (up{name!=\"\"})"
      op        = "lt"
      threshold = 1
      severity  = "critical"
      summary   = "{{ $labels.name }} ({{ $labels.instance }}) node_exporter not responding (up==0) for 1m — instance up but unresponsive"
    },
  ]
}

resource "grafana_rule_group" "instances" {
  name             = "instances"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 30

  dynamic "rule" {
    for_each = local.alert_rules
    content {
      name           = rule.value.name
      condition      = "C"
      for            = "1m"
      no_data_state  = "OK"
      exec_err_state = "Error"
      labels         = { severity = rule.value.severity }
      annotations = {
        summary = rule.value.summary
      }

      data {
        ref_id         = "A"
        datasource_uid = rule.value.ds
        relative_time_range {
          from = 600
          to   = 0
        }
        model = rule.value.ds == "loki" ? jsonencode({
          refId     = "A"
          expr      = rule.value.expr
          queryType = "range"
          }) : jsonencode({
          refId   = "A"
          expr    = rule.value.expr
          range   = true
          instant = false
        })
      }

      data {
        ref_id         = "B"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({
          refId      = "B"
          type       = "reduce"
          expression = "A"
          reducer    = "last"
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "B"
          conditions = [{ evaluator = { type = rule.value.op, params = [rule.value.threshold] } }]
        })
      }
    }
  }
}

# --- Notification: contact point + 정책 (조건부) ---------------------------
# 알람 통지는 Slack 단일 경로다. webhook 미설정이면 정책·contact point를 만들지
# 않고 알람은 Grafana UI에만 머문다. 에이전트 전달도 이 경로 하나다 — Hermes가
# 알람 채널을 직접 읽는다(별도 webhook 경로 없음). PagerDuty 자동 페이지는 의도적으로
# 없다: 온콜 페이지는 에이전트가 런북 서킷 브레이커에서 포기했을 때만
# ops_pagerduty_page_oncall(Events API v2, 3-1-pagerduty routing key)로 나간다.
locals {
  notify_enabled = var.slack_webhook_url != ""

  # Slack 메시지 템플릿(인라인). Firing/Resolved 섹션 분리 — 사람은 섹션 제목으로,
  # 에이전트는 문자열 매칭이 아닌 섹션 위치로 상태를 판별한다. ValueString은 reduce(last)
  # 값이라 이 룰들에선 곧 현재 측정값(임계값 대비 실제치). SilenceURL은 항상 제공되고
  # DashboardURL은 __dashboardUid__ annotation이 있을 때만 값이 생긴다(현재 룰엔 없음).
  # instance 라벨이 없는 loki 룰(host 라벨만)은 or로 폴백한다. color는 attachment
  # 좌측 바 색상 — firing 빨강 / resolved 초록.
  # Fingerprint는 alert instance 식별자(라벨셋 해시) — 룰과 인스턴스를 값 하나로
  # 특정한다. 장애 조치 PR을 열 때 에이전트가 reason에 alarm_id=<이 값>으로 옮겨
  # 적고, 정책 승인자(심화 실습)는 이 값으로 Grafana에 직접 조회해 판정한다.
  notify_title = "{{ if eq .Status \"firing\" }}:red_circle:{{ else }}:white_check_mark:{{ end }} [{{ .CommonLabels.severity | toUpper }}] {{ .CommonLabels.alertname }}"
  notify_color = "{{ if eq .Status \"firing\" }}#D63232{{ else }}#36A64F{{ end }}"
  notify_body  = <<-EOT
    {{ if .Alerts.Firing }}:fire: Firing {{ len .Alerts.Firing }}건
    {{ range .Alerts.Firing -}}
    *{{ .Labels.alertname }}*  `{{ or .Labels.instance .Labels.host }}`
    {{ if .Annotations.summary }}> {{ .Annotations.summary }}
    {{ end }}측정값: {{ .ValueString }}
    알람 ID: `{{ .Fingerprint }}`
    :no_bell: <{{ .SilenceURL }}|silence>{{ if .DashboardURL }} · <{{ .DashboardURL }}|dashboard>{{ end }}
    {{ end }}{{ end -}}
    {{ if .Alerts.Resolved }}:white_check_mark: Resolved {{ len .Alerts.Resolved }}건
    {{ range .Alerts.Resolved -}}
    *{{ .Labels.alertname }}*  `{{ or .Labels.instance .Labels.host }}`
    {{ end }}{{ end -}}
  EOT
}

resource "grafana_contact_point" "slack" {
  count = var.slack_webhook_url != "" ? 1 : 0
  name  = "slack"

  slack {
    url   = var.slack_webhook_url
    title = local.notify_title
    text  = local.notify_body
    color = local.notify_color
  }
}

resource "grafana_notification_policy" "root" {
  count = local.notify_enabled ? 1 : 0

  contact_point  = "slack"
  group_by       = ["grafana_folder", "alertname"]
  group_wait     = "10s"
  group_interval = "1m"
  # 5m 균형값(2026-08-03 INC-4 리허설 실측). 2m은 반복 통지 세션이 에피소드당
  # 3~5개씩 쌓여 시끄럽고, 10m은 에스컬레이션이 느려진다 — 조치(rolling-restart 등)가
  # 완료됐는데 알람이 남는 경우, 에이전트의 1회성 후속 cron이 완료 시점을 놓치면
  # 다음 재평가 트리거가 이 반복 통지다. 10m이면 page가 조치 완료 후 최대 10분 밀린다
  # (실측: 발화→page 23분). 반복 통지는 이제 한 줄(§0.5)이라 5m 노이즈는 낮다.
  # 운영이라면 30m 이상이 맞다.
  repeat_interval = "5m"

  # 정책은 contact point를 이름(문자열)으로 참조하므로 생성 순서를 명시한다.
  depends_on = [grafana_contact_point.slack]
}
