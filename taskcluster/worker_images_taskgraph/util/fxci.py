# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import re
from collections import defaultdict
from functools import cache

import taskcluster

AZURE_IMAGE_NAME_RE = re.compile(r".+/images/(\w+)/versions/.*")


@cache
def get_worker_pool_images() -> dict[str, set[str]]:
    options = taskcluster.optionsFromEnvironment()
    wm = taskcluster.WorkerManager(options)
    data = wm.listWorkerPools()
    assert data

    pool_images = defaultdict(set)
    for pool in data["workerPools"]:
        assert isinstance(pool, dict)

        # Skip pools that don't have launchConfigs
        if "launchConfigs" not in pool["config"]:
            continue

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
