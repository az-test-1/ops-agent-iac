# 아키텍처 기반 변형 질문 (SA 셀) — fc-e2e-live 보조 문서

소크 런에서 매 사이클 read-only 아키텍처 Q&A 셀(SA)을 삽입해 에이전트의
(a) 인프라 구조 이해 (b) ops-read 도구로 라이브 상태 정확 응답
(c) 모르는 것 정직 고지(환각 금지) 를 검증한다. 쓰기 경로 시나리오(1~9,12,13)와
달리 인프라를 바꾸지 않는다 — 순수 조회·설명 셀이다.

## 셀 정의
- 매 사이클 **SA1(정적) + SA2(라이브)** 2개를 삽입한다. 위치는 **S1(양 env
  프로비저닝) 직후** — 라이브 질문이 실데이터를 갖도록.
- 질문은 아래 풀에서 **사이클 번호로 결정적 선택**(랜덤 대신 재현성 유지하면서
  사이클마다 변형):
  - `SA1 = STATIC[(cycle-1) % len(STATIC)]`
  - `SA2 = LIVE[(cycle-1) % len(LIVE)]`
  - LIVE 질문의 `{env}`는 사이클 홀짝으로 교대(홀수 사이클=dev, 짝수=prod).
- verbatim 전송, 자기완결(에이전트 fresh-session — "그 서버" 금지). 한 셀=한 메시지.
- 결과표에 `SA1`/`SA2` 열로 기록(사이클마다 실제 물은 질문 번호를 메모에 남긴다).

## 판정
- **pass = 답이 ground truth와 일치**(핵심 사실 정확) **+ 정직**(불확실은 명시,
  없는 값 지어내지 않음, ops-read 도구로 실조회).
- 검증은 각 질문의 "확인" 방법으로 operator가 실측 대조.
- 부분정답·환각·실측 불일치 = fail(이슈 프로토콜). **도구 미사용 추측답도 fail** —
  라이브 질문에 조회 없이 기억으로 답하면 정답이어도 fail(도구 사용이 검증 대상).

## STATIC 풀 (인프라 무관 — 코드/설정 근거, 언제든 물어도 됨)
1. `우리 인프라에서 EC2 인스턴스 타입 비용 상한이 어디서, 어떻게 강제돼?`
   - 확인: `variables.tf` validation(t3.micro/small) + guard의 비용 가드레일(`.github/`).
     **2중 강제**를 짚어야 완전 정답(한쪽만이면 부분).
2. `dev와 prod 서비스 배포는 각각 어떤 브랜치/이벤트로 트리거돼?`
   - 확인: dev 브랜치 머지→2-1-dev apply, main 머지→2-2-prod apply. branch-per-env.
3. `에이전트가 코드 PR을 직접 열 수 있는 경로와 없는 경로를 구분해줘.`
   - 확인: 가능=dev 브랜치의 `2-1-dev/`·`modules/`·`ansible/`. 불가=`.github/`·
     `scripts/`·`2-0-setup/`·`2-2-prod`(사람 소유). prod 코드는 dev→main 승격 PR.
4. `RDS는 어디서 접근 가능하고 외부 직접 경로가 있어?`
   - 확인: app+bastion SG만 5432. 외부 직접 경로 없음(프라이빗 서브넷).
5. `앱 배포가 blue-green이야? 교체가 어떻게 이뤄져?`
   - 확인: create_before_destroy + app_ready 게이트. 신 인스턴스 헬시 후 구 인스턴스 제거.
6. `monitoring 스택은 어떤 컴포넌트로 구성돼?`
   - 확인: Grafana·Prometheus·Loki·promtail(docker compose). Prometheus ec2_sd 스크레이프.
7. `prod 리소스 삭제는 어떤 승인 게이트를 거쳐?`
   - 확인: Slack 사전 승인 요청+인프라 멘션 → CODEOWNERS 사람 머지. dev는 무개입 auto.
8. `에이전트가 인프라를 바꿀 수 있는 쓰기 경로가 뭐뭐야?`
   - 확인: PR-only — (a) tfvars surface PR(dev·prod), (b) dev 한정 코드 PR,
     (c) ansible dispatch. **로컬 terraform apply 없음**(2-0-setup 부트스트랩 예외).

## LIVE 풀 (ops-read 도구 필요 — S1 이후 실데이터, `{env}`는 홀짝 교대)
1. `지금 {env} ALB 뒤에 앱 인스턴스 몇 대가 running이고 헬시해?`
   - 확인: `describe-instances` + ALB target health. baseline 2대·2/2 healthy.
2. `{env} 서비스의 현재 /data 디스크 크기는?`
   - 확인: `describe-volumes`/df. 사이클 baseline(리셋 후 10, S4 후 40).
3. `지금 열려 있는 {env} EC2 SSH allowlist 엔트리가 있어?`
   - 확인: `{env}/ec2-ssh.auto.tfvars.json` + SG describe. 리셋 후 비어 있어야.
4. `{env} RDS 엔드포인트가 지금 존재해?`
   - 확인: `describe-db-instances`. 서비스 up이면 존재, destroy면 없음.
5. `지금 활성화된 Cloudflare WAF 룰 있어?`
   - 확인: CF API `http_request_firewall_custom`. 리셋 후 비어야, S6 후 block 룰.
6. `{env} 서비스에 지금 임시 DB 계정이 붙어 있어?`
   - 확인: `db_grants` surface + RDS role. 리셋 후 없음, S3 후 존재(만료 전).

주의: 라이브 질문은 **그 시점 상태에 의존**한다 — S1 직후면 fresh baseline,
후반이면 앞 시나리오가 만든 상태가 반영된다. operator는 **질문 시점의 실상태**를
기준으로 판정한다(에이전트가 "지금" 상태를 정확히 읽었는지가 핵심).
