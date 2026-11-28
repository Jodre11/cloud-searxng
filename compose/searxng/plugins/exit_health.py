# SPDX-License-Identifier: AGPL-3.0-or-later
"""Record which engines answered each real search, so health is judged from real traffic.

Mounted into the image at searx/plugins/exit_health.py. Appends one JSON line per first-page search to
RECORD_PATH; scripts/health-check.sh and scripts/engine-health.sh read them. Nothing is sent anywhere.

Keep the imports to the public plugin base classes: a plugin that fails to import stops SearXNG from starting,
and Watchtower updates the image unattended. Failures inside post_search are caught and logged by SearXNG.
"""

import json
import os
import time
import typing

from . import Plugin, PluginInfo

if typing.TYPE_CHECKING:
    from searx.extended_types import SXNG_Request
    from searx.search import SearchWithPlugins

    from . import PluginCfg

# A host directory mounted by docker-compose.yml, so records survive restarts (engine-health.sh needs them).
RECORD_PATH = "/run/exit-health/records.jsonl"
MAX_BYTES = 256 * 1024


class SXNGPlugin(Plugin):
    """Appends the queried, answering and unresponsive engines of every search to a local JSONL file."""

    id = "exit_health"

    def __init__(self, plg_cfg: "PluginCfg"):
        super().__init__(plg_cfg)
        self.info = PluginInfo(
            id=self.id,
            name="Exit health recorder",
            description="Records which engines answered each search, for this instance's health check.",
            preference_section="general",
        )

    def post_search(self, request: "SXNG_Request", search: "SearchWithPlugins") -> None:
        query = search.search_query
        if query.pageno > 1:
            return None
        container = search.result_container
        answered = sorted({name for result in container.main_results_map.values() for name in result.engines})
        record = {
            "ts": int(time.time()),
            "queried": sorted({ref.name for ref in query.engineref_list}),
            "answered": answered,
            "unresponsive": sorted({entry.engine for entry in container.unresponsive_engines}),
        }
        self._append(json.dumps(record, separators=(",", ":")) + "\n")
        return None

    @staticmethod
    def _append(line: str) -> None:
        try:
            if os.path.getsize(RECORD_PATH) > MAX_BYTES:
                os.replace(RECORD_PATH, RECORD_PATH + ".1")
        except FileNotFoundError:
            pass
        # One small O_APPEND write per line keeps lines whole across concurrent workers.
        with open(RECORD_PATH, "a", encoding="utf-8") as handle:
            handle.write(line)
