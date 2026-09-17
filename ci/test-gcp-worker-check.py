"""Run the guest worker check with a local executable; no cloud access needed."""
from pathlib import Path
import subprocess
import tempfile

check = Path(__file__).resolve().parents[1] / "tests/linux/test_taskcluster.sh"
with tempfile.TemporaryDirectory() as directory:
    worker = Path(directory) / "generic-worker"
    for version, status, expected, passes in [
        ("110.0.0", 0, "110.0.0", True),
        ("109.0.0", 0, "110.0.0", False),
        ("110.0.0", 1, "110.0.0", False),
        ("110.0.0", 0, "", False),
        (None, 0, "110.0.0", False),
    ]:
        if version is None:
            worker.unlink()
        else:
            worker.write_text(
                '#!/bin/sh\n[ "$1" = "--short-version" ] || exit 2\n'
                f'echo "{version}"\nexit {status}\n'
            )
            worker.chmod(0o755)
        result = subprocess.run(
            ["/bin/bash", str(check)],
            env={"PATH": directory, "TASKCLUSTER_VERSION": expected},
            capture_output=True, text=True,
        )
        assert (result.returncode == 0) == passes, (version, status, expected, result)
print("Worker check passed: matching, wrong, failed, unset, and missing worker.")
