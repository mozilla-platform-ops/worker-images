# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

from mozilla_taskgraph import register as register_mozilla_taskgraph


def register(graph_config):
    """Setup for task generation."""
    # Setup mozilla-taskgraph
    register_mozilla_taskgraph(graph_config)
