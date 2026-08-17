# syntax=docker/dockerfile:1
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Ubuntu's default apt config deletes downloaded .debs after every install
# (docker-clean), which would defeat the cache mount below. Disable that and
# tell apt to keep what it downloads.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Recommends only — Suggests dropped, it was pulling in far more than needed.
RUN printf 'APT::Install-Recommends "true";\n' > /etc/apt/apt.conf.d/99-recommends

# /var/cache/apt and /var/lib/apt/lists are BuildKit cache mounts: reused
# across builds to speed things up, but never written into an image layer.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get upgrade -y && apt-get install -y \
        build-essential \
        golang-1.25 \
        golang-1.26 \
        openssh-client \
        python3 \
        python3-venv \
        python3-pip \
        curl \
        git \
        ca-certificates \
        zip \
        unzip \
        locales \
        tzdata

RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

ENV TZ=America/New_York
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone

# golang-1.25 / golang-1.26 land under /usr/lib/go-<ver>/, not on PATH.
# Register both with update-alternatives; 1.26 wins by default.
# Switch with `update-alternatives --config go`.
RUN update-alternatives --install /usr/bin/go go /usr/lib/go-1.25/bin/go 125 \
        --slave /usr/bin/gofmt gofmt /usr/lib/go-1.25/bin/gofmt \
 && update-alternatives --install /usr/bin/go go /usr/lib/go-1.26/bin/go 126 \
        --slave /usr/bin/gofmt gofmt /usr/lib/go-1.26/bin/gofmt

# Go lint/debug tools, built once with the toolchain above. Dropped into
# /usr/local/bin (global) rather than a user's $GOPATH/bin — same reasoning
# as `go` itself being global via update-alternatives: root runs later build
# steps, `dev` runs at container runtime, both should see the same tools.
#
# One build, not one per Go version: both tools shell out to whichever `go`
# is on PATH at run time rather than baking in the version they were built
# with (golangci-lint drives `go list`/`go build` under the hood; dlv reads
# DWARF from whatever binary you point it at). Which Go compiled the tool
# itself doesn't matter here, so there's nothing to gain from building
# separate copies against 1.25 and 1.26.
RUN GOBIN=/usr/local/bin go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest \
 && GOBIN=/usr/local/bin go install github.com/go-delve/delve/cmd/dlv@latest \
 && GOBIN=/usr/local/bin go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest \
 && rm -rf /root/go /root/.cache/go-build

# Helm: official install script, which downloads the release tarball and
# verifies it against the published checksum itself. Pinned to the latest
# v4 tag so we don't pull a v3 release.
RUN set -eu; \
    version="$(curl -fsSL https://api.github.com/repos/helm/helm/releases \
        | grep -oP '"tag_name":\s*"\Kv4[^"]+' | head -1)"; \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        | DESIRED_VERSION="${version}" bash

# GitHub CLI: fetch the latest release binary straight from GitHub instead
# of Ubuntu's apt package, which trails upstream by a wide margin.
RUN set -eu; \
    arch="$(dpkg --print-architecture)"; \
    version="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
        | grep -oP '"tag_name":\s*"v\K[^"]+')"; \
    tarball="gh_${version}_linux_${arch}.tar.gz"; \
    curl -fsSL -o "/tmp/${tarball}" \
        "https://github.com/cli/cli/releases/download/v${version}/${tarball}"; \
    curl -fsSL -o /tmp/gh_checksums.txt \
        "https://github.com/cli/cli/releases/download/v${version}/gh_${version}_checksums.txt"; \
    (cd /tmp && grep " ${tarball}\$" gh_checksums.txt | sha256sum -c -); \
    tar -xzf "/tmp/${tarball}" -C /tmp; \
    install -m 0755 "/tmp/gh_${version}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh*

# Non-root dev user. No sudo: this image runs a headless agent as `dev`,
# not an interactive human, so it gets no built-in path to root. If a task
# needs a system package, add it above and rebuild — don't hand an
# unattended agent open-ended privilege escalation.
RUN useradd -m -s /bin/bash dev \
 && mkdir -p /workspace \
 && chown dev:dev /workspace

USER dev
WORKDIR /home/dev

# Claude Code: native installer, per-user — installs to ~/.local/bin.
# Auto-updates left on (default `latest` channel): some of these containers
# run long enough that picking up fixes without a rebuild is preferred over
# pinning to a fixed version.
RUN curl -fsSL https://claude.ai/install.sh | bash

ENV PATH="/home/dev/.local/bin:${PATH}"

# helm unittest plugin. Installed as `dev`, not root, so it lands under
# ~dev/.local/share/helm/plugins where the `dev`-run helm will find it.
RUN helm plugin install https://github.com/helm-unittest/helm-unittest

WORKDIR /workspace
CMD ["/bin/bash"]
