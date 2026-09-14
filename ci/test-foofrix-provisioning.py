"""Run with python3 ci/test-foofrix-provisioning.py; all Azure calls are fake."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import yaml


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/foofrix/azure-worker.sh"
SUB = "00000000-0000-0000-0000-000000000001"
PREFIX = f"/subscriptions/{SUB}/resourceGroups/rg-foofrix/providers"

with tempfile.TemporaryDirectory(prefix="foofrix-provisioning-test-") as directory:
    root = Path(directory)
    log = root / "calls.jsonl"
    fake = root / "az"
    fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FAKE_AZ_LOG'], 'a') as log:
    log.write(json.dumps({'args': args, 'cache': os.environ['AZURE_CONFIG_DIR']}) + '\\n')
if args[:2] == ['group', 'exists']:
    print(os.environ.get('FAKE_EXISTS', 'false'))
elif args[:2] == ['group', 'show']:
    print(os.environ.get('FAKE_OWNERSHIP', 'true'))
elif args[:3] == ['network', 'nic', 'create']:
    print('/fake/nic')
elif args[:2] == ['vm', 'create']:
    sys.exit(int(os.environ.get('FAKE_VM_EXIT', '0')))
elif args[:2] == ['vm', 'show']:
    print(json.dumps({'name': 'foofrix-win-01', 'privateIps': '10.0.0.4'}))
""")
    fake.chmod(0o755)
    env = {
        **os.environ,
        "PATH": str(root) + os.pathsep + os.environ["PATH"],
        "FAKE_AZ_LOG": str(log),
        "AZURE_TENANT_ID": "dummy-tenant",
        "AZURE_SUBSCRIPTION_ID": SUB,
        "AZURE_CLIENT_ID": "dummy-provisioner",
        "AZURE_CLIENT_SECRET": "dummy-secret",
        "WINDOWS_ADMIN_PASSWORD": "dummy-password",
        "AZURE_IMAGE_VERSION_ID": PREFIX + "/Microsoft.Compute/galleries/foofrix/images/windows/versions/0.1.0",
        "AZURE_WORKER_IDENTITY_ID": PREFIX + "/Microsoft.ManagedIdentity/userAssignedIdentities/worker",
        "AZURE_SUBNET_ID": PREFIX + "/Microsoft.Network/virtualNetworks/workers/subnets/default",
        "AZURE_NSG_ID": PREFIX + "/Microsoft.Network/networkSecurityGroups/workers",
        "AZURE_VM_SIZE": "Standard_D8ads_v5",
    }

    fields = {
        'tenant_id': 'AZURE_TENANT_ID', 'subscription_id': 'AZURE_SUBSCRIPTION_ID',
        'client_id': 'AZURE_CLIENT_ID', 'image_version_id': 'AZURE_IMAGE_VERSION_ID',
        'worker_identity_id': 'AZURE_WORKER_IDENTITY_ID', 'subnet_id': 'AZURE_SUBNET_ID',
        'nsg_id': 'AZURE_NSG_ID', 'vm_size': 'AZURE_VM_SIZE', 'location': 'AZURE_LOCATION',
        'os_disk_gb': 'AZURE_OS_DISK_GB', 'admin_username': 'WINDOWS_ADMIN_USERNAME',
        'security_type': 'AZURE_SECURITY_TYPE',
    }

    def run(action, *, name="foofrix-win-01", success=True, config_text=None, **overrides):
        log.write_text("")
        values = {**env, **overrides}
        config = root / 'settings.yaml'
        config.write_text(config_text if config_text is not None else yaml.safe_dump({key: values.get(variable, '') for key, variable in fields.items()}))
        # Non-secret Azure settings must actually come from YAML, not inherited env.
        process_env = {key: value for key, value in values.items() if key not in fields.values()}
        result = subprocess.run(["bash", str(SCRIPT), action, name, '--config', str(config)], env=process_env, text=True, capture_output=True)
        assert (result.returncode == 0) == success, result.stderr
        assert "dummy-secret" not in result.stdout + result.stderr
        assert "dummy-password" not in result.stdout + result.stderr
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        for call in calls:
            assert not Path(call["cache"]).exists(), "Temporary Azure login cache was not removed"
        return result, [call["args"] for call in calls]

    result, calls = run("create")
    assert json.loads(result.stdout)["privateIps"] == "10.0.0.4"
    vm = next(call for call in calls if call[:2] == ["vm", "create"])
    assert vm[vm.index("--priority") + 1] == "Regular"
    assert vm[vm.index("--assign-identity") + 1] == env["AZURE_WORKER_IDENTITY_ID"]
    assert vm[vm.index("--nics") + 1] == "/fake/nic"
    assert vm[vm.index("--os-disk-size-gb") + 1] == "1024"
    assert not any("--public-ip-address" in call or call[:3] == ["network", "public-ip", "create"] for call in calls)

    _, calls = run("create", success=False, FAKE_EXISTS="true")
    assert not any(call[:2] in (["group", "create"], ["vm", "create"], ["group", "delete"]) for call in calls)
    _, calls = run("create", success=False, FAKE_VM_EXIT="1")
    assert not any(call[:2] == ["group", "delete"] for call in calls), "Failed builds must retain resources for diagnosis"
    _, calls = run("create", success=False, AZURE_IMAGE_VERSION_ID=env["AZURE_IMAGE_VERSION_ID"].replace("0.1.0", "latest"))
    assert not calls
    _, calls = run("create", success=False, AZURE_SUBNET_ID="/subscriptions/another-sub/resourceGroups/network")
    assert not calls
    _, calls = run("delete", name="foofrix", success=False)
    assert not calls, "Must not operate on the shared rg-foofrix group"
    _, calls = run("delete", success=False, FAKE_OWNERSHIP="false")
    assert not any(call[:2] == ["group", "delete"] for call in calls)
    _, calls = run("delete")
    deletion = next(call for call in calls if call[:2] == ["group", "delete"])
    assert deletion[deletion.index("--name") + 1] == "rg-foofrix-win-01"
    _, calls = run("stop")
    assert any(call[:2] == ["vm", "deallocate"] for call in calls)
    assert not any(call[:2] == ["group", "delete"] for call in calls)
    for invalid in ('[]', 'client_secret: do-not-store-here', 'tenant_id: [nested]', 'tenant_id: true', 'tenant_id: "line1\\nline2"', 'tenant_id: ['):
        _, calls = run('create', success=False, config_text=invalid)
        assert not calls, 'Invalid config must fail before Azure login'
    _, calls = run('create', success=False, config_text=(SCRIPT.parents[2] / 'config/foofrix/provisioning.example.yaml').read_text())
    assert not calls, 'Unfilled example must fail before Azure login'
    marker = root / 'must-not-exist'
    _, calls = run('create', AZURE_VM_SIZE=f'$(touch {marker})')
    assert not marker.exists(), 'Config must never execute shell substitutions'
    vm = next(call for call in calls if call[:2] == ['vm', 'create'])
    assert vm[vm.index('--size') + 1] == f'$(touch {marker})'
    print("All Azure provisioning example checks passed (mocked Azure CLI).")
