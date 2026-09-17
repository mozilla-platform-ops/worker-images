"""Run after packer init: python3 ci/test-foofrix-config.py (no Azure calls)."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
packer = os.environ.get('PACKER', 'packer')
uuid = '00000000-0000-0000-0000-000000000001'
env = {**os.environ, 'PKR_VAR_config': 'win11-24h2',
       'PKR_VAR_subscription_id': uuid, 'PKR_VAR_tenant_id': uuid,
       'PKR_VAR_client_id': uuid, 'PKR_VAR_build_identity_id': '/unused',
       'PKR_VAR_artifact_storage_account': 'unusedstorage',
       'PKR_VAR_oidc_request_url': 'https://example.invalid',
       'PKR_VAR_oidc_request_token': 'test'}


def evaluate(template, expression, success=True):
    result = subprocess.run([packer, 'console', str(template)], input=expression + '\n',
                            env=env, text=True, capture_output=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result.stdout.strip() if success else None


template = root / 'packer/foofrix-azure.pkr.hcl'
config = json.loads(evaluate(template, 'jsonencode(local.config)'))
assert evaluate(template, 'local.image_version') == config['azure']['image_version']
with tempfile.TemporaryDirectory(prefix='foofrix-config-') as directory:
    scratch = Path(directory)
    (scratch / 'packer').mkdir()
    (scratch / 'config/foofrix').mkdir(parents=True)
    copied = scratch / 'packer' / template.name
    shutil.copyfile(template, copied)
    yaml_file = scratch / 'config/foofrix/win11-24h2.yaml'
    # JSON is valid YAML; exercise Packer's real decoder without a Python YAML dependency.
    config['azure']['image_version'] = '9.8.7'
    config['software']['node'] = '24.99.0'
    yaml_file.write_text(json.dumps(config))
    assert evaluate(copied, 'local.image_version') == '9.8.7'
    guest_config = json.loads(evaluate(copied, 'jsonencode(local.config)'))
    assert guest_config['software']['node'] == '24.99.0'
    for invalid in ('latest', '1.2', '1.2.3-extra'):
        config['azure']['image_version'] = invalid
        yaml_file.write_text(json.dumps(config))
        evaluate(copied, 'local.image_version', success=False)
    del config['azure']['image_version']
    yaml_file.write_text(json.dumps(config))
    evaluate(copied, 'local.image_version', success=False)
print('YAML gallery/software selection and invalid gallery version checks passed.')
