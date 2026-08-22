import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "validate_access_expiry.py"

spec = importlib.util.spec_from_file_location("validate_access_expiry", SCRIPT_PATH)
validate_access_expiry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validate_access_expiry)


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")


class ValidateAccessExpiryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.now = datetime(2026, 7, 27, tzinfo=timezone.utc)
        self.db_grant = {
            "cidr": "203.0.113.10/32",
            "expires_at": "2026-07-26T23:59:59Z",
        }
        write_json(
            self.root / "2-2-prod/db-access.auto.tfvars.json",
            {"db_grants": {"alice": self.db_grant}},
        )
        write_json(
            self.root / "2-2-prod/ec2-ssh.auto.tfvars.json",
            {"ec2_ssh_allowlist": {}},
        )

    def tearDown(self):
        self.tmp.cleanup()

    def write_revocations(self, db=None, ssh=None):
        write_json(
            self.root / "2-2-prod/access-expiry.auto.tfvars.json",
            {
                "access_expiry_revocations": {
                    "db_grants": db or {},
                    "ec2_ssh_allowlist": ssh or {},
                }
            },
        )

    def test_accepts_matching_expired_fingerprint(self):
        self.write_revocations(db={"alice": self.db_grant})

        self.assertEqual(validate_access_expiry.validate(self.root, self.now), [])

    def test_rejects_future_grant(self):
        future = {
            "cidr": "203.0.113.11/32",
            "expires_at": "2026-07-27T00:00:00Z",
        }
        write_json(
            self.root / "2-2-prod/ec2-ssh.auto.tfvars.json",
            {"ec2_ssh_allowlist": {"bob": future}},
        )
        self.write_revocations(ssh={"bob": future})

        errors = validate_access_expiry.validate(self.root, self.now)

        self.assertTrue(any("not expired" in error for error in errors), errors)

    def test_rejects_removing_revocation_for_still_expired_grant(self):
        self.write_revocations()

        errors = validate_access_expiry.validate(self.root, self.now)

        self.assertTrue(any("missing its revocation" in error for error in errors))

    def test_rejects_unknown_or_mismatched_grant(self):
        self.write_revocations(
            db={
                "alice": {
                    "cidr": "203.0.113.99/32",
                    "expires_at": self.db_grant["expires_at"],
                },
                "unknown": self.db_grant,
            }
        )

        errors = validate_access_expiry.validate(self.root, self.now)

        self.assertTrue(any("does not match" in error for error in errors), errors)
        self.assertTrue(any("does not exist" in error for error in errors), errors)

    def test_rejects_extra_schema_fields(self):
        fingerprint = dict(self.db_grant, requester="alice")
        self.write_revocations(db={"alice": fingerprint})

        errors = validate_access_expiry.validate(self.root, self.now)

        self.assertTrue(any("exactly cidr and expires_at" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
