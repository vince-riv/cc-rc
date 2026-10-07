#!/usr/bin/env bash
set -euo pipefail

# GitLab CLI: fetch the latest release binary straight from GitLab, since
# it isn't in Ubuntu's apt repos. Checksum-verified.
arch="$(dpkg --print-architecture)"
version="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest \
    | grep -oP '"tag_name":\s*"v\K[^"]+' | head -1)"
tarball="glab_${version}_linux_${arch}.tar.gz"
base="https://gitlab.com/gitlab-org/cli/-/releases/v${version}/downloads"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "/tmp/${tarball}" \
    "${base}/${tarball}"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/glab_checksums.txt \
    "${base}/checksums.txt"
(cd /tmp && grep " ${tarball}\$" glab_checksums.txt | sha256sum -c -)
mkdir /tmp/glab_extract
tar -xzf "/tmp/${tarball}" -C /tmp/glab_extract
install -m 0755 /tmp/glab_extract/bin/glab /usr/local/bin/glab
glab --version
