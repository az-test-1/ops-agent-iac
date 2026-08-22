# 사람 소유 파일 — 에이전트는 *.tf를 절대 편집하면 안 된다.
#
# app: 실제로 RDS(PostgreSQL)를 쓰는 가벼운 API. :8080에서 뜬다.
#   GET  /healthz      → 200 (ALB health check, DB 불필요 — 가볍게)
#   GET  /             → 200 서비스 정보 + DB 연결 상태
#   GET  /items        → DB에서 items SELECT (JSON)
#   POST /items        → items INSERT (body=name)
#   GET  /troublemaker → 사전 장애(2-07): DB 커넥션을 누수시키고 CPU를 태우며
#                        ERROR 로그를 남기고 500. 특정 경로로 질의하면 장애가 재현되고,
#                        메트릭(CPU↑)·로그(ERROR)·DB 커넥션 증가로 관측된다.
# 로그: /var/log/app/app.log (2-07 로그 조회 대상, promtail이 있으면 job=app).
#
# 앱 코드는 이 파일에 인라인하지 않고 별도 퍼블릭 리포 wo-o/ops-agent-app에 있다.
# user_data는 그 리포를 var.app_version 태그로 clone → install.sh로 배치하고,
# 데이터 볼륨(/data) 포맷·마운트까지 처리한다 — 초기 세팅은 apply만으로 완결되며
# ansible이 필요 없다(모니터링 에이전트 설치만 2-3 실습에서 별도로 한다).
# 인프라 정의(*.tf)와 애플리케이션 코드를 분리하기 위함.
#
# 단순화: RDS master 비밀번호는 Secrets Manager가 아니라 평문 데모 변수(var.db_password).
# state/tfvars에 들어가지만 데모 편의 우선(운영 아님). 앱은 user_data로 host/비번을 받는다.

locals {
  # cloudflare 리소스 생성 게이트. 토큰 자체는 sensitive라 for_each/count에 직접 못
  # 쓴다(TF 제약) — 존재 여부(boolean)만 nonsensitive로 벗겨 게이트로 쓴다. zone_id +
  # token 둘 다 있어야 생성, 하나라도 비면 리소스 0(fail-closed, apply 안 깨짐).
  cloudflare_ready = var.cloudflare_zone_id != "" && nonsensitive(var.cloudflare_api_token != "")

  db_host       = try(aws_db_instance.this[0].address, "")
  app_user_data = <<-EOT
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y git

    # 시크릿 env는 Terraform만 아는 값(db_host·비번)이라 여기서 작성한다.
    # 앱 코드 리포(ops-agent-app)는 이 파일을 건드리지 않으므로 시크릿이 없다.
    mkdir -p /opt/app /var/log/app
    cat >/opt/app/env <<ENV
    DB_HOST=${local.db_host}
    DB_NAME=appdb
    DB_USER=dbadmin
    DB_PASSWORD=${var.db_password}
    ENV

    # 앱 코드는 태그에 pin해서 clone → install.sh가 의존성 설치·배치·기동.
    # 브랜치가 아닌 태그라 언제 띄우든 같은 코드(재현성).
    rm -rf /tmp/ops-agent-app
    git clone --depth 1 --branch "${var.app_version}" \
      https://github.com/wo-o/ops-agent-app.git /tmp/ops-agent-app
    bash /tmp/ops-agent-app/install.sh

    # 데이터 볼륨(/data) 포맷·마운트 — 초기 세팅을 ansible 없이 부팅에서 완결한다.
    # attachment(/dev/sdf, Nitro에선 nvme 재명명)는 인스턴스 생성 뒤에 붙으므로
    # 두 번째 whole-disk가 나타날 때까지 기다린다. 안전장치는 이전 data-mount.yml과
    # 동일: 기존 파일시스템엔 절대 mkfs 하지 않고(데이터 보존), fstab은 LABEL=data
    # + nofail. 전체가 fail-open — 볼륨이 늦거나 없어도 앱 부팅은 막지 않는다.
    (
      set +e
      root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)
      data_dev=""
      for i in $(seq 1 36); do
        for d in $(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
          if [ "$(basename "$d")" != "$root_disk" ]; then data_dev="$d"; break; fi
        done
        [ -n "$data_dev" ] && break
        sleep 5
      done
      if [ -z "$data_dev" ]; then echo "data volume not attached after 180s — skip mount"; exit 0; fi
      fstype=$(blkid -o value -s TYPE "$data_dev")
      if [ -z "$fstype" ]; then
        mkfs.ext4 -L data "$data_dev"
      elif [ "$fstype" = "ext4" ]; then
        e2label "$data_dev" data
      fi
      mkdir -p /data
      grep -q " /data " /etc/fstab || echo "LABEL=data /data ext4 defaults,nofail 0 2" >>/etc/fstab
      mountpoint -q /data || mount /data
      findmnt -no SOURCE,TARGET /data
    ) || true
  EOT
}

# =============================================================================
# 2-05 DNS (Cloudflare) — 실습 필수 단계 (dev/prod 공통). 2-06 WAF는 2-2-prod 소유.
# 리소스 생성 조건: service_enabled + zone_id + api_token 모두 있어야 한다. zone_id는
# env.auto.tfvars에, api_token은 GitHub secret CLOUDFLARE_API_TOKEN에 항상 채운다.
# 토큰이나 zone_id가 비면 리소스 0 → provider가 호출되지 않아 apply가 깨지지 않는
# fail-closed는 배선 실패 대비 안전장치일 뿐, 정상 실습에선 셋 다 채워 실제 반영한다.
# =============================================================================
resource "cloudflare_record" "app" {
  for_each = var.service_enabled && local.cloudflare_ready ? var.dns_records : {}
  zone_id  = var.cloudflare_zone_id
  type     = each.value.type
  name     = each.value.name
  content  = each.value.content
  proxied  = each.value.proxied
}

# 2-06 WAF는 존 공유 제약(엔트리포인트 룰셋 존당 1개) 때문에 env 모듈이 아니라
# 2-2-prod(waf.tf)가 소유한다 — 2026-07-16 e2e C1-I8(존당 1개),
# 2026-07-20 결정(WAF 수정은 prod 전용 → 구 2-4-waf 디렉터리를 prod로 통합).
