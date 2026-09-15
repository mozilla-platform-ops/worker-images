"""Offline checks for shared provisioning; never provision the test host."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = ROOT / "scripts/windows/tceng"
STRESS = ROOT / "provisioners/windows/MDC1Windows/utility_scripts/stress_test"

# Token hashes of the three pre-extraction scripts at a31713f7. Comments and
# layout are ignored; commands, arguments, ordering, and function bodies are not.
WINDOWS_BODIES = {
    "generic-worker-win2022": "c9d6b82342ea02a327db5dfbee7d999d97b243c2ce441d90f04596fd6450fad8",
    "generic-worker-win2022-staging": "089d110383ec04e73974ee8c950e25fb4b272ce69d2d82fb29b0f10cbe422db1",
    "generic-worker-win2025-staging": "68df7820c78e32d2b67b565261a36a85628b1c3ec62de362f5b6f2347ec2d1f0",
}


def powershell(script, **env):
    return subprocess.run(
        ["pwsh", "-NoProfile", "-Command", script],
        cwd=ROOT,
        env=os.environ | env,
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def windows_tokens(path, source=False, minimal=False):
    # Only fold the two new variant selectors. Existing guest-side conditionals
    # remain intact and are compared without executing a single guest command.
    output = powershell(
        r"""
        $errors = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:SCRIPT, [ref]$tokens, [ref]$errors)
        if ($errors) { throw ($errors | Out-String) }
        $body = foreach ($statement in $ast.EndBlock.Statements) {
            $choice = $null
            if ($statement -is [System.Management.Automation.Language.IfStatementAst]) {
                switch ($statement.Clauses[0].Item1.Extent.Text) {
                    '$BuildFromSource' { $choice = $env:SOURCE -eq 'true' }
                    '-not $SkipDevelopmentTools' { $choice = $env:MINIMAL -ne 'true' }
                }
            }
            if ($null -eq $choice) { $statement.Extent.Text }
            elseif ($choice) { $statement.Clauses[0].Item2.Statements | ForEach-Object { $_.Extent.Text } }
            elseif ($statement.ElseClause) { $statement.ElseClause.Statements | ForEach-Object { $_.Extent.Text } }
        }
        $null = [System.Management.Automation.Language.Parser]::ParseInput(($body -join "`n"), [ref]$tokens, [ref]$errors)
        if ($errors) { throw ($errors | Out-String) }
        ConvertTo-Json -Compress -InputObject @($tokens | Where-Object {
            $_.Kind -notin 'Comment', 'NewLine', 'LineContinuation', 'EndOfInput'
        } | ForEach-Object { $_.Text.Replace("`r`n", "`n") })
    """,
        SCRIPT=str(path),
        SOURCE=str(source).lower(),
        MINIMAL=str(minimal).lower(),
    )
    return hashlib.sha256(json.dumps(json.loads(output)).encode()).hexdigest()


class ProvisioningChecks(unittest.TestCase):
    def test_windows_variants_preserve_guest_commands(self):
        for name, expected in WINDOWS_BODIES.items():
            with self.subTest(name=name):
                source = name.endswith("-staging")
                minimal = "win2025" in name
                self.assertEqual(
                    windows_tokens(
                        WINDOWS / "generic-worker-common.ps1", source, minimal
                    ),
                    expected,
                )
                with tempfile.TemporaryDirectory() as tmp:
                    tmp = Path(tmp)
                    (tmp / "entry.ps1").write_text(
                        (WINDOWS / f"{name}.ps1").read_text()
                    )
                    (tmp / "generic-worker-common.ps1").write_text(
                        "param([switch]$BuildFromSource, [switch]$SkipDevelopmentTools)\n"
                        "@{source=[bool]$BuildFromSource; minimal=[bool]$SkipDevelopmentTools} | ConvertTo-Json"
                    )
                    flags = json.loads(
                        powershell("& $env:ENTRY", ENTRY=str(tmp / "entry.ps1"))
                    )
                    self.assertEqual(flags, dict(source=source, minimal=minimal))

    def test_linux_wrappers_and_invalid_mode(self):
        folder = ROOT / "scripts/linux/tceng"
        common = folder / "generic-worker-ubuntu-common.sh"
        subprocess.run(["bash", "-n", str(common)], check=True)
        for script in (
            common,
            ROOT / "scripts/linux/ubuntu-2404-amd64-gui/fxci/bootstrap.sh",
        ):
            self.assertIn(
                "systemctl mask apt-daily.timer apt-daily-upgrade.timer",
                script.read_text(),
            )
        invalid = subprocess.run(["bash", str(common), "invalid"], capture_output=True)
        self.assertEqual(invalid.returncode, 64)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / common.name).write_text('printf "%s" "$1"\n')
            for suffix, expected in [("", "release"), ("-staging", "source")]:
                wrapper = tmp / "entry.sh"
                wrapper.write_text(
                    (folder / f"generic-worker-ubuntu-24-04{suffix}.sh").read_text()
                )
                self.assertEqual(
                    subprocess.check_output(["bash", str(wrapper)], text=True), expected
                )

    def test_shared_guest_files_and_gcp_source_names(self):
        for cloud in ("aws", "gcp"):
            template = (ROOT / f"packer/tceng-{cloud}.pkr.hcl").read_text()
            self.assertIn(
                '/scripts/linux/tceng/generic-worker-ubuntu-common.sh"', template
            )
            self.assertRegex(template, r'remote_folder\s*=\s*"/tmp"')
            self.assertIn(
                'destination = "/tmp/generic-worker-ubuntu-common.sh"', template
            )
        azure = (ROOT / "packer/tceng-azure.pkr.hcl").read_text()
        self.assertIn(
            'destination = "C:/Windows/Temp/generic-worker-common.ps1"', azure
        )
        gcp = (ROOT / "gcp.pkr.hcl").read_text()
        variants = re.findall(
            r'source "source.googlecompute.base" \{(.*?)\n  \}', gcp, re.S
        )
        names = set()
        for variant in variants:
            name = re.search(r'name\s*=\s*"([^"]+)"', variant)[1]
            names.add(name)
            machine = '"t2a-standard-4"' if "arm64" in name else "var.machine_type"
            self.assertRegex(variant, rf"machine_type\s*=\s*{re.escape(machine)}")
            self.assertEqual("GVNIC" in variant, "-gui-" not in name)
        self.assertEqual(
            names, {p.stem for p in (ROOT / "config").glob("*gw-fxci-gcp-*-alpha.yaml")}
        )

    @unittest.skipIf(os.name == "nt", "uses POSIX fake ssh/scp executables")
    def test_remote_batch_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            # Fail closed if a host other than these synthetic test names is used.
            (tmp / "scp").write_text("""#!/bin/sh
case "$*" in
  *scpfail.invalid*) echo 'copy failed' >&2; exit 1 ;;
  *.invalid:*) exit 0 ;;
  *) exit 99 ;;
esac
""")
            (tmp / "ssh").write_text("""#!/bin/sh
case "$*" in
  *busy.invalid*) echo '{"Status":"busy","Hostname":"busy"}' ;;
  *bad.invalid*) echo 'not json' ;;
  *exit.invalid*) echo 'ssh failed' >&2; exit 1 ;;
  *ok.invalid*) echo '{"Status":"ok","Value":42}' ;;
  *) exit 99 ;;
esac
""")
            for executable in (tmp / "ssh", tmp / "scp"):
                executable.chmod(0o755)
            result = powershell(
                r"""
                . $env:HELPER
                $results = Invoke-RemoteScriptBatch -Fqdns @('ok.invalid', 'busy.invalid', 'bad.invalid', 'exit.invalid', 'scpfail.invalid') `
                    -Parallel 2 -User nobody -Payload 'unused' -NamePrefix test_payload -TimeoutMs 60000 `
                    -DescribeResult { param($short, $data) "$short=$($data.Value)" } 6>$null
                $results | ConvertTo-Json -Depth 5 -Compress
            """,
                HELPER=str(STRESS / "Invoke-RemoteScriptBatch.ps1"),
                TEMP=str(tmp),
                PATH=f"{tmp}{os.pathsep}{os.environ['PATH']}",
            )
            results = json.loads(result)
            self.assertEqual(results["ok.invalid"]["Data"]["Value"], 42)
            self.assertEqual(results["busy.invalid"]["_s"], "busy")
            for host in ["bad", "exit", "scpfail"]:
                self.assertEqual(results[f"{host}.invalid"]["_s"], "ssherr")
            self.assertFalse(list(tmp.glob("test_payload_*.ps1")))


if __name__ == "__main__":
    unittest.main()
