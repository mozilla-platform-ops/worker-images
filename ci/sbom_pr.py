"""Publish SBOM-only PRs and validate them before a separate identity merges them."""

import base64
import fnmatch
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from urllib.parse import urlencode
import zipfile


WORKFLOWS = {
    "sig-FXCI-parallel-build.yml", "sig-FXCI-nontrusted-parallel-build-alpha.yml",
    "sig-nontrusted.yml", "sig-trusted.yml", "gcp-fxci-parallel-alpha.yml",
    "gcp-deploy-parallel.yml", "gcp-fxci.yml", "gcp-deploy.yml", "win-hw-wim-build.yml",
}
MAX_BYTES = 20 * 1024 * 1024


class ApiError(RuntimeError):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def require(condition, message):
    if not condition:
        raise ValueError(message)


def api(route, method="GET", data=None, *, raw=False, token=None):
    args = ["gh", "api", "--method", method, route]
    if data is not None:
        args += ["--input", "-"]
    result = subprocess.run(
        args, input=json.dumps(data).encode() if data is not None else None,
        capture_output=True, env={**os.environ, **({"GH_TOKEN": token} if token else {})},
    )
    if result.returncode:
        error = result.stderr.decode()
        match = re.search(r"\(HTTP (\d+)\)", error)
        raise ApiError(error, int(match[1]) if match else None)
    return result.stdout if raw else json.loads(result.stdout)


def pages(route, key=None):
    result = []
    for page in range(1, 101):
        response = api(f"{route}{'&' if '?' in route else '?'}per_page=100&page={page}")
        batch = response[key] if key else response
        result.extend(batch)
        if len(batch) < 100:
            return result
    raise ValueError("API listing exceeded pagination limit")


def trusted_run(run, repo, completed):
    require(run["head_repository"]["full_name"] == repo, "Foreign source repository")
    require(run["head_branch"] == "main" and run["event"] == "workflow_dispatch",
            "SBOM publication requires a dispatch from main")
    require(run["path"] in {f".github/workflows/{name}" for name in WORKFLOWS},
            "Unrecognized build workflow")
    if completed:
        require(run["status"] == "completed" and run["conclusion"] == "success",
                "Build workflow must have succeeded")


def read_archive(data):
    require(len(data) <= MAX_BYTES, "Artifact archive is too large")
    notes = {}
    total = 0
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.md", entry.filename),
                    "Artifact must contain only flat Markdown filenames")
            require(stat.S_IFMT(entry.external_attr >> 16) in (0, stat.S_IFREG),
                    "Artifact must contain only regular files")
            total += entry.file_size
            require(total <= MAX_BYTES, "Uncompressed notes are too large")
            content = archive.read(entry)
            # Windows PowerShell writes BOM-marked UTF-16; preserve the artifact bytes.
            encoding = "utf-16" if content.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
            require("\0" not in content.decode(encoding), "Markdown must be text")
            path = f"sboms/{entry.filename}"
            require(path not in notes, "Duplicate filename in artifact")
            notes[path] = content
    require(notes, "Empty release-note artifact")
    return notes


def artifacts(repo, run, pattern="release-notes-*"):
    notes = {}
    for artifact in pages(f"repos/{repo}/actions/runs/{run['id']}/artifacts", "artifacts"):
        if not fnmatch.fnmatchcase(artifact["name"], pattern):
            continue
        require(artifact["name"].startswith("release-notes-"), "Not a release-note artifact")
        require(not artifact["expired"], "Release-note artifact expired")
        require(artifact["size_in_bytes"] <= MAX_BYTES, "Artifact is too large")
        data = api(f"repos/{repo}/actions/artifacts/{artifact['id']}/zip", raw=True)
        for path, content in read_archive(data).items():
            require(path not in notes or notes[path] == content, "Conflicting release notes")
            notes[path] = content
        require(sum(map(len, notes.values())) <= MAX_BYTES, "Combined notes are too large")
    require(notes, "No release notes from this build")
    return notes


def branch(run):
    return f"sbom/{run['id']}-{run['run_attempt']}"


def publish(repo, run):
    trusted_run(run, repo, completed=False)
    require(str(run["run_attempt"]) == os.environ["GITHUB_RUN_ATTEMPT"], "Attempt changed")
    notes = artifacts(repo, run, os.environ["ARTIFACT_PATTERN"])
    base = api(f"repos/{repo}/git/ref/heads/main")["object"]["sha"]
    tree = api(f"repos/{repo}/git/commits/{base}")["tree"]["sha"]
    entries = []
    for path, content in sorted(notes.items()):
        blob = api(f"repos/{repo}/git/blobs", "POST", {
            "content": base64.b64encode(content).decode(), "encoding": "base64",
        })
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    updated = api(f"repos/{repo}/git/trees", "POST", {"base_tree": tree, "tree": entries})
    if updated["sha"] == tree:
        print("Release notes already match main; no PR needed.")
        return
    commit = api(f"repos/{repo}/git/commits", "POST", {
        "message": os.environ["COMMIT_MESSAGE"], "tree": updated["sha"], "parents": [base],
    })
    api(f"repos/{repo}/git/refs", "POST", {
        "ref": f"refs/heads/{branch(run)}", "sha": commit["sha"],
    })
    print(f"Created {branch(run)} at {commit['sha']}; main was not updated.")


def validate_diff(pr, files, tree, notes):
    require(files and len(files) == pr["changed_files"], "Incomplete or empty PR diff")
    require(not tree["truncated"], "Truncated Git tree")
    entries = {entry["path"]: entry for entry in tree["tree"]}
    for file in files:
        path = file["filename"]
        require(file["status"] in ("added", "modified"), "Deletion or rename in SBOM PR")
        require(re.fullmatch(r"sboms/[A-Za-z0-9][A-Za-z0-9._-]*\.md", path) and path in notes,
                "Changed file does not match a build artifact")
        entry = entries.get(path, {})
        require(entry.get("mode") == "100644" and entry.get("type") == "blob",
                "Changed file must be a regular Markdown file")
        content = notes[path]
        expected = hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest()
        require(file["sha"] == entry["sha"] == expected, "PR content differs from build artifact")


def candidates(repo, run):
    query = urlencode({"state": "open", "base": "main", "head": f"{repo.split('/')[0]}:{branch(run)}"})
    return pages(f"repos/{repo}/pulls?{query}")


def validate_branch(repo, run):
    trusted_run(run, repo, completed=True)
    try:
        sha = api(f"repos/{repo}/git/ref/heads/{branch(run)}")["object"]["sha"]
    except ApiError as error:
        if error.status == 404:
            print("No SBOM branch for this run attempt.")
            return None
        raise
    comparison = api(f"repos/{repo}/compare/main...{sha}")
    base = comparison["merge_base_commit"]["sha"]
    tree = api(f"repos/{repo}/git/trees/{sha}?recursive=1")
    old = api(f"repos/{repo}/git/trees/{base}?recursive=1")
    require(not old["truncated"] and not tree["truncated"], "Truncated Git tree")
    before = {entry["path"]: entry for entry in old["tree"] if entry["type"] != "tree"}
    after = {entry["path"]: entry for entry in tree["tree"] if entry["type"] != "tree"}
    files = []
    for path in before.keys() | after.keys():
        left, right = before.get(path), after.get(path)
        if left == right:
            continue
        files.append({"filename": path, "sha": right["sha"] if right else None,
                      "status": "removed" if right is None else "modified" if left else "added"})
    validate_diff({"changed_files": len(files)}, files, tree, artifacts(repo, run))
    return sha


def open_pr(repo, run):
    sha = validate_branch(repo, run)
    require(sha is not None and sha == os.environ["BRANCH_SHA"], "SBOM branch changed")
    if not candidates(repo, run):
        api(f"repos/{repo}/pulls", "POST", {
            "title": f"SBOM release notes: build {run['id']}, attempt {run['run_attempt']}",
            "head": branch(run), "base": "main",
            "body": f"Release notes from {run['html_url']}, attempt {run['run_attempt']}.\n\n"
                    "Automatic review verifies the complete diff against this build's artifacts.",
        }, token=os.environ["SBOM_PR_TOKEN"])
    return validate(repo, run)


def validate(repo, run):
    trusted_run(run, repo, completed=True)
    matches = candidates(repo, run)
    if not matches:
        print("No open SBOM PR for this run attempt.")
        return None
    require(len(matches) == 1, "Ambiguous SBOM PR")
    pr = api(f"repos/{repo}/pulls/{matches[0]['number']}")
    require(pr["state"] == "open" and not pr["draft"], "PR must be open and ready")
    require(pr["user"]["login"] == f"{os.environ['SBOM_PR_APP_SLUG']}[bot]" and pr["user"]["type"] == "Bot",
            "Unexpected PR author")
    require(pr["head"]["repo"]["full_name"] == repo and pr["base"]["repo"]["full_name"] == repo,
            "PR must stay within this repository")
    require(pr["base"]["ref"] == "main" and pr["head"]["ref"] == branch(run), "Wrong PR branches")
    sha = pr["head"]["sha"]
    tree = api(f"repos/{repo}/git/trees/{sha}?recursive=1")
    files = pages(f"repos/{repo}/pulls/{pr['number']}/files")
    validate_diff(pr, files, tree, artifacts(repo, run))
    # The file-list endpoint uses the current PR head, whereas the tree is pinned.
    require(api(f"repos/{repo}/pulls/{pr['number']}")["head"]["sha"] == sha, "PR changed during validation")
    return pr


def merge(repo, run):
    pr = validate(repo, run)
    require(pr is not None, "No SBOM PR to merge")
    sha = pr["head"]["sha"]
    require(str(pr["number"]) == os.environ["PR_NUMBER"] and sha == os.environ["PR_SHA"],
            "PR changed after read-only validation")
    api(f"repos/{repo}/pulls/{pr['number']}/reviews", "POST", {
        "event": "APPROVE", "commit_id": sha,
        "body": "Verified: only regular sboms/*.md files matching the successful build artifacts.",
    })
    for attempt in range(60):
        try:
            result = api(f"repos/{repo}/pulls/{pr['number']}/merge", "PUT", {
                "sha": sha, "merge_method": "squash",
            })
            require(result["merged"], "GitHub did not merge the PR")
            print(f"Merged {pr['html_url']} at {sha}")
            return
        except ApiError as error:
            if error.status != 405 or attempt == 59:
                raise
            # Direct SHA-guarded merges wait for protections without enabling auto-merge on future commits.
            print("Merge requirements not met yet; retrying in 20 seconds.", flush=True)
            time.sleep(20)


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    run = api(f"repos/{repo}/actions/runs/{int(os.environ['SOURCE_RUN_ID'])}")
    require(str(run["run_attempt"]) == os.environ["SOURCE_RUN_ATTEMPT"], "Source attempt changed")
    if sys.argv[1] == "publish":
        publish(repo, run)
    elif sys.argv[1] == "prepare":
        sha = validate_branch(repo, run)
        if sha:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
                output.write(f"sha={sha}\n")
    elif sys.argv[1] == "open":
        pr = open_pr(repo, run)
        if pr:
            with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
                output.write(f"pr={pr['number']}\nsha={pr['head']['sha']}\n")
    elif sys.argv[1] == "merge":
        merge(repo, run)
    else:
        raise ValueError("Unknown SBOM operation")


if __name__ == "__main__":
    main()
