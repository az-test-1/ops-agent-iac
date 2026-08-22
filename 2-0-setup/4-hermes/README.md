# 4-hermes — Hermes 호스트에 ops 플러그인 설치·배선 (수동)

실행 순서의 마지막 단계. 1~4(bootstrap·foundation·github·grafana) 이후,
foundation이 만든 hermes 호스트에 에이전트(read + write)를 올린다.

전제:
- `1-foundation` apply 완료 → hermes 호스트 running + `<project>-hermes-readonly` 롤.
- `3-grafana` apply 완료 → `ops_grafana_token` 존재.
- Hermes 설치·플러그인 배포는 **수동 실습** (user_data는 curl+git+gh 프리앰블만).

호스트 IP:
```bash
HERMES_IP=$(terraform -chdir=../1-foundation output -raw hermes_host_public_ip)
```

---

## 1. GitHub App 발급 — 에이전트 write 정체성 (로컬 Mac, 브라우저 필요)

에이전트가 PR을 봇 이름으로 열려면 GitHub App이 필요하다. **로컬에서** 실행:
```bash
gh auth login                                   # 아직 로그인 안 했으면
python3 ../2-github/create_github_app.py         # 브라우저 열림 → Create GitHub App 클릭
#   → 끝나며 설치 링크 출력: https://github.com/apps/<slug>/installations/new
#   그 링크로 가서 '본인 리포만' 선택해 Install
python3 ../2-github/print_install_id.py          # 설치 후 실행 → installation_id 출력
```
결과물: `./.secrets/app.json`(app_id) + `./.secrets/app.pem`(private key, gitignore됨).
private key를 호스트로 복사:
```bash
scp -i ~/.ssh/ops-agent-iac .secrets/app.pem ubuntu@${HERMES_IP}:/home/ubuntu/.hermes/app.pem
```

## 2. 호스트 접속
```bash
ssh -i ~/.ssh/ops-agent-iac ubuntu@${HERMES_IP}
```

## 3. 플러그인 설치 (호스트에서)
```bash
gh auth login                                    # 플러그인 리포 접근용 (private면 필수)
hermes plugins install wo-o/ops-agent-plugin
```

## 4. `~/.hermes/.env` 배선 (read + write)

기본(필수) — 리소스 이름 프리픽스. bootstrap이 등록한 PROJECT_NAME과 반드시 일치:
```
OPS_PROJECT_PREFIX=ops-agent-iac   # = gh variable PROJECT_NAME. unused-candidates가 "<prefix>-"로 필터
```
> 플러그인 설치 시 `OPS_PROJECT_PREFIX`를 프롬프트로 물으면 `ops-agent-iac` 입력(또는 기본값 Enter).

read 자격증명 — 로컬에서 `bash ../env.sh` 출력을 그대로 붙여넣기:
```
OPS_GRAFANA_URL=...            # obs-read (Grafana/Prometheus/Loki)
OPS_GRAFANA_PUBLIC_URL=...     # 응답에 인용할 dashboard 링크 base (수강생 브라우저용 공인 IP)
OPS_GRAFANA_TOKEN=...
OPS_AWS_READ_ROLE=...          # 플러그인이 assume하는 read 경계 롤 (자체 AWS 키 없음)
# OPS_PAGERDUTY_TOKEN=...      # PagerDuty read (UI 발급, 선택 — 활성 PD 플랜 필요)
OPS_CLOUDFLARE_READ_TOKEN=...  # cloudflare read (UI 발급, 필수 — dns/waf 조회 + 엣지 5xx; 토큰에 Analytics:Read 포함)
OPS_CLOUDFLARE_ZONE_ID=...
```
write 자격증명 — 1단계 GitHub App 값:
```
OPS_GITHUB_APP_ID=<app_id>
OPS_GITHUB_PRIVATE_KEY_PATH=/home/ubuntu/.hermes/app.pem
OPS_GITHUB_INSTALLATION_ID=<installation_id>
OPS_GITHUB_REPO=<owner>/ops-agent-iac   # 본인 리포 (template으로 만든 자기 리포)
```
> 값 없는 툴셋은 자동 비활성(check gate). write(PR) 툴은 위 4개가 다 있어야 켜진다.

ansible 조치(disk-grow·security-patch·rolling-restart 등)는 **GHA self-hosted 러너**가 실행한다 —
ansible-ops.yml을 workflow_dispatch/push로 돌린다(러너에 ansible + fleet 키 보유). 에이전트는
GitHub App으로 이 워크플로를 **dispatch만** 하면 되고, Hermes엔 ansible도 키도 필요 없다
(2-3 incident-response도 ansible-ops.yml dispatch 방식).

`ops_run_ansible_playbook`도 이 경로를 쓴다 — GitHub App으로 ansible-ops.yml을 workflow_dispatch
한다(Hermes에서 직접 SSH로 도는 옛 경로는 제거됨: VPC 밖이라 fleet SG에 막히고, write는
전부 GitHub를 거친다는 원칙과도 어긋났다). 따라서 write(`OPS_GITHUB_*`)만 있으면 켜지고,
`OPS_IAC_REPO_PATH`·`OPS_ANSIBLE_SSH_KEY`는 **더 이상 필요 없다**(있어도 무시된다).

GITHUB_TOKEN(선택) — PR/워크플로 상태 read용 fallback PAT. 위 GitHub App(OPS_GITHUB_*)을
배선하면 App 토큰이 대체하므로 불필요.

## 5. 응답 언어(한국어) + 출력 형식 — `~/.hermes/SOUL.md`

언어 지시는 파일 **최상단**에 둔다(끝에 append하면 영어 기본 프롬프트에 앵커링돼 영어로 샘).
출력 형식 규칙(마크다운 표 금지 — Slack이 렌더링 못 함, 이모지 라인/코드블록 정렬로 대체)도
같은 파일에 있다. 전체 예시는 `ops-agent-plugin` README "응답 언어: 한국어 (SOUL.md)" 절.

## 6. gateway 재시작
```bash
hermes gateway restart
```

## 7. 검증 — "이게 되네"
```bash
# read 경계: 임시 자격증명은 read만
aws sts assume-role --role-arn "$OPS_AWS_READ_ROLE" --role-session-name smoke
#   → aws ec2 describe-vpcs (OK) / aws ec2 create-tags (AccessDenied)
```
- obs-read: Slack에서 에이전트에게 알람/메트릭 조회 요청 → 응답 확인 (같은 VPC private 통신 — 별도 SG 설정 불필요).
- write: 에이전트에게 surface tfvars 변경 요청 → 봇 이름으로 PR 열리는지 확인.
- Slack "Command Approval Required" 버튼이 뜨면: raw 셸(aws CLI 등) 실행 시도 = 기본 **Deny**.
  조회는 ops read 도구가 정답 경로. 상세는 ops-agent-plugin `PLUGIN.md` "명령 승인" 절.
