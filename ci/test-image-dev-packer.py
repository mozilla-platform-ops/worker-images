"""Evaluate the real nested-config guards with Packer, without cloud plugins."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
packer = os.environ.get('PACKER', 'packer')
for template, team in (
    ('foofrix-azure.pkr.hcl', 'foofrix'),
    ('tceng-azure.pkr.hcl', 'tceng'),
    ('tceng-gcp.pkr.hcl', 'tceng'),
    ('tceng-aws.pkr.hcl', 'tceng'),
):
    # Use the template's actual variable/validation block, without cloud builders.
    config_block = re.search(r'^variable "config" \{.*?^\}',
                             (root / 'packer' / template).read_text(), re.M | re.S)
    assert config_block, template
    with tempfile.TemporaryDirectory(prefix='image-dev-packer-') as directory:
        scratch = Path(directory)
        (scratch / 'guard.pkr.hcl').write_text(config_block.group())
        config_dir = scratch / 'config' / team
        config_dir.mkdir(parents=True)
        for dev in ('absent', 'dev/branch', '', None, False, 1, ['branch'], {'branch': 'dev'}):
            config = {} if dev == 'absent' else {'dev': dev}
            (config_dir / 'test-alpha.yaml').write_text(json.dumps(config))
            result = subprocess.run(
                [packer, 'validate', '-var', 'config=test-alpha', 'guard.pkr.hcl'],
                cwd=scratch, text=True, capture_output=True,
            )
            output = result.stdout + result.stderr
            if dev == 'absent':
                # Successful variable validation reaches the expected missing-build error.
                assert 'Missing build block' in output and 'Not authorized:' not in output, output
            else:
                assert result.returncode != 0 and 'Not authorized:' in output, output
print('All nested Packer configs reject dev, regardless of its value.')
