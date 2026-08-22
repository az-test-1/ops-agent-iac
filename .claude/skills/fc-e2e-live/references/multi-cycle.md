# Multi-cycle mode (소크 런) — fc-e2e-live 보조 문서

args가 매트릭스 반복을 요청하면("10바퀴", "사이클 돌리면서") 소크 런이다.
단일 런 규칙(SKILL.md)이 기본이고, 이 문서의 규칙이 사이클 경계에서 —
그리고 배치 모드일 때는 이슈 처리에서도 — 그것을 덮어쓴다.

## 사이클 경계 상태

각 사이클은 시나리오 9로 dev·prod 서비스 스택을 전부 삭제하고 끝난다 —
"헤르메스 삭제 전까지 전부 삭제". foundation(SSH 키, 공유 SG, VPC, OIDC 롤,
hermes 호스트, gha-runner, monitoring)은 절대 건드리지 않는다. 다음 사이클은
그 빈 상태에서 시나리오 1(양 env 프로비저닝)로 시작한다. 사이클 중간 상태가
dev service_enabled 정본과 달라도 소크 런 동안은 이 규칙이 우선한다(런 종료 시
최종 상태를 보고하고 정본 확인).

**Surface 리셋 (시나리오 9 이후, 다음 사이클 1 이전 — 필수).** 서비스 스택
삭제만으로는 tfvars surface와 앱 리포 수정 PR이 남아, 다음 사이클의 시나리오
2~8이 신규 생성 대신 idempotent 재사용 경로만 탄다(실측: 리셋 없이는 매 사이클
S1·S9만 fresh — 소크 신호 급감). 각 사이클 경계에서 operator 커밋/PR로
baseline을 복원한다:
- dev 브랜치: `2-1-dev/{ec2-ssh,db-access,dns}.auto.tfvars.json` 엔트리 비우기
  (예: `{"ec2_ssh_allowlist": {}}`), `2-1-dev/disk.auto.tfvars` →
  `data_volume_size_gb = 10`, `ansible/patch-extra-packages.yml` →
  `extra_packages: []`
- main 브랜치: `2-2-prod/*` 동일 + `2-2-prod/waf.auto.tfvars.json` →
  `{"waf_rules": {}}` + `ansible/patch-extra-packages.yml`
- 앱 리포: 시나리오 7이 만든 수정 PR close + 브랜치 삭제(다음 사이클이 fresh
  PR 생성 경로를 타도록)
- dev 브랜치(13a·13d 아티팩트): 13a·13d가 추가한 `ansible/<name>.yml` 삭제 +
  `ansible/playbooks.yml` 등록 원복(`playbooks: []`) + 13d의 `ansible/specs/<name>.yml`
  삭제 — 안 지우면 다음 사이클이 "이미 존재"로 no-op이 돼 추가·등록·syntax-check·
  specs 게이트 경로가 미검증된다. 파일 삭제는 봇 코드 PR이 못 하므로
  (open_code_pr는 삭제 미지원) operator PR로 처리
- dns는 시나리오가 추가한 엔트리만 제거하고 사전 존재 인프라 레코드는 유지
- 주의: 스택이 내려간 상태라 대부분 no-op apply지만, waf 리셋은 존 전역
  Cloudflare 룰을 실제로 destroy한다(의도된 동작). operator PR은 봇 필터에
  안 걸려 auto-merge가 안 붙는다 — guard 통과 후 직접 머지한다.
- **direct push 금지 (리셋도 PR로).** push 트리거 tf-apply는 dflook이 커밋에
  연결된 PR의 plan을 재생하는 구조라, PR 없는 direct push는 변경이 하나라도
  있으면 "No PR found" apply 실패 → 드리프트가 된다(실측: waf 리셋 direct push
  → cloudflare 룰 destroy 미반영). 변경 0이면 우연히 통과하므로 dev에서 되고
  main에서 깨지는 식으로 비대칭 실패한다. 이미 direct push했다면
  `gh workflow run tf-apply.yml --ref <branch>`(dispatch는 auto_approve 즉석
  plan)로 회수하고 run 성공 + destroy 카운트를 확인한다.

## 아키텍처 질문 셀 (SA — 사이클마다 변형)

쓰기 경로 시나리오(1~9,12,13)만 반복하면 에이전트의 **인프라 이해·라이브 조회·정직
응답** 역량이 검증되지 않는다. 매 사이클 read-only 아키텍처 Q&A 셀을 삽입한다 —
`references/architecture-questions.md`의 풀에서 사이클 번호로 결정적 선택(랜덤
대신 재현성 유지하면서 사이클마다 변형)한 **SA1(정적)+SA2(라이브)** 2개.

- 위치: **S1(양 env 프로비저닝) 직후** — 라이브 질문이 실데이터를 갖도록.
- 선택: `SA1=STATIC[(cycle-1)%N]`, `SA2=LIVE[(cycle-1)%M]`, LIVE의 `{env}`는
  사이클 홀짝 교대(홀수=dev, 짝수=prod).
- 판정: 답이 ground truth와 일치 + 정직(불확실 명시·환각 없음·ops-read 실조회).
  도구 미사용 추측답은 정답이어도 fail. 상세 확인법은 references 문서.
- 결과표에 SA1·SA2 열 추가(사이클당 실제 물은 질문 번호를 사이클 메모에 기록).
- 인프라를 바꾸지 않으므로 사이클 경계 리셋·destroy 대상이 아니다.

## 이슈 처리 — 모드 선택과 공통 규칙

args가 수정 타이밍을 지시하지 않으면 **배치 모드**(기본)다. args가 "장애나면
바로/즉시 수정하고 재테스트"류를 지시하면 **즉시수정 모드**다. 모드는 런 시작
시 한 번 정해 findings doc 머리의 런 규칙에 기록하고, 런 도중 바꾸지 않는다.

두 모드 공통:
- **사이클 요약.** 각 사이클 종료 시 findings doc에 결과 표(24셀 —
  1~9×{dev,prod} + 12a/b/c + 13a/b/c/d — 및 SA1·SA2 아키텍처 질문 2셀)와 이슈 수, 수정 커밋
  해시를 기록하고 체크리스트를
  초기화한다. 세션이 끊겨도 이 문서와 체크리스트만으로 재개 가능해야 한다.
- **중복 이슈는 카운트.** 같은 이슈가 여러 사이클에서 재발하면 새 항목 대신
  기존 항목에 재발 사이클을 추가한다 — 배치 모드에선 재발 빈도가 우선순위
  신호고, 즉시수정 모드에선 이전 사이클의 수정이 실효였는지의 신호다.

### 배치 모드 (기본 — 사이클 중에는 고치지 않고 기록한다)

1. **기록 우선.** 사이클 도중 발견한 이슈는 즉시 수정하지 않고 findings doc의
   `## Cycle K — issues`에 기록한다(증상/증거 링크/의심 원인/blocking 여부).
   수정 없이 다음 셀로 진행한다.
2. **Blocking 예외 = 응급 unblock만.** 이후 셀 진행을 막는 상태(예: 머지됐지만
   apply가 계속 실패하는 드리프트)는 최소한의 상태 복구(revert PR 등)만 즉시
   하고 "응급 unblock — 근본수정은 배치로"라고 기록한다. 근본 수정은 배치 창까지
   미룬다.
3. **배치 수정 창.** 사이클이 끝나면(9번 destroy 완료 후) 그 사이클의 이슈를
   fault domain별로 묶어 한 번에 근본 수정한다(단일 런의 issue protocol 1·3·4·5
   기준 동일). pytest / terraform validate + hermes sync·restart는 배치당 1회로
   몰아서 한다.
4. **재검증 = 다음 사이클.** 수정 직후 같은 시나리오를 따로 재실행하지 않는다 —
   다음 사이클의 해당 셀 pass가 수정의 증명이다. 마지막 사이클에서 나온 이슈만
   수정 후 해당 시나리오를 즉시 재실행해 닫는다.

### 즉시수정 모드 (args 지시 시 — 발견 즉시 고치고 같은 셀을 닫는다)

1. **단일 런 이슈 프로토콜을 사이클 안에서 그대로 적용.** fault domain 분류 →
   root-cause 수정 → 커밋 + (plugin/SOUL이면) hermes sync·restart → 같은
   시나리오를 Slack에서 재실행해 pass한 뒤에만 다음 셀로 진행한다. pytest /
   terraform validate도 수정 건마다 그때그때 돌린다.
2. **2회 연속 실패 = 에스컬레이션.** 수정→재실행으로도 같은 셀이 2회 연속
   실패하면 같은 자리에서 계속 반복하지 않는다 — blocker로 기록하고 사용자에게
   알린 뒤 지시를 받는다(침묵 반복 금지).
3. **External은 이 모드에서도 즉시 못 고친다.** 단일 런 프로토콜대로 증거와
   함께 문서화하고 대기/보류를 사용자에게 묻는다.
4. **사이클 경계 규칙은 동일.** 시나리오 9 destroy와 surface 리셋은 배치
   모드와 같은 절차를 따른다.
