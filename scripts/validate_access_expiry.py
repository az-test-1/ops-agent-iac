#!/usr/bin/env python3
"""Validate that the prod expiry overlay can revoke only already-expired grants."""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


REVOCATIONS_PATH = Path("2-2-prod/access-expiry.auto.tfvars.json")
REVOCATIONS_KEY = "access_expiry_revocations"
SOURCES = {
    "db_grants": Path("2-2-prod/db-access.auto.tfvars.json"),
    "ec2_ssh_allowlist": Path("2-2-prod/ec2-ssh.auto.tfvars.json"),
}
FINGERPRINT_KEYS = {"cidr", "expires_at"}


def parse_expires_at(value):
    """Parse ISO 8601, treating a trailing Z or a naive timestamp as UTC."""
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        return None, "{}: cannot read valid JSON: {}".format(path, exc)


def validate(root, now):
    """Return policy errors for the current prod revocation file."""
    errors = []
    path = root / REVOCATIONS_PATH
    document, error = load_json(path)
    if error:
        return [error]
    if not isinstance(document, dict) or set(document) != {REVOCATIONS_KEY}:
        return [
            "{}: expected the single top-level key {!r}".format(
                path, REVOCATIONS_KEY
            )
        ]

    revocations = document[REVOCATIONS_KEY]
    if not isinstance(revocations, dict) or set(revocations) != set(SOURCES):
        return [
            "{}: {!r} must contain exactly {}".format(
                path, REVOCATIONS_KEY, ", ".join(sorted(SOURCES))
            )
        ]

    sources = {}
    for surface, relative_path in SOURCES.items():
        source_path = root / relative_path
        source_document, error = load_json(source_path)
        if error:
            errors.append(error)
            continue
        if not isinstance(source_document, dict) or not isinstance(
            source_document.get(surface), dict
        ):
            errors.append(
                "{}: expected a top-level {!r} object".format(source_path, surface)
            )
            continue
        sources[surface] = source_document[surface]

    if errors:
        return errors

    for surface in sorted(SOURCES):
        entries = revocations[surface]
        if not isinstance(entries, dict):
            errors.append(
                "{}: {}.{} must be an object".format(
                    path, REVOCATIONS_KEY, surface
                )
            )
            continue

        expected_expired = set()
        for grant_id, grant in sources[surface].items():
            if not isinstance(grant, dict):
                continue
            expires_raw = grant.get("expires_at")
            if not isinstance(expires_raw, str) or not expires_raw.strip():
                continue
            try:
                expires = parse_expires_at(expires_raw)
            except (TypeError, ValueError, AttributeError):
                continue
            if expires < now:
                expected_expired.add(grant_id)

        missing = sorted(expected_expired - set(entries))
        for grant_id in missing:
            errors.append(
                "{}/{}: expired source grant is missing its revocation".format(
                    surface, grant_id
                )
            )

        for grant_id in sorted(entries):
            fingerprint = entries[grant_id]
            label = "{}/{}".format(surface, grant_id)
            if not isinstance(fingerprint, dict) or set(fingerprint) != FINGERPRINT_KEYS:
                errors.append(
                    "{}: fingerprint must contain exactly cidr and expires_at".format(
                        label
                    )
                )
                continue

            grant = sources[surface].get(grant_id)
            if not isinstance(grant, dict):
                errors.append("{}: source grant does not exist".format(label))
                continue
            if fingerprint["cidr"] != grant.get("cidr") or fingerprint[
                "expires_at"
            ] != grant.get("expires_at"):
                errors.append(
                    "{}: fingerprint does not match the CODEOWNERS-owned source".format(
                        label
                    )
                )
                continue

            try:
                expires = parse_expires_at(fingerprint["expires_at"])
            except (TypeError, ValueError, AttributeError):
                errors.append("{}: expires_at is not parseable".format(label))
                continue
            if expires >= now:
                errors.append(
                    "{}: grant is not expired (expires_at={} now={})".format(
                        label,
                        fingerprint["expires_at"],
                        now.isoformat().replace("+00:00", "Z"),
                    )
                )

    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
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
    args = parser.parse_args(argv)
    now = parse_expires_at(args.now) if args.now else datetime.now(timezone.utc)

    errors = validate(args.root, now)
    for error in errors:
        print("ERROR: {}".format(error), file=sys.stderr)
    if errors:
        return 1
    print("prod access-expiry policy valid (revocations match expired source grants)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
