# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

from functools import cache

import taskcluster

FIREFOXCI_ROOT_URL = "https://firefox-ci-tc.services.mozilla.com"


@cache
def get_taskcluster_client(service: str):
    options = {"rootUrl": FIREFOXCI_ROOT_URL}
    return getattr(taskcluster, service)(options)


@cache
def get_worker_pools():
    wm = get_taskcluster_client("WorkerManager")
    pools = wm.listWorkerPools()["workerPools"]
    return [p["workerPoolId"] for p in pools]
