#!/usr/bin/env bash
# Run on Perf's GCP Linux launcher. See config/foofrix/provisioning.md.
# Do not enable shell tracing: credentials are provided through the environment.
set +x
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/foofrix/azure-worker.sh create|show|stop|delete VM_NAME --config CONFIG.yaml

VM_NAME: foofrix- followed by lowercase letters/digits/hyphens; 15 characters max.
Copy config/foofrix/provisioning.example.yaml and fill in the Azure settings.
All actions require AZURE_CLIENT_SECRET in the environment for the FooFrix
VM-provisioning service principal. Create also requires WINDOWS_ADMIN_PASSWORD.

YAML optional defaults: location=centralus, admin_username=foofrixadmin,
os_disk_gb=1024, security_type=Standard. Requires Python 3 with PyYAML.

Creates a regular Windows VM with a private NIC and a managed OS disk.
stop deallocates compute but retains disks. delete removes the worker resource
group and ALL its disks/resources permanently. Export results before deletion.
The script does not queue jobs, start the harness, or impose a lifetime limit.
EOF
}
die() { echo "error: $*" >&2; exit 1; }
require() { [[ -n "${!1:-}" ]] || die "Set $1"; }

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
[[ $# == 4 && "$3" == --config ]] || { usage >&2; exit 1; }
action=$1
vm=$2
case "$action" in create|show|stop|delete) ;; *) die "Unknown action: $action" ;; esac
[[ "$vm" =~ ^foofrix-[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#vm} -le 15 ]] || die 'Use a foofrix- VM name, at most 15 characters'
group="rg-$vm"

# Parse only documented settings; never evaluate YAML content as shell code.
config_values=$(python3 - "$4" <<'PY'
import sys
import yaml

fields = {
    'tenant_id': 'AZURE_TENANT_ID',
    'subscription_id': 'AZURE_SUBSCRIPTION_ID',
    'client_id': 'AZURE_CLIENT_ID',
    'image_version_id': 'AZURE_IMAGE_VERSION_ID',
    'worker_identity_id': 'AZURE_WORKER_IDENTITY_ID',
    'subnet_id': 'AZURE_SUBNET_ID',
    'nsg_id': 'AZURE_NSG_ID',
    'vm_size': 'AZURE_VM_SIZE',
    'location': 'AZURE_LOCATION',
    'os_disk_gb': 'AZURE_OS_DISK_GB',
    'admin_username': 'WINDOWS_ADMIN_USERNAME',
    'security_type': 'AZURE_SECURITY_TYPE',
}
try:
    with open(sys.argv[1]) as stream:
        config = yaml.safe_load(stream)
    if not isinstance(config, dict) or any(key not in fields for key in config):
        raise ValueError('Use only the settings in provisioning.example.yaml; secrets must come from the environment')
    for key, name in fields.items():
        value = config.get(key, '')
        if type(value) not in (str, int) or any(c in str(value) for c in '\r\n\0'):
            raise ValueError(f'{key} must be a single-line string or integer')
        print(f'{name}={value}')
except (OSError, ValueError, yaml.YAMLError) as error:
    sys.exit(f'Invalid provisioning YAML: {error}')
PY
) || die 'Could not load config (requires Python 3 and PyYAML)'
while IFS='=' read -r name value; do
  printf -v "$name" '%s' "$value"
done <<< "$config_values"

for variable in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET; do require "$variable"; done

if [[ "$action" == create ]]; then
  for variable in AZURE_IMAGE_VERSION_ID AZURE_WORKER_IDENTITY_ID AZURE_SUBNET_ID AZURE_NSG_ID AZURE_VM_SIZE WINDOWS_ADMIN_PASSWORD; do require "$variable"; done
  # Keep this example within the isolated FooFrix subscription.
  for variable in AZURE_IMAGE_VERSION_ID AZURE_WORKER_IDENTITY_ID AZURE_SUBNET_ID AZURE_NSG_ID; do
    value=${!variable}
    [[ "${value,,}" == "/subscriptions/${AZURE_SUBSCRIPTION_ID,,}/"* ]] || die "$variable must belong to the FooFrix subscription"
  done
  [[ "$AZURE_IMAGE_VERSION_ID" =~ /galleries/[^/]+/images/[^/]+/versions/[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Use an exact gallery image version ID, not latest'
  [[ "${AZURE_OS_DISK_GB:-1024}" =~ ^[1-9][0-9]*$ ]] || die 'AZURE_OS_DISK_GB must be a positive integer'
fi

command -v az >/dev/null || die 'Install Azure CLI on the launcher first'
umask 077
# Each invocation has its own login/cache, including concurrent launcher jobs.
worker_azure_config=$(mktemp -d)
trap 'rm -rf -- "$worker_azure_config"' EXIT
export AZURE_CONFIG_DIR="$worker_azure_config"
az login --service-principal --username "$AZURE_CLIENT_ID" \
  --password "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID" \
  --only-show-errors --output none
az account set --subscription "$AZURE_SUBSCRIPTION_ID"

if [[ "$action" == create ]]; then
  exists=$(az group exists --name "$group" --output tsv --only-show-errors)
  [[ "$exists" == false ]] || die "$group already exists; inspect it with show or explicitly delete it first"
  az group create --name "$group" --location "${AZURE_LOCATION:-centralus}" \
    --tags managed_by=foofrix-azure-worker "worker=$vm" \
    --only-show-errors --output none
  # No public IP is created. The shared subnet must provide outbound connectivity.
  nic_id=$(az network nic create --resource-group "$group" --name "$vm-nic" \
    --location "${AZURE_LOCATION:-centralus}" --subnet "$AZURE_SUBNET_ID" \
    --network-security-group "$AZURE_NSG_ID" --query NewNIC.id --output tsv --only-show-errors)
  az vm create --resource-group "$group" --name "$vm" \
    --location "${AZURE_LOCATION:-centralus}" --image "$AZURE_IMAGE_VERSION_ID" \
    --size "$AZURE_VM_SIZE" --nics "$nic_id" --os-type Windows \
    --admin-username "${WINDOWS_ADMIN_USERNAME:-foofrixadmin}" --admin-password "$WINDOWS_ADMIN_PASSWORD" \
    --assign-identity "$AZURE_WORKER_IDENTITY_ID" --priority Regular \
    --security-type "${AZURE_SECURITY_TYPE:-Standard}" \
    --os-disk-size-gb "${AZURE_OS_DISK_GB:-1024}" --storage-sku Premium_LRS \
    --tags managed_by=foofrix-azure-worker "worker=$vm" \
    --only-show-errors --output none
else
  ownership=$(az group show --name "$group" \
    --query "tags.managed_by == 'foofrix-azure-worker' && tags.worker == '$vm'" --output tsv --only-show-errors)
  [[ "$ownership" == true ]] || die 'Resource group ownership tags do not match; refusing operation'
fi

case "$action" in
  create|show)
    az vm show --resource-group "$group" --name "$vm" --show-details \
      --query '{id:id,name:name,resourceGroup:resourceGroup,privateIps:privateIps,powerState:powerState}' \
      --output json --only-show-errors
    ;;
  stop)
    az vm deallocate --resource-group "$group" --name "$vm" --only-show-errors --output none
    ;;
  delete)
    az group delete --name "$group" --yes --only-show-errors --output none
    ;;
esac
