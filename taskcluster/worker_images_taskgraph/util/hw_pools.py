# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Registry for the MDC1 Windows hardware worker pools.

Hardware pools are static workers with no worker-manager entry, so pools.yml is
the only record of what each one is running. Imported by both the decision task
and ci/run-hw-os-integration.py, so PyYAML is the only dependency.
"""

import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml

PROVISIONER_ID = "releng-hardware"

POOLS_YAML_RELPATH = Path("provisioners/windows/MDC1Windows/pools.yml")

# Production pools are the ones mozilla-central addresses directly, via its
# `win11-64-24h2(-hw|-hw-ref)` alias. Derived so a new one is refused on sight.
_PRODUCTION_RE = re.compile(r"^win11-(?:64|a64)-[0-9a-z]+-hw(?:-ref)?$")

LOW_CAPACITY_THRESHOLD = 4


class HwPoolError(Exception):
    """Raised when a requested hardware pool is unknown or not targetable."""


@dataclass(frozen=True)
class HwPool:
    """One entry from the ``pools`` list in ``pools.yml``."""

    name: str
    image: str | None = None
    src_organisation: str | None = None
    src_repository: str | None = None
    src_branch: str | None = None
    revision: str | None = None
    secret_date: str | None = None
    domain_suffix: str | None = None
    description: str | None = None
    dev_branch: str | None = None
    nodes: tuple[str, ...] = field(default_factory=tuple)

    @property
    def task_queue_id(self) -> str:
        return f"{PROVISIONER_ID}/{self.name}"

    @property
    def is_production(self) -> bool:
        return bool(_PRODUCTION_RE.match(self.name))

    @property
    def node_count(self) -> int:
        return len(self.nodes)

    @property
    def is_low_capacity(self) -> bool:
        return self.node_count < LOW_CAPACITY_THRESHOLD

    @property
    def identity(self) -> dict[str, str | None]:
        """The WIM + ronin triple a test result has to be attributed to."""
        return {
            "image": self.image,
            "src_branch": self.src_branch,
            "revision": self.revision,
        }

    def fqdn(self, node: str) -> str:
        if not self.domain_suffix:
            return node
        return f"{node}.{self.domain_suffix}"


@dataclass(frozen=True)
class HwPoolRegistry:
    pools: dict[str, HwPool]
    known_bad_nodes: frozenset[str]

    def __contains__(self, name: object) -> bool:
        return name in self.pools

    def __getitem__(self, name: str) -> HwPool:
        return self.pools[name]

    @property
    def targetable(self) -> dict[str, HwPool]:
        return {n: p for n, p in self.pools.items() if not p.is_production}

    def healthy_nodes(self, name: str) -> tuple[str, ...]:
        return tuple(n for n in self[name].nodes if n not in self.known_bad_nodes)

    def resolve(self, names) -> list[HwPool]:
        """Validate requested pool names, returning them in pools.yml order."""
        requested = list(dict.fromkeys(names))
        if not requested:
            raise HwPoolError("no hardware pools requested")

        unknown = [n for n in requested if n not in self.pools]
        if unknown:
            raise HwPoolError(
                "unknown hardware pool(s): {}. Known pools: {}".format(
                    ", ".join(sorted(unknown)),
                    ", ".join(sorted(self.pools)),
                )
            )

        # Last line of defence if the hook is triggered by hand.
        production = [n for n in requested if self[n].is_production]
        if production:
            raise HwPoolError(
                "refusing to target production hardware pool(s): {}. "
                "These pools run production Firefox CI.".format(
                    ", ".join(sorted(production))
                )
            )

        return [p for n, p in self.pools.items() if n in requested]


def find_repo_root(start: Path | str | None = None) -> Path:
    """Walk up from ``start`` looking for the checkout containing pools.yml."""
    here = Path(start).resolve() if start else Path(__file__).resolve()
    for candidate in (here, *here.parents):
        if (candidate / POOLS_YAML_RELPATH).is_file():
            return candidate
    raise HwPoolError(
        f"could not locate {POOLS_YAML_RELPATH} above {here}; "
        "is this a worker-images checkout?"
    )


def _coerce_nodes(raw) -> tuple[str, ...]:
    if not raw:
        return ()
    return tuple(str(n).strip() for n in raw if str(n).strip())


def _parse_known_bad(raw) -> frozenset[str]:
    """Flatten the ``Known-BAD`` mapping of hw-class -> node list."""
    if not isinstance(raw, dict):
        return frozenset()
    nodes: set[str] = set()
    for entries in raw.values():
        nodes.update(_coerce_nodes(entries))
    return frozenset(nodes)


def load_registry(repo_root: Path | str | None = None) -> HwPoolRegistry:
    """Parse ``pools.yml`` into an :class:`HwPoolRegistry`."""
    root = Path(repo_root) if repo_root else find_repo_root()
    pools_yaml = root / POOLS_YAML_RELPATH
    if not pools_yaml.is_file():
        raise HwPoolError(f"{pools_yaml} does not exist")

    data = yaml.safe_load(pools_yaml.read_text()) or {}

    pools: dict[str, HwPool] = {}
    for entry in data.get("pools") or []:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        if not name:
            continue
        pools[name] = HwPool(
            name=name,
            image=entry.get("image"),
            src_organisation=entry.get("src_Organisation"),
            src_repository=entry.get("src_Repository"),
            src_branch=entry.get("src_Branch"),
            # pools.yml `hash` is the ronin_puppet pin; renamed to avoid the builtin.
            revision=entry.get("hash"),
            secret_date=entry.get("secret_date"),
            domain_suffix=entry.get("domain_suffix"),
            description=entry.get("Description"),
            dev_branch=entry.get("dev"),
            nodes=_coerce_nodes(entry.get("nodes")),
        )

    if not pools:
        raise HwPoolError(f"no pools found in {pools_yaml}")

    return HwPoolRegistry(
        pools=pools,
        known_bad_nodes=_parse_known_bad(data.get("Known-BAD")),
    )
