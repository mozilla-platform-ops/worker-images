#!/usr/bin/env python3

import os
import subprocess
import tempfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "scripts/linux/common/ephemeral-disks.sh"
STUB = """#!/bin/sh
name=${0##*/}
printf '%s' "$name" >> "$CALLS"
for arg do
    printf '\\t%s' "$arg" >> "$CALLS"
done
printf '\\n' >> "$CALLS"
case "$name" in
    mount)
        if [ "$#" -eq 0 ] && [ "$SCENARIO" = mounted ]; then
            echo '/dev/mapper/instance_storage-lv_instance_storage on /mnt type ext4 (rw)'
        fi
        ;;
    ls)
        [ "$SCENARIO" != noscratch ] || exit 2
        echo /dev/disk/by-id/google-local-nvme-ssd-0
        echo /dev/disk/by-id/google-local-nvme-ssd-1
        ;;
esac
exit 0
"""


def check(scenario, source=SOURCE):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        bindir = root / "bin"
        bindir.mkdir()
        for name in (
            "systemctl",
            "apt-get",
            "ls",
            "mkdir",
            "mount",
            "umount",
            "cp",
            "vgcreate",
            "lvcreate",
            "mkfs.ext4",
        ):
            command = bindir / name
            command.write_text(STUB)
            command.chmod(0o755)
        calls = root / "calls"
        env = dict(
            os.environ,
            PATH=f"{bindir}:{os.environ['PATH']}",
            CALLS=str(calls),
            SCENARIO=scenario,
        )
        setup = root / "disk-setup"
        unit = root / "disk-setup.service"
        installer = (
            source.read_text()
            .replace("/usr/local/bin/configure-generic-worker-disks", str(setup))
            .replace("/etc/systemd/system/generic-worker-disk-setup.service", str(unit))
        )
        subprocess.run(
            ["bash", "-c", installer], env=env, check=True, capture_output=True
        )
        assert "Before=worker.service docker.service" in unit.read_text()
        fstab = root / "fstab"
        original_fstab = "/dev/root / ext4 defaults 0 1\n"
        if scenario == "mounted":
            original_fstab += (
                "/dev/instance_storage/lv_instance_storage /mnt ext4 defaults\n"
            )
        fstab.write_text(original_fstab)
        setup.write_text(setup.read_text().replace("/etc/fstab", str(fstab)))
        calls.write_text("")
        subprocess.run(["sh", str(setup)], env=env, check=True, capture_output=True)
        commands = [line.split("\t") for line in calls.read_text().splitlines()]
        assert not any("/home" in arg for command in commands for arg in command)
        assert "/home" not in fstab.read_text()
        assert ["mkdir", "-p", "/mnt/var/lib/docker"] in commands
        assert fstab.read_text().startswith(original_fstab)
        if scenario == "scratch":
            assert [
                "vgcreate",
                "-y",
                "instance_storage",
                "/dev/disk/by-id/google-local-nvme-ssd-0",
                "/dev/disk/by-id/google-local-nvme-ssd-1",
            ] in commands
            assert [
                "mkfs.ext4",
                "-E",
                "lazy_journal_init=1",
                "/dev/instance_storage/lv_instance_storage",
            ] in commands
            assert any(c[0] == "mount" and c[-1] == "/mnt" for c in commands)
            assert "/dev/instance_storage/lv_instance_storage /mnt" in fstab.read_text()
        else:
            assert not any(
                c[0] in ("vgcreate", "lvcreate", "mkfs.ext4", "umount")
                for c in commands
            )
            assert not any(c[0] == "mount" and len(c) > 1 for c in commands)
            assert fstab.read_text() == original_fstab


if __name__ == "__main__":
    for layout in ("scratch", "noscratch", "mounted"):
        check(layout)
    print("Ephemeral disk checks passed")
