"""Exercise untrusted artifacts, PR metadata, complete diffs and merge races."""

import copy
import hashlib
import io
import os
import stat
import unittest
from unittest.mock import patch
import zipfile

import sbom_pr as sbom


REPO = "mozilla-platform-ops/worker-images"
CONTENT = b"# Release notes\n"
BLOB = hashlib.sha1(f"blob {len(CONTENT)}\0".encode() + CONTENT).hexdigest()
RUN = {
    "id": 123, "run_attempt": 2, "head_repository": {"full_name": REPO},
    "head_branch": "main", "event": "workflow_dispatch", "status": "completed",
    "conclusion": "success", "path": ".github/workflows/win-hw-wim-build.yml",
    "run_started_at": "2026-11-03T00:00:00Z", "html_url": "https://example.invalid/run/123",
}
PR = {
    "number": 42, "state": "open", "draft": False, "changed_files": 1,
    "user": {"login": "sbom-publisher[bot]", "type": "Bot"},
    "head": {"repo": {"full_name": REPO}, "ref": "sbom/123-2", "sha": "a" * 40},
    "base": {"repo": {"full_name": REPO}, "ref": "main"},
    "html_url": "https://example.invalid/pull/42",
}
FILES = [{"filename": "sboms/image.md", "status": "added", "sha": BLOB}]
TREE = {"truncated": False, "tree": [
    {"path": "sboms/image.md", "mode": "100644", "type": "blob", "sha": BLOB},
]}
NOTES = {"sboms/image.md": CONTENT}


def archive(entries):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zipped:
        for name, content, mode in entries:
            info = zipfile.ZipInfo(name)
            info.external_attr = mode << 16
            zipped.writestr(info, content)
    return buffer.getvalue()


class SbomTests(unittest.TestCase):
    def test_regular_markdown_archive(self):
        self.assertEqual(sbom.read_archive(archive([
            ("image.md", CONTENT, stat.S_IFREG | 0o644),
        ])), NOTES)

    def test_windows_powershell_encoding_is_preserved(self):
        content = "# WIM release notes\r\n".encode("utf-16")
        self.assertEqual(sbom.read_archive(archive([("image.md", content, 0)])),
                         {"sboms/image.md": content})

    def test_unsafe_archive_entries(self):
        for name, content, mode in [
            ("../image.md", CONTENT, 0), ("/image.md", CONTENT, 0),
            ("nested/image.md", CONTENT, 0), (".github/workflows/job.yml", CONTENT, 0),
            ("image.MD", CONTENT, 0), ("image.md", b"target", stat.S_IFLNK | 0o777),
            ("image.md", b"\xff", 0), ("image.md", b"bad\0text", 0),
            ("folder/", b"", stat.S_IFDIR | 0o755),
        ]:
            with self.subTest(name=name, mode=mode), self.assertRaises((ValueError, UnicodeError)):
                sbom.read_archive(archive([(name, content, mode)]))
        with self.assertRaises(ValueError):
            sbom.read_archive(archive([]))
        with patch.object(sbom, "MAX_BYTES", 1), self.assertRaises(ValueError):
            sbom.read_archive(archive([("image.md", CONTENT, 0)]))

    def test_good_diff(self):
        sbom.validate_diff(PR, FILES, TREE, NOTES)

    def test_entire_diff_is_checked(self):
        for path, status in [("README.md", "modified"), ("sboms/image.md", "removed"),
                             ("sboms/image.md", "renamed"), ("sboms/new.md", "added")]:
            files = copy.deepcopy(FILES)
            files.append({"filename": path, "status": status, "sha": BLOB})
            with self.subTest(path=path, status=status), self.assertRaises(ValueError):
                sbom.validate_diff({**PR, "changed_files": 2}, files, TREE, NOTES)

    def test_incomplete_diff_and_unsafe_tree(self):
        cases = [({**PR, "changed_files": 2}, FILES, TREE),
                 (PR, [], TREE), (PR, FILES, {**TREE, "truncated": True})]
        for mode in ("120000", "100755", "160000"):
            tree = copy.deepcopy(TREE)
            tree["tree"][0]["mode"] = mode
            cases.append((PR, FILES, tree))
        changed = copy.deepcopy(FILES)
        changed[0]["sha"] = "b" * 40
        cases.append((PR, changed, TREE))
        for pr, files, tree in cases:
            with self.subTest(pr=pr, files=files, tree=tree), self.assertRaises(ValueError):
                sbom.validate_diff(pr, files, tree, NOTES)

    def test_run_provenance(self):
        sbom.trusted_run(RUN, REPO, completed=True)
        for key, value in [
            ("head_repository", {"full_name": "attacker/fork"}), ("head_branch", "feature"),
            ("event", "pull_request"), ("path", ".github/workflows/pre-commit.yml"),
            ("conclusion", "failure"), ("status", "in_progress"),
        ]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                sbom.trusted_run({**RUN, key: value}, REPO, completed=True)

    def api_fixture(self, route, method="GET", data=None, **kwargs):
        if route.endswith("/git/ref/heads/sbom/123-2"):
            return {"object": {"sha": PR["head"]["sha"]}}
        if "/compare/main..." in route:
            return {"merge_base_commit": {"sha": "base-sha"}}
        if "/git/trees/base-sha?" in route:
            return {"truncated": False, "tree": []}
        if route.endswith("/files?per_page=100&page=1"):
            return FILES
        if "/pulls?" in route:
            return [self.pr] if self.pr else []
        if route.endswith("/pulls/42"):
            return self.pr
        if "/git/trees/" in route:
            return TREE
        if method == "POST" and route.endswith("/pulls"):
            self.writes.append((route, data, kwargs))
            self.pr = copy.deepcopy(PR)
            return self.pr
        if method == "POST" and route.endswith("/reviews"):
            self.writes.append((route, data, kwargs))
            return {}
        if method == "PUT" and route.endswith("/merge"):
            self.writes.append((route, data, kwargs))
            return {"merged": True}
        raise AssertionError(f"Unexpected API call: {method} {route}")

    def setUp(self):
        self.pr = copy.deepcopy(PR)
        self.writes = []
        env = patch.dict(os.environ, {"SBOM_PR_APP_SLUG": "sbom-publisher"})
        env.start()
        self.addCleanup(env.stop)

    def test_wrong_pr_identity_or_branches(self):
        for key, value in [
            ("user", {"login": "attacker", "type": "User"}), ("draft", True),
            ("state", "closed"),
            ("head", {**PR["head"], "repo": {"full_name": "attacker/fork"}}),
            ("head", {**PR["head"], "ref": "sbom/123-1"}),
            ("base", {**PR["base"], "ref": "other"}),
        ]:
            self.pr = {**copy.deepcopy(PR), key: value}
            with self.subTest(key=key), patch.object(sbom, "api", self.api_fixture), self.assertRaises(ValueError):
                sbom.validate(REPO, RUN)

    def test_merge_pins_approval_and_merge_to_same_sha(self):
        env = {"PR_NUMBER": "42", "PR_SHA": PR["head"]["sha"]}
        with patch.dict(os.environ, env), patch.object(sbom, "api", self.api_fixture), \
                patch.object(sbom, "artifacts", return_value=NOTES):
            sbom.merge(REPO, RUN)
        self.assertEqual(len(self.writes), 2)
        self.assertEqual(self.writes[0][1]["commit_id"], PR["head"]["sha"])
        self.assertEqual(self.writes[1][1], {"sha": PR["head"]["sha"], "merge_method": "squash"})
        self.assertTrue(all("token" not in call[2] for call in self.writes))

    def test_changed_head_never_approved(self):
        env = {"PR_NUMBER": "42", "PR_SHA": "b" * 40}
        with patch.dict(os.environ, env), patch.object(sbom, "api", self.api_fixture), \
                patch.object(sbom, "artifacts", return_value=NOTES), self.assertRaises(ValueError):
            sbom.merge(REPO, RUN)
        self.assertEqual(self.writes, [])

    def test_all_file_pages_are_loaded(self):
        with patch.object(sbom, "api", side_effect=[list(range(100)), ["extra-file"]]):
            self.assertEqual(sbom.pages("test")[-1], "extra-file")

    def test_head_change_during_file_listing(self):
        reads = 0

        def api(route, *args, **kwargs):
            nonlocal reads
            if route.endswith("/pulls/42"):
                reads += 1
                if reads == 2:
                    return {**PR, "head": {**PR["head"], "sha": "b" * 40}}
            return self.api_fixture(route, *args, **kwargs)

        with patch.object(sbom, "api", api), patch.object(sbom, "artifacts", return_value=NOTES), \
                self.assertRaisesRegex(ValueError, "changed during validation"):
            sbom.validate(REPO, RUN)

    def test_expired_oversized_and_conflicting_artifacts(self):
        artifact = {
            "id": 1, "name": "release-notes-image", "expired": False,
            "size_in_bytes": 100, "created_at": RUN["run_started_at"],
        }
        for changed in ({"expired": True}, {"size_in_bytes": sbom.MAX_BYTES + 1}):
            with self.subTest(changed=changed), \
                    patch.object(sbom, "pages", return_value=[{**artifact, **changed}]), \
                    patch.object(sbom, "api") as api, self.assertRaises(ValueError):
                sbom.artifacts(REPO, RUN)
            api.assert_not_called()
        first = archive([("image.md", CONTENT, 0)])
        second = archive([("image.md", b"Different release notes", 0)])
        with patch.object(sbom, "pages", return_value=[{**artifact, "created_at": "2026-11-02T00:00:00Z"}]), \
                patch.object(sbom, "api", return_value=first):
            self.assertEqual(sbom.artifacts(REPO, RUN), NOTES)
        with patch.object(sbom, "pages", return_value=[artifact, {**artifact, "id": 2}]), \
                patch.object(sbom, "api", side_effect=[first, second]), self.assertRaises(ValueError):
            sbom.artifacts(REPO, RUN)

    def test_publisher_only_writes_sbom_branch(self):
        writes = []

        def api(route, method="GET", data=None, **kwargs):
            if method != "GET":
                writes.append((route, data))
            if route.endswith("/git/ref/heads/main"):
                return {"object": {"sha": "main-sha"}}
            if route.endswith("/git/commits/main-sha"):
                return {"tree": {"sha": "old-tree"}}
            if route.endswith("/git/blobs"):
                return {"sha": BLOB}
            if route.endswith("/git/trees"):
                return {"sha": "new-tree"}
            if route.endswith("/git/commits"):
                return {"sha": "new-commit"}
            if route.endswith("/git/refs"):
                return {}
            raise AssertionError(route)

        env = {"GITHUB_RUN_ATTEMPT": "2", "ARTIFACT_PATTERN": "release-notes-*",
               "COMMIT_MESSAGE": "Image release notes"}
        with patch.dict(os.environ, env), patch.object(sbom, "api", api), \
                patch.object(sbom, "artifacts", return_value=NOTES):
            sbom.publish(REPO, RUN)
        refs = [data for route, data in writes if route.endswith("/git/refs")]
        self.assertEqual(refs, [{"ref": "refs/heads/sbom/123-2", "sha": "new-commit"}])
        self.assertTrue(writes[-1][0].endswith("/git/refs"))

    def test_no_pr_never_uses_merge_token(self):
        with patch.object(sbom, "pages", return_value=[]), patch.object(sbom, "api") as api:
            self.assertIsNone(sbom.validate(REPO, RUN))
        api.assert_not_called()

    def test_app_opens_pr_after_validating_branch(self):
        self.pr = None
        env = {"BRANCH_SHA": PR["head"]["sha"], "SBOM_PR_TOKEN": "test-pr-token"}
        with patch.dict(os.environ, env), patch.object(sbom, "api", self.api_fixture), \
                patch.object(sbom, "artifacts", return_value=NOTES):
            result = sbom.open_pr(REPO, RUN)
        self.assertEqual(result["number"], 42)
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.writes[0][1]["head"], "sbom/123-2")
        self.assertEqual(self.writes[0][2]["token"], "test-pr-token")

    def test_app_does_not_open_unsafe_branch(self):
        def api(route, *args, **kwargs):
            if route == f"repos/{REPO}/git/trees/{PR['head']['sha']}?recursive=1":
                return {**TREE, "tree": TREE["tree"] + [
                    {"path": "ci/malicious.py", "type": "blob", "mode": "100644", "sha": BLOB},
                ]}
            return self.api_fixture(route, *args, **kwargs)

        with patch.object(sbom, "api", api), patch.object(sbom, "artifacts", return_value=NOTES), \
                self.assertRaises(ValueError):
            sbom.open_pr(REPO, RUN)
        self.assertEqual(self.writes, [])

    def test_missing_branch_is_a_noop(self):
        with patch.object(sbom, "api", side_effect=sbom.ApiError("Not found", 404)):
            self.assertIsNone(sbom.validate_branch(REPO, RUN))

    def test_required_checks_are_waited_for_with_same_sha(self):
        attempts = []

        def api(route, method="GET", data=None, **kwargs):
            if method == "PUT":
                attempts.append(data["sha"])
                if len(attempts) == 1:
                    raise sbom.ApiError("Required checks pending", 405)
            return self.api_fixture(route, method, data, **kwargs)

        env = {"PR_NUMBER": "42", "PR_SHA": PR["head"]["sha"]}
        with patch.dict(os.environ, env), patch.object(sbom, "api", api), \
                patch.object(sbom, "artifacts", return_value=NOTES), patch.object(sbom.time, "sleep"):
            sbom.merge(REPO, RUN)
        self.assertEqual(attempts, [PR["head"]["sha"]] * 2)

    def test_merge_head_conflict_is_never_retried(self):
        def api(route, method="GET", data=None, **kwargs):
            if method == "PUT":
                raise sbom.ApiError("Head changed", 409)
            return self.api_fixture(route, method, data, **kwargs)

        env = {"PR_NUMBER": "42", "PR_SHA": PR["head"]["sha"]}
        with patch.dict(os.environ, env), patch.object(sbom, "api", api), \
                patch.object(sbom, "artifacts", return_value=NOTES), \
                patch.object(sbom.time, "sleep") as sleep, self.assertRaises(sbom.ApiError):
            sbom.merge(REPO, RUN)
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
