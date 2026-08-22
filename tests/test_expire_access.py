import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "expire_access.py"

spec = importlib.util.spec_from_file_location("expire_access", SCRIPT_PATH)
expire_access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(expire_access)


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


class ExpireAccessTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "2-1-dev").mkdir()
        (self.root / "2-2-prod").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        stdout = io.StringIO()
        stderr = io.StringIO()
        argv = ["--root", str(self.root), "--now", "2026-07-27T00:00:00Z", *args]
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = expire_access.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_dev_environment_removes_expired_grants_from_source_files(self):
        write_json(
            self.root / "2-1-dev" / "db-access.auto.tfvars.json",
            {
                "db_grants": {
                    "expired": {
                        "cidr": "203.0.113.10/32",
                        "expires_at": "2026-07-26T23:59:59Z",
                        "target": "app",
                    },
                    "future": {
                        "cidr": "203.0.113.11/32",
                        "expires_at": "2026-07-28T00:00:00Z",
                        "target": "app",
                    },
                    "permanent": {
                        "cidr": "203.0.113.12/32",
                        "expires_at": "",
                        "target": "app",
                    },
                }
            },
        )
        write_json(
            self.root / "2-1-dev" / "ec2-ssh.auto.tfvars.json",
            {"ec2_ssh_allowlist": {}},
        )

        code, stdout, stderr = self.run_script("--environment", "dev")

        self.assertEqual(code, 0, stderr)
        self.assertIn("removed 2-1-dev/db_grants/expired", stdout)
        grants = read_json(self.root / "2-1-dev" / "db-access.auto.tfvars.json")[
            "db_grants"
        ]
        self.assertEqual(sorted(grants), ["future", "permanent"])

    def test_prod_environment_writes_revocations_without_changing_sources(self):
        db_source = {
            "db_grants": {
                "expired-db": {
                    "cidr": "203.0.113.20/32",
                    "expires_at": "2026-07-26T23:59:59Z",
                    "requester": "alice",
                    "target": "app",
                },
                "future-db": {
                    "cidr": "203.0.113.21/32",
                    "expires_at": "2026-07-28T00:00:00Z",
                    "target": "app",
                },
            }
        }
        ssh_source = {
            "ec2_ssh_allowlist": {
                "expired-ssh": {
                    "cidr": "203.0.113.22/32",
                    "expires_at": "2026-07-26T23:59:59+00:00",
                    "target": "bastion",
                },
                "permanent-ssh": {
                    "cidr": "203.0.113.23/32",
                    "target": "bastion",
                },
            }
        }
        write_json(self.root / "2-2-prod" / "db-access.auto.tfvars.json", db_source)
        write_json(self.root / "2-2-prod" / "ec2-ssh.auto.tfvars.json", ssh_source)

        code, stdout, stderr = self.run_script("--environment", "prod")

        self.assertEqual(code, 0, stderr)
        self.assertIn("revoked 2-2-prod/db_grants/expired-db", stdout)
        self.assertIn("revoked 2-2-prod/ec2_ssh_allowlist/expired-ssh", stdout)
        self.assertEqual(
            read_json(self.root / "2-2-prod" / "db-access.auto.tfvars.json"),
            db_source,
        )
        self.assertEqual(
            read_json(self.root / "2-2-prod" / "ec2-ssh.auto.tfvars.json"),
            ssh_source,
        )
        self.assertEqual(
            read_json(self.root / "2-2-prod" / "access-expiry.auto.tfvars.json"),
            {
                "access_expiry_revocations": {
                    "db_grants": {
                        "expired-db": {
                            "cidr": "203.0.113.20/32",
                            "expires_at": "2026-07-26T23:59:59Z",
                        }
                    },
                    "ec2_ssh_allowlist": {
                        "expired-ssh": {
                            "cidr": "203.0.113.22/32",
                            "expires_at": "2026-07-26T23:59:59+00:00",
                        }
                    },
                }
            },
        )

        code, stdout, stderr = self.run_script("--environment", "prod")
        self.assertEqual(code, 0, stderr)
        self.assertEqual(stdout, "no expired access grants\n")

    def test_prod_environment_prunes_stale_revocations(self):
        write_json(
            self.root / "2-2-prod" / "db-access.auto.tfvars.json",
            {
                "db_grants": {
                    "renewed": {
                        "cidr": "203.0.113.24/32",
                        "expires_at": "2026-07-28T00:00:00Z",
                        "target": "app",
                    }
                }
            },
        )
        write_json(
            self.root / "2-2-prod" / "ec2-ssh.auto.tfvars.json",
            {"ec2_ssh_allowlist": {}},
        )
        write_json(
            self.root / "2-2-prod" / "access-expiry.auto.tfvars.json",
            {
                "access_expiry_revocations": {
                    "db_grants": {
                        "renewed": {
                            "cidr": "203.0.113.24/32",
                            "expires_at": "2026-07-26T23:59:59Z",
                        }
                    },
                    "ec2_ssh_allowlist": {
                        "deleted": {
                            "cidr": "203.0.113.25/32",
                            "expires_at": "2026-07-26T23:59:59Z",
                        }
                    },
                }
            },
        )

        code, stdout, stderr = self.run_script("--environment", "prod")

        self.assertEqual(code, 0, stderr)
        self.assertIn("cleared stale revocation db_grants/renewed", stdout)
        self.assertIn(
            "cleared stale revocation ec2_ssh_allowlist/deleted", stdout
        )
        self.assertEqual(
            read_json(self.root / "2-2-prod" / "access-expiry.auto.tfvars.json"),
            {
                "access_expiry_revocations": {
                    "db_grants": {},
                    "ec2_ssh_allowlist": {},
                }
            },
        )


if __name__ == "__main__":
    unittest.main()
