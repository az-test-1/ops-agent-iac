import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class AccessExpiryGovernanceTest(unittest.TestCase):
    def read(self, relative_path):
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def test_prod_grant_sources_stay_owned_and_only_revocations_are_unowned(self):
        rules = self.read(".github/CODEOWNERS").splitlines()

        self.assertRegex(
            next(line for line in rules if line.startswith("/2-2-prod/db-access")),
            r"\s@wo-o$",
        )
        self.assertRegex(
            next(line for line in rules if line.startswith("/2-2-prod/ec2-ssh")),
            r"\s@wo-o$",
        )
        revocation_rule = next(
            line for line in rules if line.startswith("/2-2-prod/access-expiry")
        )
        self.assertEqual(
            revocation_rule, "/2-2-prod/access-expiry.auto.tfvars.json"
        )

    def test_auto_merge_limits_prod_expiry_to_fixed_bot_branch_and_single_file(self):
        workflow = self.read(".github/workflows/auto-merge.yml")

        self.assertIn('"2-2-prod/access-expiry.auto.tfvars.json"', workflow)
        self.assertIn('"ops/access-expiry-prod"', workflow)
        self.assertIn(
            '[ "$FILES" != "2-2-prod/access-expiry.auto.tfvars.json" ]', workflow
        )
        self.assertIn("--match-head-commit", workflow)
        self.assertNotIn("2-2-prod/db-access.auto.tfvars.json", workflow)
        self.assertNotIn("2-2-prod/ec2-ssh.auto.tfvars.json", workflow)

    def test_required_guard_includes_expiry_policy(self):
        workflow = self.read(".github/workflows/tf-plan.yml")

        self.assertRegex(
            workflow,
            re.compile(
                r"detect:\n.*?python3 scripts/validate_access_expiry.py.*?"
                r"guard:\n.*?needs: \[detect, plan, ansible-syntax\]",
                re.DOTALL,
            ),
        )

    def test_prod_workflow_commits_revocation_file_not_owned_sources(self):
        workflow = self.read(".github/workflows/access-expiry.yml")

        self.assertIn(
            'changed_paths=("${env_dir}/access-expiry.auto.tfvars.json")', workflow
        )
        self.assertIn('--environment "${env_name}"', workflow)

    def test_terraform_consumes_only_fingerprint_matching_active_maps(self):
        module = self.read("modules/service/main.tf")

        self.assertIn("active_ec2_ssh_allowlist", module)
        self.assertIn("active_db_grants", module)
        self.assertIn(
            "var.access_expiry_revocations.ec2_ssh_allowlist[k].cidr", module
        )
        self.assertIn(
            "var.access_expiry_revocations.db_grants[k].expires_at", module
        )


if __name__ == "__main__":
    unittest.main()
