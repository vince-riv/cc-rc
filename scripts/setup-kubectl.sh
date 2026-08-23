#!/usr/bin/env bash
set -euo pipefail

# kubectl isn't in Ubuntu's apt repos at all, so it's fetched straight from
# the official release, checksum-verified — same pattern as gh/crane.
# renovate: datasource=github-releases depName=kubernetes/kubernetes
KUBECTL_VERSION=v1.36.4
arch="$(dpkg --print-architecture)"

curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/kubectl.sha256 \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl.sha256"
(cd /tmp && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -)

install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
kubectl version --client
