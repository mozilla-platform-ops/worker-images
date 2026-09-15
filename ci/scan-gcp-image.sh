#!/bin/bash
set -euo pipefail

: "${IMAGE_NAME:?}" "${PROJECT_ID:?}" "${WIZ_CLIENT_ID:?}" "${WIZ_CLIENT_SECRET:?}"
# Update version and checksum together; verified against the vendor's release object.
version=1.75.0
sha256=1ba377887ed9d0543fd24d9ba0db778e52dce0c54ad35dd194410f9f64cd609a
cli=$(mktemp)
trap 'rm -f "$cli"' EXIT
curl -fsSL --retry 3 --retry-all-errors \
  "https://downloads.wiz.io/v1/wizcli/${version}/wizcli-linux-amd64" -o "$cli"
printf '%s  %s\n' "$sha256" "$cli" | sha256sum --check --strict
chmod +x "$cli"
"$cli" auth --id "$WIZ_CLIENT_ID" --secret "$WIZ_CLIENT_SECRET"
"$cli" vm-image scan --id "$IMAGE_NAME" --region us-west1 \
  --subscriptionId "$PROJECT_ID" --secrets --show-vulnerability-details --policy-hits-only
