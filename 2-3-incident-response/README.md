# 2-3-incident-response — 알람 발화 → 에이전트 진단 → 자동 조치

## 목표

앞선 2-1-dev / 2-2-prod가 "사람(또는 에이전트)이 요청한 변경을 안전하게 반영"이라면,
여기서는 **관측된 알람에서 시작해 에이전트가 스스로 진단하고 조치**한다. 그래서
"알람이 오게끔" 하는 세팅(알람 룰 + notification 배선)도 이 실습의 terraform 디렉터리가
직접 provisioning한다 — 관측 기반(모니터링 서버·datasource·대시보드·read 토큰)은
2-0-setup 소유 그대로 두고, 알람 콘텐츠만 여기서 만든다. 조치는 기존 ansible
플레이북·surface·플러그인 스킬을 재사용한다.

## 사전 준비 — 모니터링 에이전트 설치 (인스턴스가 새로 뜰 때마다)

app 인스턴스의 node_exporter(:9100)와 promtail은 초기 서비스 세팅(user_data)에
포함되지 않는다 — 이 실습을 시작할 때 ansible로 설치한다. 설치 전에는 아래 알람
룰의 소스(metric/log)가 없어 발화하지 않는 것이 정상이다. 모니터링 서버
(Prometheus/Loki/Grafana) 자체는 2-0-setup이 이미 띄워 두었다.

```bash
gh workflow run ansible-ops.yml -f environment=dev -f playbook=monitoring-agents
# prod도 실습하면: -f environment=prod
```

**주의 — 1회로 끝나지 않는다.** exporter는 user_data 밖이라 인스턴스가 교체되면
사라진다(시나리오 9 삭제 후 재세팅, blue-green 교체 등). 이 디렉터리의 알람이 이미
provisioning된 상태에서 새 인스턴스를 띄우면 `up==0` critical이 바로 발화해 알람
채널이 시끄러워진다 — **서비스를 (재)기동한 직후 위 dispatch를 먼저 실행**한다.
(방치해도 에이전트가 up==0 경로로 자동 설치하지만 알람 소음이 남는다.)

## 알람 세팅 (이 디렉터리의 terraform)

이 디렉토리가 사람-로컬 terraform root 모듈이다(2-0-setup과 동일: CI 밖, 로컬 state,
trusted IP에서만 apply — Grafana :3000이 trusted IP에만 열려 있다).

provisioning 대상:

- **알람 룰 7종** (`alerting.tf`, 인스턴스 단위 평가 — 전용 폴더 `<project>-alerts`):

  | 알람 | 소스 | severity | 의미 |
  |---|---|---|---|
  | CPU high | Prometheus node_exporter | critical | 사용률 80% 초과 1분 |
  | Memory high | Prometheus node_exporter | critical | 사용률 80% 초과 1분 |
  | /data disk high | Prometheus node_exporter | warning | 데이터 볼륨 80% 초과 |
  | /data inode high | Prometheus node_exporter | warning | inode 80% 초과 |
  | scrape down (up==0) | Prometheus | critical | 인스턴스 무응답 |
  | app 5xx/ERROR surge | Loki (`job=app`) | critical | 5분 내 ERROR 10줄 초과 |
  | auth failure surge | Loki (`job=nginx`) | warning | 5분 내 401 20회 초과 |

- **contact point + notification 정책** — Slack 단일 통지(`slack_webhook_url`).
  안 넘기면 알람은 평가·발화되지만 Grafana UI에만 보인다. Grafana가 PagerDuty로
  자동 페이지하는 경로는 없다 — 온콜 페이지는 에이전트가 런북 서킷 브레이커에서
  자동 대응을 포기했을 때만 `ops_pagerduty_page_oncall`로 나간다(3-1 실습).

세팅 절차 (전제: 2-0-setup foundation + 2-1-dev apply 완료, Grafana 기동):

```bash
cd 2-3-incident-response
terraform init && terraform apply
# admin 비밀번호를 UI에서 바꿨다면: -var 'grafana_auth=admin:<새 비밀번호>'
# 알림 라우팅(선택)은 Slack webhook을 함께 넘겨 켠다:
#   -var 'slack_webhook_url=...'
```

apply가 끝나면 alert는 Slack contact point로 알람 채널에 라우팅되고, Hermes가
그 채널을 직접 읽는다. 즉 "알람 → 에이전트"가 자동으로 도착한다.

## 조치 경로 (알람 → 진단 → 조치)

에이전트(`ops-alarm-response` 스킬)가 metric·log를 읽어 원인을 좁히고, 알람 종류에
맞는 조치를 고른다. 조치는 3가지 축이다:

1. **메모리 누수 / 행 (up==0)** → 롤링 재시작
   `ansible/rolling-restart.yml` — TG에서 빼고(드레인) → 서비스 재시작 → `/healthz`
   확인 → TG 복귀. `ansible-ops.yml` dispatch(playbook=rolling-restart, environment=dev|prod).

2. **디스크 임계** → 볼륨 확대
   `disk.auto.tfvars`(surface)로 `data_volume_size_gb`를 올리는 PR → 머지 시 terraform이
   EBS를 라이브 확대 → `ansible/disk-grow.yml`이 파일시스템 확장. (grow-only 가드레일)

3. **app 오류 / 5xx** → 로그 조사 후 코드 수정 PR
   Loki에서 ERROR 로그를 조회해 원인 경로(예: `/troublemaker`)를 특정 → 앱 코드
   리포(`wo-o/ops-agent-app`)에 수정 PR을 연다. (사람 리뷰 경로)

## 조치별 승인 (경로가 정책)

- rolling-restart / disk-grow(dev) → 무소유 경로·자동 (auto)
- prod 대상 조치, 코드 수정 PR, 구조 변경 → CODEOWNERS 소유 → 사람 승인
- 삭제성 조치 → `tf-destroy`의 Slack 멘션(`@진`) + `destroy-approval` 게이트

## 알람 유발 (실습용)

앱의 `/troublemaker` 경로가 DB 커넥션 누수 + CPU 소모 + ERROR 로그 + 500을 내며
사전 장애를 재현한다 — 알람을 실제로 발화시키는 트리거다.

```bash
# dev app ALB로 장애 유발 (RDS 커넥션 누수 + CPU burn + 5xx)
curl "http://$(terraform -chdir=../2-1-dev output -raw alb_dns_name)/troublemaker"
# → 수 분 내 CPU/메모리/5xx 알람 발화 → Hermes로 라우팅 → 에이전트 대응 관찰
```

## destroy

이 디렉터리만 destroy하면 알람 룰·contact point·notification 정책이 지워진다 —
대시보드·datasource·모니터링 서버(2-0-setup 소유)는 그대로다. 단, Grafana
서버(:3000)가 살아 있어야 provider가 접속해 지울 수 있으므로 2-0-setup foundation을
내리기 전에 먼저 destroy할 것.

## 요약

- **알람 세팅 terraform은 여기** — 알람 룰 7종 + contact point + notification 정책.
  서버·대시보드·토큰(2-0-setup)과 분리돼 있어 알람 콘텐츠만 재-apply/destroy할 수 있다.
- 조치는 기존 app + 모니터링 + ansible/surface/플러그인 재사용.
- 핵심: **알람이 에이전트에게 도착하고, 에이전트가 진단→조치까지 자율로 수행**하되,
  조치의 승인 경계는 앞선 실습과 동일하게 CODEOWNERS·environment가 강제한다.
