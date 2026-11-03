"""Keep repository writes in SBOM publication and OIDC in cloud login jobs."""

from pathlib import Path

import yaml

from sbom_pr import WORKFLOWS


root = Path(__file__).resolve().parents[1]
publisher = "./.github/workflows/upload-release-notes.yml"
callers = set()
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
        merges = path.name == "merge-sbom.yml" and name == "merge"
        assert permissions.get("contents", "none") in (
            ("write",) if publishes or merges else ("read", "none")
        ), label
        expected_pr = "write" if merges else "read" if path.name == "merge-sbom.yml" else "none"
        assert permissions.get("pull-requests", "none") == expected_pr, label
        if publishes:
            assert permissions.get("actions") == "read", label
            assert not cloud_login, label
            if job.get("uses") == publisher:
                callers.add(path.name)

assert callers == WORKFLOWS, "Every publisher needs a merge trigger and provenance check"
merger = yaml.safe_load((root / ".github/workflows/merge-sbom.yml").read_text())
trigger = merger[True]["workflow_run"]  # PyYAML's YAML 1.1 decoder treats 'on' as True.
names = {yaml.safe_load((root / ".github/workflows" / name).read_text())["name"] for name in callers}
assert set(trigger["workflows"]) == names
assert trigger["branches"] == ["main"] and trigger["types"] == ["completed"]
for name, job in merger["jobs"].items():
    assert job["environment"] == "sbom-merge"
    access = "write" if name == "merge" else "read"
    assert job["permissions"] == {"actions": "read", "contents": access, "pull-requests": access}
    checkout = job["steps"][0]["with"]
    assert checkout["ref"] == "main" and checkout["persist-credentials"] is False
app = merger["jobs"]["open"]["steps"][2]["with"]
assert app["permission-contents"] == "read" and app["permission-pull-requests"] == "write"
publisher_job = yaml.safe_load((root / publisher[2:]).read_text())["jobs"]["sbom"]
assert publisher_job["if"] == "github.ref == 'refs/heads/main'"

print("Workflow permissions: only SBOM jobs can write contents; only the trusted merger can approve PRs; only cloud login jobs have OIDC.")
