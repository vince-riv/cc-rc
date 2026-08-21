#!/usr/bin/env bash
set -euo pipefail

# argocd isn't in Ubuntu's apt repos at all, so it's fetched straight from
# the GitHub release, checksum-verified.
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARGOCD_VERSION=v3.5.1

case "$(dpkg --print-architecture)" in
    amd64) arch=amd64 ;;
    arm64) arch=arm64 ;;
    *) echo "unsupported architecture" >&2; exit 1 ;;
esac

binary="argocd-linux-${arch}"
curl -fsSL -o "/tmp/${binary}" \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/${binary}"
curl -fsSL -o /tmp/argocd_checksums.txt \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/cli_checksums.txt"
(cd /tmp && grep " ${binary}\$" argocd_checksums.txt | sha256sum -c -)

install -m 0755 "/tmp/${binary}" /usr/local/bin/argocd
argocd version --client
