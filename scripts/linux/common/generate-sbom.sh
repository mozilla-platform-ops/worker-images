#!/usr/bin/env bash

set -euo pipefail

output_path="${SBOM_OUTPUT:-/etc/worker-images/SBOM.md}"
output_dir="$(dirname "${output_path}")"
os_release_path="${OS_RELEASE_PATH:-/etc/os-release}"
mkdir -p "${output_dir}"
temporary_output="$(mktemp "${output_path}.XXXXXX")"

cleanup() {
  rm -f "${temporary_output}"
}
trap cleanup EXIT

markdown_table_row() {
  local value
  for value in "$@"; do
    value="${value//|/\\|}"
    printf '| %s ' "${value}"
  done
  printf '|\n'
}

write_taskcluster_tools() {
  local tool tool_path version
  local found_tool=false

  for tool in generic-worker start-worker livelog taskcluster-proxy; do
    if tool_path="$(command -v "${tool}" 2>/dev/null)"; then
      version="$("${tool_path}" --version 2>&1 | head -n 1 || true)"
      markdown_table_row "${tool}" "${version:-installed (version unavailable)}"
      found_tool=true
    fi
  done

  if [[ "${found_tool}" == false ]]; then
    markdown_table_row "None" "No Taskcluster tools found in PATH"
  fi
}

os_release_value() {
  local key="$1"

  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "${os_release_path}"
}

os_name_and_version() {
  local name version

  name="$(os_release_value NAME)"
  version="$(os_release_value VERSION)"
  printf '%s %s' "${name:-unknown}" "${version:-unknown}"
}

{
  printf '# Linux worker image SBOM\n\n'

  printf '## Build provenance\n\n'
  printf -- '- Image name: %s\n' "${IMAGE_NAME:-unknown}"
  printf -- '- Taskcluster version: %s\n' "${TASKCLUSTER_VERSION:-unknown}"
  printf -- '- Taskcluster ref: %s\n' "${TASKCLUSTER_REF:-unknown}"
  printf -- '- Architecture: %s\n' "${TC_ARCH:-unknown}"
  printf -- '- Source image family: %s\n' "${SOURCE_IMAGE_FAMILY:-unknown}"
  printf -- '- GCP project: %s\n' "${PROJECT_ID:-unknown}"
  printf -- '- GCP zone: %s\n\n' "${ZONE:-unknown}"

  printf '## Operating system\n\n'
  printf -- '- OS: %s\n' "$(os_name_and_version)"
  printf -- '- Kernel: %s\n' "$(uname -srmo)"
  printf -- '- Machine architecture: %s\n\n' "$(uname -m)"

  printf '## Taskcluster tools\n\n'
  markdown_table_row 'Name' 'Version'
  markdown_table_row '---' '---'
  write_taskcluster_tools
  printf '\n'

  printf '## Python packages\n\n'
  markdown_table_row 'Name' 'Version'
  markdown_table_row '---' '---'
  if python3 -m pip list --format=freeze 2>/dev/null | while IFS='=' read -r name version; do
    markdown_table_row "${name}" "${version#=}"
  done; then
    :
  else
    markdown_table_row 'None' 'python3 pip is unavailable'
  fi
  printf '\n'

  printf '## dpkg packages\n\n'
  markdown_table_row 'Name' 'Version' 'Architecture'
  markdown_table_row '---' '---' '---'
  while IFS=$'\t' read -r name version architecture; do
    markdown_table_row "${name}" "${version}" "${architecture}"
  done < <(dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' | LC_ALL=C sort)
} > "${temporary_output}"

mv "${temporary_output}" "${output_path}"
chmod 0644 "${output_path}"
trap - EXIT
