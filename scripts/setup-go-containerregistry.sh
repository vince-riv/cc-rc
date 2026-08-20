#!/usr/bin/env bash
set -euo pipefail

# go-containerregistry's release tarball, checksum-verified. Not `go
# install`'d: krane's own go.mod has a local `replace` directive that `go
# install` won't honor outside the main module, so crane is built the same
# way for consistency.
# renovate: datasource=github-releases depName=google/go-containerregistry
GO_CONTAINERREGISTRY_VERSION=v0.21.9

case "$(dpkg --print-architecture)" in
    amd64) arch=x86_64 ;;
    arm64) arch=arm64 ;;
    *) echo "unsupported architecture" >&2; exit 1 ;;
esac

tarball="go-containerregistry_Linux_${arch}.tar.gz"
curl -fsSL -o "/tmp/${tarball}" \
    "https://github.com/google/go-containerregistry/releases/download/${GO_CONTAINERREGISTRY_VERSION}/${tarball}"
curl -fsSL -o /tmp/gcr_checksums.txt \
    "https://github.com/google/go-containerregistry/releases/download/${GO_CONTAINERREGISTRY_VERSION}/checksums.txt"
(cd /tmp && grep " ${tarball}\$" gcr_checksums.txt | sha256sum -c -)

# Install every binary the tarball ships (crane, gcrane, krane, ...), not a
# hardcoded subset, so new tools upstream adds show up here automatically.
tar -xzf "/tmp/${tarball}" -C /tmp
find /tmp -maxdepth 1 -type f ! -name '*.md' ! -iname LICENSE ! -name '*.tar.gz' ! -name '*_checksums.txt' \
    -exec install -m 0755 {} /usr/local/bin/ \;
