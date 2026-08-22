---
name: pr-policy-approve
description: >
  GitHub pull_request 웹훅으로 도착한 장애 조치 PR을 정책 승인자 파이프라인으로
  검증할 때 사용한다. 판정 주체는 이 스킬이 아니라 policy_approver.py다 — 이
  스킬의 역할은 스크립트를 한 번 실행하고 결과를 보고하는 것뿐이다.
version: 0.1.0
author: ops-agent-iac
---

# pr-policy-approve

승인자 프로필 전용. 웹훅 프롬프트에 실린 PR 번호에 대해 정책 승인자를 one-shot
모드로 실행하고, 판정 결과를 그대로 보고한다.

## 절차

1. 프롬프트에서 PR 번호를 확인한다.
2. 정확히 다음 한 줄을 실행한다 (guard 대기 포함 최대 10분 걸릴 수 있다):

```bash
set -a; source ~/policy-approver/policy-approver.env; set +a
python3 ~/policy-approver/policy_approver.py --check-pr <PR번호>
```

3. 출력 마지막 판정 라인을 근거로 결과를 보고한다:
   - `approved and merged` → "PR #N 자동 승인·머지 완료" + 알람·변경값 요약 + PR 링크
   - `skip ...` → "PR #N 승인 보류" + skip 사유 원문 그대로
   - `error ...` → "승인자 오류" + 오류 원문 그대로

## 금지

- 스크립트 판정을 뒤집는 행동 금지: 직접 approve/merge/close, 스크립트 재실행으로
  결과 뒤집기, skip 사유에 대한 우회 시도 전부 금지. 스크립트가 skip이면 skip이
  최종 결론이다.
- 다른 리포·다른 PR에 대한 조작 금지. 프롬프트에 없는 PR 번호를 만들어내지 않는다.
- env 파일 내용(PAT·토큰)을 출력·보고에 포함하지 않는다.
