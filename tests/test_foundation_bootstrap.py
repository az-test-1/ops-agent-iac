import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class FoundationBootstrapTest(unittest.TestCase):
    def read(self, relative_path):
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def run_foundation_helper(self, action, subject_prefix):
        with tempfile.TemporaryDirectory() as temp_dir:
            bin_dir = Path(temp_dir)
            terraform_args = bin_dir / "terraform-args"
            gh = bin_dir / "gh"
            gh.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -euo pipefail
                    if [ "$1 $2" = "repo view" ]; then
                      printf '%s\\n' 'octo/example'
                    elif [[ "$*" == *"/actions/oidc/customization/sub"* ]]; then
                      printf '%s\\n' "$TEST_OIDC_PREFIX"
                    elif [[ "$*" == *"/actions/runners/registration-token"* ]]; then
                      printf '%s\\n' 'test-registration-token'
                    else
                      printf 'unexpected gh arguments: %s\\n' "$*" >&2
                      exit 1
                    fi
                    """
                ),
                encoding="utf-8",
            )
            terraform = bin_dir / "terraform"
            terraform.write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > \"$TEST_TERRAFORM_ARGS\"\n",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            terraform.chmod(0o755)

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "TEST_OIDC_PREFIX": subject_prefix,
                    "TEST_TERRAFORM_ARGS": str(terraform_args),
                }
            )
            subprocess.run(
                ["bash", str(REPO_ROOT / "2-0-setup/foundation.sh"), action],
                check=True,
                cwd=REPO_ROOT,
                env=env,
                capture_output=True,
                text=True,
            )
            return terraform_args.read_text(encoding="utf-8").splitlines()

    def test_apply_preserves_name_based_oidc_prefix(self):
        args = self.run_foundation_helper("apply", "repo:octo/example")

        self.assertIn(
            "github_oidc_subject_prefix=repo:octo/example",
            args,
        )
        self.assertIn("github_runner_token=test-registration-token", args)

    def test_destroy_preserves_immutable_id_oidc_prefix(self):
        args = self.run_foundation_helper(
            "destroy", "repo:octo@123456/example@987654"
        )

        self.assertIn(
            "github_oidc_subject_prefix=repo:octo@123456/example@987654",
            args,
        )
        self.assertIn("github_runner_token=unused-during-destroy", args)

    def test_terraform_uses_api_prefix_for_exact_match_subjects(self):
        foundation = self.read("2-0-setup/1-foundation/main.tf")

        self.assertIn("repo_claim       = var.github_oidc_subject_prefix", foundation)
        self.assertIn('test     = "StringEquals"', foundation)
        self.assertNotIn(
            'repo_claim       = "repo:${var.github_owner}/${local.github_repo}"',
            foundation,
        )

    def test_targeted_refresh_also_passes_canonical_prefix(self):
        refresh = self.read("scripts/refresh-ip.sh")

        self.assertIn(
            'gh api "repos/$OWNER/$REPO/actions/oidc/customization/sub" '
            "--jq .sub_claim_prefix",
            refresh.replace("\n", " "),
        )
        self.assertIn(
            '-var "github_oidc_subject_prefix=${OIDC_SUBJECT_PREFIX}"', refresh
        )

    def test_runner_resolves_latest_stable_release(self):
        runner = self.read("2-0-setup/1-foundation/runner.tf")

        self.assertIn(
            "https://api.github.com/repos/actions/runner/releases/latest", runner
        )
        self.assertIn("RUNNER_VER=\"$${RUNNER_TAG#v}\"", runner)
        self.assertNotIn("RUNNER_VER=2.320.0", runner)


if __name__ == "__main__":
    unittest.main()
