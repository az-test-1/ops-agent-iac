#!/usr/bin/env python3
"""에이전트 write-surface에서 만료된 임시 access grant를 회수한다.

dev/prod 두 환경 × 두 접근 유형(RDS=db_grants, EC2 SSH=ec2_ssh_allowlist)의
surface를 스윕한다. dev는 기존처럼 만료 grant를 원본 파일에서 삭제한다. prod는
CODEOWNER 보호 원본 파일을 건드리지 않고 machine-owned revocation tfvars 파일에
만료 grant id별 cidr/expires_at fingerprint를 기록한다. Terraform은 이 revocation
map을 보고 실제 적용 대상에서 제외한다.

각 엔트리의 expires_at(ISO 8601; naive/끝의 'Z'는 UTC)이 현재보다 엄격히 이전이면
회수 대상이다. expires_at이 없거나 빈 엔트리는 "영구 grant"로 보고 유지한다(dev의
상시 접근 등).

.github/workflows/access-expiry.yml 이 스케줄에 따라 호출한다. 워크플로는 여기서
생긴 diff를 PR로 만든다(자동 머지 → tf-apply가 실제 회수). RDS 임시 유저
자체(postgres role)는 ansible/rds-temp-user.yml state=absent가 별도로 DROP한다.

결정론적이다(경로 정렬, id 정렬, sort_keys JSON, 끝 개행) — 반복 실행해도 동일
출력·안정적 PR diff. 출력: dev에서 제거된 grant는 "removed", prod에서 revocation
상태에 들어간 grant는 "revoked" 한 줄, 대상이 없으면 "no expired access grants".
파싱/shape 에러에만 exit 1.

stdlib만 사용 (python3.9+).
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

GRANT_KEYS = ("db_grants", "ec2_ssh_allowlist")

# 에이전트 access surface들. dev는 원본 파일을 직접 정리하고, prod는 revocation
# 파일만 갱신한다.
DEV_SURFACES = [
    ("2-1-dev/db-access.auto.tfvars.json", "db_grants"),
    ("2-1-dev/ec2-ssh.auto.tfvars.json", "ec2_ssh_allowlist"),
]
PROD_SURFACES = [
    ("2-2-prod/db-access.auto.tfvars.json", "db_grants"),
    ("2-2-prod/ec2-ssh.auto.tfvars.json", "ec2_ssh_allowlist"),
]
PROD_REVOCATIONS_PATH = "2-2-prod/access-expiry.auto.tfvars.json"
PROD_REVOCATIONS_TOP_KEY = "access_expiry_revocations"


def parse_expires_at(value):
    """ISO 8601 타임스탬프를 파싱한다; naive거나 'Z'로 끝나면 UTC로 본다."""
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def expire_file(path, now, label, top_key):
    """한 surface 파일을 스윕한다.

    반환: (removed_lines, error). error가 있으면 그 파일은 변경하지 않는다.
    expires_at이 없거나 비면 영구 grant로 보고 조용히 유지한다.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        return [], "{}: does not parse as JSON: {}".format(path, exc)
    if not isinstance(data, dict) or not isinstance(data.get(top_key), dict):
        return [], "{}: expected a top-level {!r} object".format(path, top_key)

    grants = data[top_key]
    kept = {}
    removed_lines = []
    for grant_id in sorted(grants):
        entry = grants[grant_id]
        expires_raw = entry.get("expires_at") if isinstance(entry, dict) else None
        # expires_at 미지정/빈 값 = 영구 grant → 조용히 유지.
        if expires_raw is None or (
            isinstance(expires_raw, str) and not expires_raw.strip()
        ):
            kept[grant_id] = entry
            continue
        try:
            expires = parse_expires_at(expires_raw)
        except (TypeError, ValueError, AttributeError):
            print(
                "WARNING: {}: {}: unparseable expires_at {!r} - keeping "
                "(guard will reject it)".format(label, grant_id, expires_raw),
                file=sys.stderr,
            )
            kept[grant_id] = entry
            continue
        if expires < now:
            removed_lines.append(
                "removed {}/{}: target={} cidr={} expired_at={} requester={}".format(
                    label,
                    grant_id,
                    entry.get("target", "?"),
                    entry.get("cidr", "?"),
                    entry.get("expires_at"),
                    entry.get("requester", "") or "-",
                )
            )
        else:
            kept[grant_id] = entry

    if len(kept) != len(grants):
        data[top_key] = kept
        path.write_text(
            json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    return removed_lines, None


def read_grants(path, top_key):
    """grant surface를 읽어 top_key object를 반환한다."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        return None, "{}: does not parse as JSON: {}".format(path, exc)
    if not isinstance(data, dict) or not isinstance(data.get(top_key), dict):
        return None, "{}: expected a top-level {!r} object".format(path, top_key)
    return data[top_key], None


def empty_revocations():
    return {PROD_REVOCATIONS_TOP_KEY: {key: {} for key in GRANT_KEYS}}


def read_revocations(path):
    """prod revocation tfvars를 읽는다. 파일이 없으면 빈 schema로 시작한다."""
    if not path.exists():
        return empty_revocations(), None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        return None, "{}: does not parse as JSON: {}".format(path, exc)
    if not isinstance(data, dict) or set(data) != {PROD_REVOCATIONS_TOP_KEY}:
        return None, "{}: expected the single top-level key {!r}".format(
            path, PROD_REVOCATIONS_TOP_KEY
        )

    revocations = data[PROD_REVOCATIONS_TOP_KEY]
    if not isinstance(revocations, dict):
        return None, "{}: expected a top-level {!r} object".format(
            path, PROD_REVOCATIONS_TOP_KEY
        )
    if set(revocations) != set(GRANT_KEYS):
        return None, "{}: {!r} must contain exactly {}".format(
            path, PROD_REVOCATIONS_TOP_KEY, ", ".join(sorted(GRANT_KEYS))
        )
    for key in GRANT_KEYS:
        if not isinstance(revocations[key], dict):
            return None, "{}: expected {!r}.{} to be an object".format(
                path, PROD_REVOCATIONS_TOP_KEY, key
            )
    return data, None


def desired_prod_revocations(root, now):
    """prod 원본 grant에서 현재 유효한 revocation map을 재계산한다."""
    desired = {key: {} for key in GRANT_KEYS}
    detail_lines = {}
    errors = []
    found_any = False

    for relative_path, top_key in PROD_SURFACES:
        path = root / relative_path
        if not path.exists():
            continue
        found_any = True
        label = "{}/{}".format(path.parent.name, top_key)
        grants, error = read_grants(path, top_key)
        if error:
            errors.append(error)
            continue

        for grant_id in sorted(grants):
            entry = grants[grant_id]
            expires_raw = entry.get("expires_at") if isinstance(entry, dict) else None
            if expires_raw is None or (
                isinstance(expires_raw, str) and not expires_raw.strip()
            ):
                continue
            try:
                expires = parse_expires_at(expires_raw)
            except (TypeError, ValueError, AttributeError):
                print(
                    "WARNING: {}: {}: unparseable expires_at {!r} - keeping "
                    "(guard will reject it)".format(label, grant_id, expires_raw),
                    file=sys.stderr,
                )
                continue
            if expires < now:
                desired[top_key][grant_id] = {
                    "cidr": entry.get("cidr"),
                    "expires_at": entry.get("expires_at"),
                }
                detail_lines[(top_key, grant_id)] = (
                    "revoked {}/{}: target={} cidr={} expired_at={} requester={}".format(
                        label,
                        grant_id,
                        entry.get("target", "?") if isinstance(entry, dict) else "?",
                        entry.get("cidr", "?") if isinstance(entry, dict) else "?",
                        entry.get("expires_at") if isinstance(entry, dict) else "-",
                        (entry.get("requester", "") if isinstance(entry, dict) else "")
                        or "-",
                    )
                )

    return desired, detail_lines, errors, found_any


def expire_dev(root, now):
    all_removed = []
    errors = []
    found_any = False
    for relative_path, top_key in DEV_SURFACES:
        path = root / relative_path
        if not path.exists():
            continue
        found_any = True
        label = "{}/{}".format(path.parent.name, top_key)
        removed, error = expire_file(path, now, label, top_key)
        if error:
            errors.append(error)
            continue
        all_removed.extend(removed)
    return all_removed, errors, found_any


def expire_prod(root, now):
    desired, detail_lines, errors, found_any = desired_prod_revocations(root, now)
    if errors:
        return [], errors, found_any

    path = root / PROD_REVOCATIONS_PATH
    data, error = read_revocations(path)
    if error:
        return [], [error], found_any

    current = data[PROD_REVOCATIONS_TOP_KEY]
    lines = []
    for top_key in GRANT_KEYS:
        for grant_id in sorted(desired[top_key]):
            if current[top_key].get(grant_id) != desired[top_key][grant_id]:
                lines.append(detail_lines[(top_key, grant_id)])
        for grant_id in sorted(set(current[top_key]) - set(desired[top_key])):
            lines.append(
                "cleared stale revocation {}/{}".format(top_key, grant_id)
            )

    updated = dict(data)
    updated[PROD_REVOCATIONS_TOP_KEY] = desired
    if updated != data:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(updated, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    return lines, [], found_any


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (default: parent of scripts/)",
    )
    parser.add_argument(
        "--now",
        default=None,
        help="override current time (ISO 8601, UTC) - for tests only",
    )
    parser.add_argument(
        "--environment",
        choices=("all", "dev", "prod"),
        default="all",
        help="which environment to sweep (default: all)",
    )
    args = parser.parse_args(argv)

    now = parse_expires_at(args.now) if args.now else datetime.now(timezone.utc)

    all_removed = []
    errors = []
    found_any = False

    if args.environment in ("all", "dev"):
        removed, dev_errors, dev_found = expire_dev(args.root, now)
        all_removed.extend(removed)
        errors.extend(dev_errors)
        found_any = found_any or dev_found

    if args.environment in ("all", "prod"):
        revoked, prod_errors, prod_found = expire_prod(args.root, now)
        all_removed.extend(revoked)
        errors.extend(prod_errors)
        found_any = found_any or prod_found

    if not found_any:
        print(
            "NOTICE: no access surfaces found under {} - nothing to expire".format(
                args.root
            )
        )
        return 0

    for error in errors:
        print("ERROR: {}".format(error), file=sys.stderr)

    if all_removed:
        for line in all_removed:
            print(line)
    else:
        print("no expired access grants")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
