#!/usr/bin/env bash
#
# scripts/ansible-inventory.sh — 프로젝트 app/bastion 플릿(tag:Role=app|bastion)의 SSH 인벤토리 생성.
#
# 이 리포의 ansible은 self-hosted gha-runner(.github/workflows/ansible-ops.yml) 또는
# 수강생 Mac에서 SSH로 실행한다 (모든 앱 EC2에는 2-0-setup의 <project> 키와
# 공유 접근 SG(<project>)가 붙어 있다). 이 스크립트는 이 프로젝트가 만든 앱 플릿의
# running 인스턴스 IP를 조회해 INI 인벤토리를 출력한다.
#
# 기본 경로는 ansible/inventory/aws_ec2.yml (aws_ec2 동적 인벤토리 — 파일 생성 없음).
# 이 스크립트는 boto3/amazon.aws 컬렉션을 못 쓰는 환경용 fallback이다.
#
# Usage (인자 = 프로젝트 이름, 기본 ops-agent-iac):
#   bash scripts/ansible-inventory.sh > /tmp/inv.ini
#   ansible-playbook -i /tmp/inv.ini ansible/disk-grow.yml
#   # dev/prod가 동시에 떠 있으면 둘 다 잡힌다. 2번째 인자로 env(dev|prod) 스코프.
#   bash scripts/ansible-inventory.sh ops-agent-iac prod > /tmp/inv.ini
#
#   # 특정 인스턴스만 겨냥: 출력에서 해당 IP만 남기거나 --limit <ip> 사용
#
# 롤링(한 대씩, 첫 실패에서 중단)은 플레이북 쪽에서 --forks 1 + any_errors_fatal
# 또는 실행 시 `ansible-playbook ... -f 1`로 잡는다 (과거 SSM dispatch의
# --max-concurrency 1 --max-errors 0에 해당).
#
set -euo pipefail

PROJECT="${1:-ops-agent-iac}"
ENV="${2:-}" # 선택: dev | prod (비면 두 환경 모두). dev/prod가 동시에 떠 있으므로 스코프용.
REGION="${AWS_REGION:-ap-northeast-2}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ops-agent-iac}"

env_filter=()
[ -n "$ENV" ] && env_filter=("Name=tag:Environment,Values=${ENV}")

# Role 태그로 조회한다(primary 동적 인벤토리 ansible/inventory/aws_ec2.yml와 동일 기준).
query_role() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Role,Values=$1" "Name=instance-state-name,Values=running" "${env_filter[@]}" \
    --query 'Reservations[].Instances[].PublicIpAddress' --output text | tr '\t' '\n' | sed '/^None$/d;/^$/d'
}

app_ips=$(query_role app)
bastion_ips=$(query_role bastion)

if [ -z "${app_ips}${bastion_ips}" ]; then
  echo "ERROR: Role=app/bastion running 인스턴스가 없습니다 (env=${ENV:-all}, 리전 ${REGION})" >&2
  exit 1
fi

vars_block() {
  echo
  echo "[$1:vars]"
  echo "ansible_user=ubuntu"
  echo "ansible_ssh_private_key_file=${SSH_KEY}"
  echo "ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'"
}

echo "[role_app]"
echo "$app_ips"
vars_block role_app
echo
echo "[role_bastion]"
echo "$bastion_ips"
vars_block role_bastion

# env 스코프를 줬을 때는 동적 인벤토리(aws_ec2.yml)와 같은 이름의 env_<env> 그룹도
# 만든다 — 플레이북 안내( --limit env_dev|env_prod )가 이 인벤토리에서도 그대로 먹도록.
if [ -n "$ENV" ]; then
  echo
  echo "[env_${ENV}:children]"
  echo "role_app"
  echo "role_bastion"
fi
