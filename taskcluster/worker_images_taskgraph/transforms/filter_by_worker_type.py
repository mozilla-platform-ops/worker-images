# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
"""
Filter replicated tasks by worker type.

This transform filters tasks based on their workerType field in the task
definition. It's designed to work with the replicate transform to select
specific tasks (like builds) that use a particular worker type.

Usage in kind.yml:
    transforms:
      - mozilla_taskgraph.transforms.replicate
      - worker_images_taskgraph.transforms.filter_by_worker_type
      - worker_images_taskgraph.transforms.integration_test

    tasks:
      gecko-builds:
        filter-worker-types:
          - b-win2022
        replicate:
          target:
            - gecko.v2.mozilla-central.latest.taskgraph.decision
          include-attrs:
            kind:
              - build
"""

import logging

from taskgraph.transforms.base import TransformSequence
from voluptuous import ALLOW_EXTRA, Optional, Schema

logger = logging.getLogger(__name__)
transforms = TransformSequence()


FILTER_SCHEMA = Schema(
    {
        Optional("filter-worker-types"): [str],
        # Allow other keys from replicate transform and task definition
    },
    extra=ALLOW_EXTRA,
)


transforms.add_validate(FILTER_SCHEMA)


@transforms.add
def filter_by_worker_type(config, tasks):
    """
    Filter tasks to only include those matching specified worker types.

    If 'filter-worker-types' is not specified in the task, all tasks
    are passed through unchanged.
    """
    for task in tasks:
        # Get the filter configuration from the task definition
        # This is preserved from the original kind.yml task definition
        worker_type_filter = task.get("filter-worker-types", [])

        # Get the workerType from the actual task definition
        worker_type = task.get("task", {}).get("workerType", "")

        if not worker_type_filter:
            # No filter specified, pass through all tasks
            yield task
            continue

        if worker_type in worker_type_filter:
            logger.debug(f"Including task with workerType '{worker_type}'")
            yield task
        else:
            logger.debug(
                f"Filtering out task with workerType '{worker_type}' "
                f"(not in {worker_type_filter})"
            )
