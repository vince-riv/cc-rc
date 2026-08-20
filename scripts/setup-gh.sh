#!/usr/bin/env bash
set -euo pipefail

# GitHub CLI: fetch the latest release binary straight from GitHub instead
# of Ubuntu's apt package, which trails upstream by a wide margin.
arch="$(dpkg --print-architecture)"
version="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
    | grep -oP '"tag_name":\s*"v\K[^"]+')"
tarball="gh_${version}_linux_${arch}.tar.gz"
curl -fsSL -o "/tmp/${tarball}" \
    "https://github.com/cli/cli/releases/download/v${version}/${tarball}"
curl -fsSL -o /tmp/gh_checksums.txt \
    "https://github.com/cli/cli/releases/download/v${version}/gh_${version}_checksums.txt"
(cd /tmp && grep " ${tarball}\$" gh_checksums.txt | sha256sum -c -)
tar -xzf "/tmp/${tarball}" -C /tmp
install -m 0755 "/tmp/gh_${version}_linux_${arch}/bin/gh" /usr/local/bin/gh
