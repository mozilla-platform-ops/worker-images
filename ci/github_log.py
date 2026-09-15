"""Console logging shared by cloud and hardware integration runners."""

import os
import sys
from datetime import datetime, timezone


def log_message(level: str, message: str, include_datetimestamp: bool = False) -> None:
    if include_datetimestamp:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        message = f"[{stamp}] {message}"
    if os.environ.get("GITHUB_ACTIONS") == "true" and level in ("warning", "error"):
        escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::{level}::{escaped}", flush=True)
    elif level == "error":
        sys.stdout.flush()
        print(f"ERROR: {message}", file=sys.stderr, flush=True)
    else:
        print(("WARNING: " if level == "warning" else "") + message, flush=True)


def format_duration(seconds: int) -> str:
    if seconds < 0:
        return "-"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
