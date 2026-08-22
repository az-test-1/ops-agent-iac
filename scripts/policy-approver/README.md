# policy approver — prod 장애 조치 PR 자동 승인 (Day 3 심화 실습)

모니터링 호스트에서 도는 단일 파이썬 서비스. GitHub `pull_request` 웹훅을 받아,
PR이 참조한 알람이 **지금 Grafana에서 firing 중인지 직접 확인**한 경우에만
prod disk 확장 PR을 승인·머지한다. 리포 게이트(CODEOWNERS·룰셋·auto-merge)는
하나도 바꾸지 않는다 — code owner 본인의 fine-grained PAT로 본인의 승인 클릭을
자동화할 뿐이라, 평상시 prod PR은 여전히 사람 승인을 기다린다.

배경·설계 원칙은 강의 자료(scenario-prompts)의 "심화 실습" 섹션 참고.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `policy_approver.py` | 승인자 본체 (Python 3.9+ stdlib만 사용, 의존성 없음). 웹훅 서버 모드(기본) + `--check-pr <n>` one-shot 모드 |
| `policy-approver.service` | systemd 유닛 |
| `policy-approver.env.example` | 환경 파일 템플릿 (`/etc/policy-approver.env`) |
| `hermes/` | 수신 변형 — systemd 리스너 대신 Hermes 웹훅 게이트웨이로 받기 (`hermes/README.md`) |

정책 자체는 `policy_approver.py`의 `POLICY` 딕셔너리다: 알람 이름 →
허용 파일·변수·상한. 기본값은 `instance /data disk high` →
`2-2-prod/disk.auto.tfvars`의 `data_volume_size_gb` grow-only, 상한 100
(variables.tf validation과 동일). severity는 판정에 쓰지 않는다 — disk 알람은
warning이라 "critical만 승인"으로 걸면 정작 디스크 풀이 빠진다.

## 세팅 절차

1. **fine-grained PAT 발급** — GitHub Settings → Developer settings →
   Fine-grained tokens. Repository access를 iac 리포 하나로 한정하고 권한은
   Pull requests **Read and write** + Contents **Read and write**(머지용) 두
   개만. 본인이 code owner이므로 이 PAT의 승인 리뷰가 룰셋의 code-owner
   요구를 충족한다.
2. **Grafana 서비스 계정 토큰** — 모니터링 호스트 Grafana(Administration →
   Service accounts)에서 Viewer 권한 계정 + 토큰 생성. 승인자는
   `localhost:3000`으로 firing 알람을 질의한다.
3. **파일 배치 (모니터링 호스트)**
   ```bash
   scp -r scripts/policy-approver <monitoring-host>:/tmp/
   ssh <monitoring-host>
   sudo mkdir -p /opt/policy-approver
   sudo cp /tmp/policy-approver/policy_approver.py /opt/policy-approver/
   sudo cp /tmp/policy-approver/policy-approver.service /etc/systemd/system/
   sudo cp /tmp/policy-approver/policy-approver.env.example /etc/policy-approver.env
   sudo chmod 600 /etc/policy-approver.env
   sudo vi /etc/policy-approver.env   # 토큰·리포·secret 채우기
   sudo systemctl daemon-reload && sudo systemctl enable --now policy-approver
   journalctl -u policy-approver -f   # "listening on :8646" 확인
   ```
4. **SG 인바운드 개방** — GitHub webhook 발신 대역에서 :8646만 허용.
   ```bash
   curl -s https://api.github.com/meta | jq -r '.hooks[]'
   # 나온 CIDR들을 모니터링 SG 인바운드 TCP 8646으로 추가
   ```
5. **리포 웹훅 등록** — 리포 Settings → Webhooks → Add webhook.
   Payload URL `http://<monitoring-host-public-ip>:8646/`, Content type
   `application/json`, Secret은 env 파일의 `WEBHOOK_SECRET`과 동일 값,
   이벤트는 "Let me select" → **Pull requests**만. 등록 직후 ping 전송이
   Recent Deliveries에 200으로 찍히면 수신 경로 완성.
6. **에이전트 규약** — 장애 조치로 tfvars PR을 열 때 reason에 Slack 알람
   통지의 "알람 ID"(alert fingerprint)를 포함하도록 스킬에 지시(이미 지시돼
   있다면 생략): `alarm_id=<알람 ID>`. 이 값이 PR 본문의 "요청:" 라인에 실리고,
   승인자는 이를 **조회 키로만** 써서 Grafana에 그 fingerprint가 지금 firing인지
   직접 질의한다. 알람 이름·인스턴스 같은 판정 재료는 전부 조회 응답에서
   꺼낸다 — 위조 ID는 조회 미존재로, 남의 알람 ID는 정책 매핑·prod 확인에서
   걸러진다.

## 검증

INC-1의 prod 재연: prod app 호스트 `/data`에 fallocate 주입 → 알람 firing →
에이전트가 prod disk PR → 승인자가 검증 후 자동 승인·머지 → push 트리거로
tf-apply(2-2-prod) → 에이전트가 disk-grow dispatch → 해소 보고. 사람 개입 0회.
알람 없이 여는 평상시 prod PR은 승인자가 건드리지 않는 것(skip 로그)도 함께
확인한다.

- EBS 볼륨 확장은 볼륨당 하루 1회 제약 — 리허설·본방 중복 주입 주의.
- 승인·스킵 사유는 전부 `journalctl -u policy-approver`에 남는다. 승인 시
  PR에는 근거 코멘트(알람·값·시각)와 `incident-auto-approved` 레이블이 붙는다.

## 파이프라인 (요청당)

```
X-Hub-Signature-256 HMAC 검증 (불일치 즉시 거부)
→ opened/synchronize · 봇 PR · base=main만 통과
→ 본문에서 alarm_id=<fingerprint> 파싱 (없으면 스킵)
→ Grafana alertmanager API에 그 fingerprint로 firing 조회 (없으면 스킵)
→ 조회 응답의 alertname으로 정책 매핑 + 응답의 instance로 prod 확인
  (base=main PR을 dev 알람으로 정당화 불가 — PR 본문 값은 판정에 안 쓴다)
→ 정책 파일 단일 변경 · diff 검증: 값 하나만 변경 · grow-only · 상한 이내
→ guard check success 대기 (최대 10분)
→ 승인 리뷰 + 근거 코멘트 + incident-auto-approved 레이블 + squash 머지
```

머지가 사람 PAT라 push 이벤트가 정상 발생하고 tf-apply(2-2-prod)는 기존
트리거로 돈다. disk-grow(prod)는 에이전트가 머지 확인 후 dispatch — 승인자의
역할은 머지까지다.

수신 변형: 모니터링 호스트에 Hermes를 설치했다면 systemd 리스너 대신 Hermes
웹훅 게이트웨이(`hermes webhook subscribe`)로 받을 수 있다 — Day 1 웹훅 실습의
실전 적용판. 세팅과 흐름은 `hermes/README.md` 참고 (판정은 동일하게
`policy_approver.py --check-pr`가 내린다). SG를 열 수 없는 환경이면 웹훅 대신
30초 폴링 변형으로 대체 가능(웹훅 등록·인바운드 불필요, 판정 파이프라인 동일).
