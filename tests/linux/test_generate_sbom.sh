#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
generator="${repo_root}/scripts/linux/common/generate-sbom.sh"
test_dir="$(mktemp -d)"
mock_bin="${test_dir}/bin"
output_path="${test_dir}/SBOM.md"
os_release_path="${test_dir}/os-release"

cleanup() {
  rm -rf "${test_dir}"
}
trap cleanup EXIT

mkdir -p "${mock_bin}"

printf '%s\n' 'NAME="Ubuntu"' 'VERSION="24.04 LTS"' > "${os_release_path}"

printf '%s\n' '#!/usr/bin/env bash' \
  'printf "sample-package\t1.2.3\tamd64\n"' > "${mock_bin}/dpkg-query"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "$*" == "-m pip list --format=freeze" ]]; then' \
  '  printf "sample-python-package==4.5.6\n"' \
  'fi' > "${mock_bin}/python3"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$1" in' \
  '  -srmo) printf "Linux 6.8.0 test x86_64\n" ;;' \
  '  -m) printf "x86_64\n" ;;' \
  'esac' > "${mock_bin}/uname"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "generic-worker 100.4.0\n"' > "${mock_bin}/generic-worker"
chmod +x "${mock_bin}"/*

PATH="${mock_bin}:${PATH}" \
IMAGE_NAME='test-image' \
TASKCLUSTER_VERSION='100.4.0' \
TASKCLUSTER_REF='v100.4.0' \
TC_ARCH='amd64' \
SOURCE_IMAGE_FAMILY='ubuntu-2404' \
PROJECT_ID='test-project' \
ZONE='us-west1-a' \
SBOM_OUTPUT="${output_path}" \
OS_RELEASE_PATH="${os_release_path}" \
bash "${generator}"

grep -Fqx '# Linux worker image SBOM' "${output_path}"
grep -Fqx -- '- Image name: test-image' "${output_path}"
grep -Fqx -- '- Kernel: Linux 6.8.0 test x86_64' "${output_path}"
grep -Fqx -- '- OS: Ubuntu 24.04 LTS' "${output_path}"
grep -Fqx '| generic-worker | generic-worker 100.4.0 |' "${output_path}"
grep -Fqx '| sample-python-package | 4.5.6 |' "${output_path}"
grep -Fqx '| sample-package | 1.2.3 | amd64 |' "${output_path}"
