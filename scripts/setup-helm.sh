#!/usr/bin/env bash
set -euo pipefail

# Helm: official install script, verifies its own checksum. Pinned to the
# latest v4 tag so it doesn't fall back to a v3 release.
version="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://api.github.com/repos/helm/helm/releases \
    | grep -oP '"tag_name":\s*"\Kv4[^"]+' | head -1)"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | DESIRED_VERSION="${version}" bash
helm version

# renovate: datasource=github-releases depName=norwoodj/helm-docs
HELM_DOCS_VERSION=v1.14.2
GOBIN=/usr/local/bin go install github.com/norwoodj/helm-docs/cmd/helm-docs@${HELM_DOCS_VERSION}
rm -rf /root/go /root/.cache/go-build
