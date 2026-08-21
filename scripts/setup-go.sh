#!/usr/bin/env bash
set -euo pipefail

# golang-1.25 / golang-1.26 land under /usr/lib/go-<ver>/, not on PATH.
# Register both with update-alternatives; 1.26 wins by default.
update-alternatives --install /usr/bin/go go /usr/lib/go-1.25/bin/go 125 \
        --slave /usr/bin/gofmt gofmt /usr/lib/go-1.25/bin/gofmt
update-alternatives --install /usr/bin/go go /usr/lib/go-1.26/bin/go 126 \
        --slave /usr/bin/gofmt gofmt /usr/lib/go-1.26/bin/gofmt

# Go lint/debug tools, dropped into /usr/local/bin (global), pinned so builds
# are reproducible.
# renovate: datasource=github-releases depName=golangci/golangci-lint
GOLANGCI_LINT_VERSION=v2.13.0
# renovate: datasource=github-releases depName=go-delve/delve
DELVE_VERSION=v1.27.1

GOBIN=/usr/local/bin go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}
GOBIN=/usr/local/bin go install github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION}
rm -rf /root/go /root/.cache/go-build

go version
golangci-lint version
dlv version
