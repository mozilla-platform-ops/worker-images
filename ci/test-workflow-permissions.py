"""Keep OIDC token issuance in jobs that perform cloud login."""

from pathlib import Path

import yaml


root = Path(__file__).resolve().parents[1]
for path in sorted((root / ".github/workflows").glob("*.yml")):
    workflow = yaml.safe_load(path.read_text())
    defaults = workflow.get("permissions", {})
    assert defaults.get("id-token", "none") == "none", path
    for name, job in workflow["jobs"].items():
        label = f"{path.name}:{name}"
        permissions = job.get("permissions", defaults)
        cloud_login = any(
            step.get("uses", "").split("@")[0] in (
                "azure/login", "google-github-actions/auth",
                "aws-actions/configure-aws-credentials",
            )
            for step in job.get("steps", [])
        )
        assert (permissions.get("id-token") == "write") == cloud_login, label

print("Workflow OIDC permissions: only cloud login jobs can request identity tokens.")
