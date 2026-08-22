# 수신 변형 — Hermes 웹훅 게이트웨이로 받기

systemd 리스너(`../policy_approver.py` 서버 모드) 대신, 모니터링 호스트에 설치한
Hermes의 웹훅 게이트웨이(`hermes webhook subscribe`)로 GitHub `pull_request`
웹훅을 받는 변형이다. Day 1에서 배운 웹훅 구독 흐름(서명 검증 → 이벤트 필터 →
스크립트 필터 → 세션 실행 → 전달)을 실전 게이트에 그대로 재사용한다.

**판정 주체는 변하지 않는다.** 승인·머지 여부는 여전히
`policy_approver.py --check-pr <n>`(결정적 파이프라인)이 정하고, Hermes 세션의
역할은 수신·실행·Slack 보고뿐이다. LLM 재량이 승인 게이트에 끼어들지 않도록
스킬(`pr-policy-approve/SKILL.md`)이 "스크립트 판정 뒤집기 금지"를 명시한다.

신뢰 경계도 동일하다: 이 Hermes는 **에이전트 호스트의 Hermes가 아니라**
모니터링 호스트에 따로 설치한 인스턴스의 전용 프로필이다. PAT·Grafana 토큰은
이 호스트에만 존재한다. 에이전트 호스트의 Hermes에 프로필만 하나 더 만드는 것은
같은 프로세스·같은 파일 접근 범위라 신뢰 경계 분리가 아니다 — 반드시 호스트를
분리한다.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `github-pr-filter.sh` | 라우트 스크립트 필터 — 봇 PR + `alarm_id=` 본문만 세션으로 (LLM 비용 컷) |
| `pr-policy-approve/SKILL.md` | 승인자 프로필 스킬 — `--check-pr` 실행과 결과 보고만 |

## 세팅 (모니터링 호스트)

전제: Hermes 설치 완료, `jq` 설치, `../README.md`의 PAT·Grafana 토큰 발급 완료.

```bash
# 1) 승인자 전용 프로필 + wrapper(approver 명령) 생성
hermes profile create approver --no-skills \
  --description "Incident PR policy approver: runs policy_approver.py --check-pr and reports the verdict"

# 2) 파일 배치 — 판정 코드·자격증명은 gateway 사용자 홈에만 (600)
mkdir -p ~/policy-approver
cp ../policy_approver.py github-pr-filter.sh ~/policy-approver/
cp ../policy-approver.env.example ~/policy-approver/policy-approver.env
chmod 600 ~/policy-approver/policy-approver.env
vi ~/policy-approver/policy-approver.env   # GITHUB_TOKEN·GITHUB_REPO·GRAFANA_TOKEN 채우기
                                           # (WEBHOOK_SECRET는 --check-pr 모드에선 불필요 —
                                           #  HMAC은 게이트웨이 라우트가 검증)

# 3) 스킬 배치 (approver 프로필의 skills 디렉토리)
cp -r pr-policy-approve ~/.hermes/profiles/approver/skills/

# 4) 웹훅 라우트 구독 — /webhooks/github-pr 생성
approver webhook subscribe github-pr \
  --events pull_request \
  --script ~/policy-approver/github-pr-filter.sh \
  --secret "<리포 웹훅에 등록할 secret과 동일 값>" \
  --skills pr-policy-approve \
  --description "policy approver: verify incident PR via --check-pr" \
  --prompt "GitHub PR #{pull_request.number} 승인 심사 요청. pr-policy-approve 스킬 절차대로 policy_approver.py --check-pr {pull_request.number} 를 실행하고 판정 결과만 보고하라. PR: {pull_request.html_url}" \
  --deliver slack --deliver-chat-id <#alert-ops-agent 채널 ID>

# 5) 게이트웨이 기동 (기본 리스너 :8644)
approver gateway start
```

SG 인바운드는 `api.github.com/meta`의 `hooks` CIDR → **:8644**(게이트웨이 포트)로
개방하고, 리포 웹훅의 Payload URL은
`http://<monitoring-host-public-ip>:8644/webhooks/github-pr`로 등록한다
(secret·이벤트 선택은 `../README.md` 5번과 동일). 게이트웨이가
X-Hub-Signature-256 HMAC을 라우트 secret으로 검증하므로, 서명 불일치 요청은
필터·세션에 닿기 전에 401로 끊긴다.

`--deliver slack`을 쓰려면 approver 프로필에 Slack 봇 토큰이 설정돼 있어야 한다
(기존 알람 채널 봇 재사용 가능). Slack 배선을 생략하면 `--deliver log`로 바꿔도
동작은 같다 — 감사 기록은 어차피 PR의 승인 코멘트·레이블에 남는다.

## 요청 하나의 흐름

```
GitHub POST /webhooks/github-pr
→ gateway: HMAC 검증 (불일치 401)
→ --events: pull_request 외 버림
→ github-pr-filter.sh: opened/synchronize · base=main · 봇 PR · alarm_id= 본문만 통과
→ 새 세션(pr-policy-approve 스킬): policy_approver.py --check-pr <n> 실행
   (fingerprint 조회 → 정책 매핑 → diff → guard 대기 → 승인·레이블·머지)
→ 판정 결과를 Slack으로 전달
```

주의: systemd 변형과 이 변형을 동시에 켜지 않는다 — 같은 PR을 두 수신자가
처리하면 승인 리뷰·머지가 중복 시도된다(머지는 한쪽이 실패할 뿐 무해하지만
로그가 혼란스럽다). 리포 웹훅의 Payload URL을 어느 한쪽으로만 등록할 것.
