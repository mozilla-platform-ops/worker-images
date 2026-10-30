"""Keep repository writes in SBOM publication and OIDC in cloud login jobs."""

from pathlib import Path

import yaml


root = Path(__file__).resolve().parents[1]
publisher = "./.github/workflows/upload-release-notes.yml"
for path in sorted((root / ".github/workflows").glob("*.yml")):
    workflow = yaml.safe_load(path.read_text())
    defaults = workflow.get("permissions", {})
    assert defaults.get("id-token", "none") == "none", path
    assert defaults.get("contents", "read") in ("read", "none"), path
    for name, job in workflow["jobs"].items():
        label = f"{path.name}:{name}"
        assert "permissions" in job or "permissions" in workflow, label
        permissions = job.get("permissions", defaults)
        steps = job.get("steps", [])
        cloud_login = any(
            step.get("uses", "").split("@")[0] in (
                "azure/login", "google-github-actions/auth",
                "aws-actions/configure-aws-credentials",
            )
            for step in steps
        )
        assert (permissions.get("id-token") == "write") == cloud_login, label
        publishes = job.get("uses") == publisher or (
            path.name == "upload-release-notes.yml" and name == "sbom"
        )
        assert permissions.get("contents", "none") in (
            ("write",) if publishes else ("read", "none")
        ), label
        if publishes:
            assert permissions.get("actions") == "read", label
            assert not cloud_login, label

print("Workflow permissions: only SBOM jobs can write contents; only cloud login jobs have OIDC.")
