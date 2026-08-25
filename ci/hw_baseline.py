#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""What production scores for the same test, so a staging number means something.

A staging run measures itself and stops there: a mean and a spread, with nothing
to be judged against. These pools exist to answer "does this image or ronin
change make the hardware slower", and that question needs production's number.

Two ways to get one, because they fail differently:

`perfherder` (the default) reads mozilla-central's own series for the production
counterpart platform -- fourteen days, dozens of pushes, many nodes. That gives a
spread, so a staging number can be called normal or outside the envelope rather
than merely different. It is not paired: the series spans revisions, so a real
Firefox change moves the baseline. Production CV runs 1.6-1.8% on speedometer3,
so that drift is small and visible.

`counterpart` reads the single production task the replicated one was copied
from. Same build, same revision, same day, so a difference can only be the
hardware or the image -- but it is one task on one node with no error bar, and a
slow node is indistinguishable from a real difference. Kept for the case where
"Firefox changed" is a live alternative explanation.

Nothing here writes to Perfherder: replicated tasks drop their treeherder routes
precisely so a staging run cannot pollute production's series.
"""

import json
import statistics
import urllib.error
import urllib.parse
import urllib.request

BASELINE_MODES = ("perfherder", "counterpart", "none")
DEFAULT_BASELINE_MODE = "perfherder"

TREEHERDER_ROOT = "https://treeherder.mozilla.org/api"
PERFHERDER_PROJECT = "mozilla-central"
# Treeherder rejects some default agents outright, and an unattributed scraper is
# rude besides.
USER_AGENT = "mozilla-platform-ops/worker-images hw-os-integration (RELOPS-2503)"
HTTP_TIMEOUT_SECONDS = 30

# Fourteen days of pushes: long enough for a spread that means something, short
# enough that a Firefox landing does not sit in the middle of it unnoticed.
BASELINE_WINDOW_DAYS = 14

# Only a *worse* result is worth a word, and only past the point where
# production's own scatter explains it. Production stdev is the yardstick rather
# than a percentage we invent, so a noisy suite needs a bigger gap than a quiet
# one to be called anything.
REGRESSION_SIGMAS = 3.0
# A series this thin has no usable stdev, so it flags nothing.
MIN_BASELINE_POINTS = 10

# Fallback for the name -> id mapping if Treeherder will not list frameworks.
_FRAMEWORK_IDS = {
    "talos": 1,
    "awsy": 4,
    "js-bench": 11,
    "devtools": 12,
    "browsertime": 13,
    "mozperftest": 15,
}


class BaselineError(Exception):
    """A baseline could not be read. Never fatal to a run."""


def _get(path: str, params: dict | None = None):
    url = f"{TREEHERDER_ROOT}/{path.lstrip('/')}"
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise BaselineError(f"{url}: {exc}") from exc


def framework_id(name: str, cache: dict) -> int | None:
    """Perfherder's numeric framework, from the name the blob already carries.

    Our suites span two harnesses -- browsertime for the benchmarks, talos for
    a11yr and friends -- and a signature lookup needs the right one or it
    silently matches nothing.
    """
    if "ids" not in cache:
        try:
            cache["ids"] = {f["name"]: f["id"] for f in _get("performance/framework/")}
        except BaselineError:
            cache["ids"] = dict(_FRAMEWORK_IDS)
    return cache["ids"].get(name) or _FRAMEWORK_IDS.get(name)


def production_platform(test_platform: str) -> str:
    """`windows11-64-24h2-hw-ref-shippable/opt` -> the Perfherder platform.

    Perfherder names the platform without the build type, and the pool's own
    counterpart platform is exactly the one whose series we want.
    """
    return test_platform.split("/", 1)[0]


def _signature(platform, suite, application, extra_options, framework, cache):
    """The Perfherder series for one suite on one platform, for one browser.

    Perfherder keys a signature by suite *and* application *and* extra_options --
    `speedometer3` from Firefox, from custom-car and from Chrome are three
    different series, and `no-nova` is a fourth. That is the same split
    collect_scores makes, which is why the two line up.
    """
    key = (platform, framework)
    if key not in cache:
        cache[key] = _get(
            f"project/{PERFHERDER_PROJECT}/performance/signatures/",
            {
                "framework": framework,
                "platform": platform,
                "subtests": 0,
                "interval": BASELINE_WINDOW_DAYS * 86400,
            },
        )

    wanted = sorted(extra_options or [])
    for signature_id, meta in cache[key].items():
        if meta.get("suite") != suite:
            continue
        if (meta.get("application") or "") != (application or ""):
            continue
        if sorted(meta.get("extra_options") or []) != wanted:
            continue
        return signature_id
    return None


def perfherder_baseline(
    platform, suite, application, extra_options, framework_name, cache
) -> dict | None:
    """Production's own distribution for this suite, over the window."""
    framework = framework_id(framework_name, cache.setdefault("framework", {}))
    if not framework:
        raise BaselineError(f"no Perfherder framework called {framework_name!r}")

    signature = _signature(
        production_platform(platform),
        suite,
        application,
        extra_options,
        framework,
        cache.setdefault("signatures", {}),
    )
    if not signature:
        return None

    series = _get(
        f"project/{PERFHERDER_PROJECT}/performance/data/",
        {
            "signature_id": signature,
            "framework": framework,
            "interval": BASELINE_WINDOW_DAYS * 86400,
        },
    )
    values = [
        point["value"]
        for points in series.values()
        for point in points
        if point.get("value") is not None
    ]
    if not values:
        return None
    return {
        "source": "perfherder",
        "detail": f"{BASELINE_WINDOW_DAYS}d of mozilla-central",
        "signature": str(signature),
        "n": len(values),
        "mean": statistics.fmean(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
    }


def counterpart_baseline(read_perfherder, source_task_id, suite, application):
    """The one production task this pool's task was copied from.

    Paired but unreplicated: same build and revision, no error bar.
    """
    if not source_task_id:
        return None
    data = read_perfherder(source_task_id)
    if not data:
        return None
    if ((data.get("application") or {}).get("name") or "") != (application or ""):
        return None
    for entry in data.get("suites") or []:
        if entry.get("name") == suite and entry.get("value") is not None:
            value = float(entry["value"])
            return {
                "source": "counterpart",
                "detail": f"production task {source_task_id}",
                "n": 1,
                "mean": value,
                "median": value,
                "min": value,
                "max": value,
                "stdev": 0.0,
            }
    return None


def compare(observed_mean: float, baseline: dict, lower_is_better: bool) -> dict:
    """How this run sits against production, and whether that is worth a word.

    Direction matters: faster than production is not a regression, and on a
    lower-is-better suite faster means a smaller number. Only a worse result is
    ever flagged, and only when production's own scatter cannot explain it --
    which is why the threshold is in standard deviations of the baseline rather
    than a flat percentage.
    """
    mean = baseline["mean"]
    delta = observed_mean - mean
    percent = 100 * delta / mean if mean else 0.0
    worse = delta > 0 if lower_is_better else delta < 0
    stdev = baseline.get("stdev") or 0.0
    sigmas = abs(delta) / stdev if stdev else None

    flag = bool(
        worse
        and sigmas is not None
        and sigmas >= REGRESSION_SIGMAS
        and baseline.get("n", 0) >= MIN_BASELINE_POINTS
    )
    return {
        "percent": percent,
        "sigmas": sigmas,
        "worse": worse,
        "flag": flag,
        "baseline": baseline,
    }
