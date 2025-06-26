# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import re
from collections import defaultdict
from functools import cache

import taskcluster

FIREFOXCI_ROOT_URL = "https://firefox-ci-tc.services.mozilla.com"
AZURE_IMAGE_NAME_RE = re.compile(r".+/images/(\w+)/versions/.*")


@cache
def get_taskcluster_client(service: str):
    options = {"rootUrl": FIREFOXCI_ROOT_URL}
    return getattr(taskcluster, service)(options)


@cache
def get_worker_pool_images() -> dict[str, set[str]]:
    wm = get_taskcluster_client("WorkerManager")
    pools = wm.listWorkerPools()["workerPools"]

    pool_images = defaultdict(set)
    for pool in pools:
        for lc in pool["config"]["launchConfigs"]:
            image = None
            if disks := lc.get("disks"):
                boot_disk = [d for d in disks if d.get("boot") is True][0]
                image = boot_disk["initializeParams"]["sourceImage"].rsplit("/", 1)[-1]

            elif image_ref := lc.get("storageProfile", {}).get("imageReference"):
                if match := AZURE_IMAGE_NAME_RE.match(image_ref["id"]):
                    image = match[1]

            if image:
                pool_images[pool["workerPoolId"]].add(image)
                
    return pool_images
