#!/usr/bin/env bash
set -euo pipefail

# Node.js: prebuilt tarballs from nodejs.org, checksum-verified — same
# pattern as kubectl. Lands under /usr/local/node-<major>/, registered
# with update-alternatives (like go 1.25/1.26), highest major wins by
# default. Installing here instead of via `nvm install` (as `dev`) keeps
# these three copies out of ~/.nvm, which is what used to make dev's home
# directory huge. `dev`'s nvm still gets these versions registered against
# it - see setup-dev.sh - so `nvm use 22/24/26` works without re-downloading.
#
# renovate: datasource=node-version depName=node-22
NODE22_VERSION=v22.23.2
# renovate: datasource=node-version depName=node-24
NODE24_VERSION=v24.20.0
# renovate: datasource=node-version depName=node-26
NODE26_VERSION=v26.8.1

case "$(dpkg --print-architecture)" in
    amd64) node_arch=x64 ;;
    arm64) node_arch=arm64 ;;
    *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

install_node() {
    local version="$1" priority="$2"
    local major="${version#v}"
    major="${major%%.*}"
    local tarball="node-${version}-linux-${node_arch}.tar.xz"

    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
        -o "/tmp/${tarball}" \
        "https://nodejs.org/dist/${version}/${tarball}"
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
        -o /tmp/SHASUMS256.txt \
        "https://nodejs.org/dist/${version}/SHASUMS256.txt"
    (cd /tmp && grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -)

    rm -rf "/usr/local/node-${major}"
    mkdir -p "/usr/local/node-${major}"
    tar -xJf "/tmp/${tarball}" -C "/usr/local/node-${major}" --strip-components=1
    rm -f "/tmp/${tarball}" /tmp/SHASUMS256.txt

    update-alternatives --install /usr/bin/node node "/usr/local/node-${major}/bin/node" "${priority}" \
        --slave /usr/bin/npm npm "/usr/local/node-${major}/bin/npm" \
        --slave /usr/bin/npx npx "/usr/local/node-${major}/bin/npx"
}

install_node "${NODE22_VERSION}" 22
install_node "${NODE24_VERSION}" 24
install_node "${NODE26_VERSION}" 26

node -v
npm -v
