"""Resolve paired Hg and Git revisions from one latest autoland decision."""

import json
import re
from urllib.request import urlopen


ROOT = "https://firefox-ci-tc.services.mozilla.com/api"


def read_json(url):
    with urlopen(url, timeout=120) as response:
        return json.load(response)


def hg_revision(graph, source="https://hg.mozilla.org/integration/autoland"):
    revisions = {
        task["task"]["payload"]["env"].get("GECKO_HEAD_REV", "")
        for task in graph.values()
        if task.get("task", {}).get("payload", {}).get("env", {}).get("GECKO_HEAD_REPOSITORY")
        == source
    }
    if len(revisions) != 1 or not re.fullmatch(r"[0-9a-f]{40}", next(iter(revisions), "")):
        raise ValueError(f"Expected one full autoland revision for {source} in the decision graph")
    return revisions.pop()


if __name__ == "__main__":
    decision = read_json(f"{ROOT}/index/v1/task/gecko.v2.autoland.latest.taskgraph.decision")["taskId"]
    graph = read_json(f"{ROOT}/queue/v1/task/{decision}/artifacts/public/full-task-graph.json")
    print(f"decision={decision}")
    print(f"revision={hg_revision(graph)}")
    print(f"git_revision={hg_revision(graph, 'https://github.com/mozilla-firefox/firefox')}")
