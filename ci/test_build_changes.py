"""Offline regression checks: python3 -m unittest discover -s ci -p 'test_*.py'."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from github_log import format_duration, log_message

ROOT = Path(__file__).resolve().parent.parent
region_spec = importlib.util.spec_from_file_location(
    "region_check", ROOT / "ci/check-azure-regions.py"
)
region_check = importlib.util.module_from_spec(region_spec)
region_spec.loader.exec_module(region_check)


class BuildChecks(unittest.TestCase):
    def test_region_coverage(self):
        expected, actual, missing, extra = region_check.coverage_difference(
            {"eastus", "westeurope"}, ["East US", "west-us"], "Central US"
        )
        self.assertEqual(missing, ["westeurope"])
        self.assertEqual(extra, ["westus"])
        self.assertIn("centralus", expected)
        self.assertIn("centralus", actual)
        self.assertEqual(
            region_check.coverage_difference({"eastus"}, [], "East US")[2:], ([], [])
        )
        with self.assertRaises(ValueError):
            region_check.normalize_region("")

    def test_pool_specific_region_and_trust_mapping(self):
        image = {
            "azure2": {"resource_group": "RG", "name": "image"},
            "azure_trusted": {"resource_group": "RG", "name": "image"},
        }
        images = {"resolved-alias": image}
        pools = [
            SimpleNamespace(
                provider_id=provider,
                config={
                    "image": "resolved-alias",
                    "locations": locations,
                    "maxCapacity": capacity,
                },
            )
            for provider, locations, capacity in [
                ("azure2", ["Central India"], 10),
                ("azure_trusted", ["west-us-2"], 10),
                ("azure2", ["east-us"], 0),
                ("fxci-level1-gcp", ["us-west1"], 10),
            ]
        ]
        required = region_check.pool_regions(pools, images)
        self.assertEqual(required[("azure2", "rg", "image", "image")], {"centralindia"})
        self.assertEqual(
            required[("azure_trusted", "rg", "image", "image")], {"westus2"}
        )
        self.assertEqual(len(required), 2)

    def test_log_escaping_and_duration(self):
        out = io.StringIO()
        with (
            patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}),
            contextlib.redirect_stdout(out),
        ):
            log_message("warning", "100%\r\n::error::text")
        self.assertEqual(out.getvalue(), "::warning::100%25%0D%0A::error::text\n")
        self.assertEqual(
            [format_duration(x) for x in (-1, 0, 60, 3661)],
            ["-", "0s", "1m 0s", "1h 1m"],
        )

    def test_workflow_authorization(self):
        with tempfile.TemporaryDirectory() as temp:
            github = Path(temp) / ".github"
            github.mkdir()
            (github / "relsre.json").write_text(json.dumps(["release"]))
            (github / "tceng.json").write_text(json.dumps(["engineer"]))
            for actor, tceng, expected in [
                ("release", False, 0),
                ("engineer", False, 1),
                ("engineer", True, 0),
                ("outsider", True, 1),
                ("", True, 1),
            ]:
                command = [
                    "pwsh",
                    "-NoProfile",
                    "-File",
                    str(ROOT / "ci/check-authorized-user.ps1"),
                ]
                if tceng:
                    command.append("-IncludeTCEng")
                result = subprocess.run(
                    command,
                    cwd=temp,
                    env=dict(os.environ, GITHUB_ACTOR=actor),
                    capture_output=True,
                )
                self.assertEqual(
                    result.returncode, expected, result.stdout + result.stderr
                )

    def test_puppet_exit_and_trusted_security_handlers(self):
        # Execute real exit statements in child processes; no Windows/cloud side effects.
        prelude = r"""
$ErrorActionPreference = 'Stop'
function Get-ItemProperty { @{ last_run_exit=42; worker_pool_id=$env:TEST_POOL; bootstrap_stage='initial' } }
function Set-ItemProperty { param($Path, $Name, $Value) Write-Output "PROPERTY:$Name=$Value" }
function Set-Location {}
function Get-ChildItem { @() }
function Test-Path { $true }
function Remove-Item { Write-Output 'REMOVED_OLD_KEY' }
function New-Item {
    if ($env:TEST_KEY_FAILURE -eq 'create') { throw 'create failed' }
    Write-Output 'CREATED_KEY'
}
function Set-Content {
    param($Path, $Value)
    if ($env:TEST_KEY_FAILURE -eq 'write') { throw 'write failed' }
    if ($Value -ne 'test-key') { throw 'wrong key' }
    Write-Output 'WROTE_KEY'
}
function New-NetFirewallRule {
    param($DisplayName, $Direction, $Program, $Action)
    if ($DisplayName -ne 'Block LiveLog' -or $Direction -ne 'Outbound' -or
        $Program -ne 'c:\generic-worker\livelog.exe' -or $Action -ne 'block') { throw 'wrong firewall rule' }
    Write-Output 'BLOCKED_LIVELOG'
}
function Write-Log {}
function Start-Sleep {}
function Add-Content {}
function Get-Content {
    '[{"level":"warning","message":"safe-warning"},{"level":"err","message":"Private Key redacted-secret"}]'
}
function Move-StrapPuppetLogs { Write-Output 'MOVED_LOGS' }
function puppet { $global:LASTEXITCODE = [int]$env:TEST_EXIT }
"""
        source = (
            ROOT
            / "scripts/windows/CustomFunctions/Bootstrap/Public/Start-AzRoninPuppet.ps1"
        )
        script = prelude + f"\n. '{source}'\nStart-AzRoninPuppet\n"
        cases = [
            (code, pool, "test-key", "")
            for code in (0, 1, 2, 4, 6, 99)
            for pool in ("win-test", "trusted-win-test")
        ]
        cases += [
            (code, "trusted-win-test", key, failure)
            for code in (0, 2)
            for key, failure in (
                ("", ""),
                ("test-key", "create"),
                ("test-key", "write"),
            )
        ]
        for code, pool, key, failure in cases:
            with self.subTest(code=code, pool=pool, key=key, failure=failure):
                env = dict(
                    os.environ,
                    TEST_EXIT=str(code),
                    TEST_POOL=pool,
                    COTKEY=key,
                    TEST_KEY_FAILURE=failure,
                )
                result = subprocess.run(
                    ["pwsh", "-NoProfile", "-Command", script],
                    env=env,
                    text=True,
                    capture_output=True,
                )
                success = code in (0, 2)
                trusted = pool.startswith("trusted")
                expected = code if code in (0, 1, 2, 4, 6) else 1
                if success and trusted and (not key or failure):
                    expected = 1
                self.assertEqual(
                    result.returncode, expected, result.stdout + result.stderr
                )
                blocked = success and trusted and bool(key) and not failure
                self.assertEqual("BLOCKED_LIVELOG" in result.stdout, blocked)
                self.assertEqual("WROTE_KEY" in result.stdout, blocked)
                self.assertEqual("MOVED_LOGS" in result.stdout, code in (1, 4, 6))
                self.assertNotIn("redacted-secret", result.stdout)
                if code in (1, 4, 6):
                    self.assertIn("safe-warning", result.stdout)


if __name__ == "__main__":
    unittest.main()
