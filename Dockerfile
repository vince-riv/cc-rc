# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
FROM ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

ENV DEBIAN_FRONTEND=noninteractive

# Keep downloaded .debs around for the apt cache mount below (Ubuntu's
# default docker-clean hook deletes them after every install).
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Recommends only — Suggests dropped, it was pulling in far more than needed.
RUN printf 'APT::Install-Recommends "true";\n' > /etc/apt/apt.conf.d/99-recommends

# BuildKit cache mounts: reused across builds, never written to an image layer.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get upgrade -y && apt-get install -y \
        build-essential \
        golang-1.25 \
        golang-1.26 \
        openssh-client \
        connect-proxy \
        python3 \
        python3-venv \
        python3-pip \
        curl \
        git \
        ca-certificates \
        zip \
        unzip \
        locales \
        tzdata \
        yamllint \
        screen \
        tmux \
        rsync \
        file \
        jq \
        tree \
        gnupg \
        kubectx \
        libssl-dev \
        libffi-dev \
        libyaml-dev \
        libreadline-dev \
        zlib1g-dev \
        autoconf \
        automake \
        bison \
        flex \
        pkg-config \
        cmake

RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

ENV TZ=America/New_York
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
 && echo $TZ > /etc/timezone

# Scripts below are bind-mounted, not COPY'd, so pinned versions never land
# in an image layer. Each gets its own tmpfs /tmp, discarded after the RUN,
# so none of them need to clean up what they download.

# go 1.25/1.26 via update-alternatives, plus golangci-lint and dlv.
RUN --mount=type=bind,source=scripts/setup-go.sh,target=/opt/build-scripts/setup-go.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /opt/build-scripts/setup-go.sh

# crane, gcrane, krane, ... — everything go-containerregistry's release ships.
RUN --mount=type=bind,source=scripts/setup-go-containerregistry.sh,target=/opt/build-scripts/setup-go-containerregistry.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /opt/build-scripts/setup-go-containerregistry.sh

# Helm, plus helm-docs.
RUN --mount=type=bind,source=scripts/setup-helm.sh,target=/opt/build-scripts/setup-helm.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /opt/build-scripts/setup-helm.sh

# kubectl, latest stable release (not in Ubuntu's apt repos at all).
RUN --mount=type=bind,source=scripts/setup-kubectl.sh,target=/opt/build-scripts/setup-kubectl.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /opt/build-scripts/setup-kubectl.sh

# argocd CLI, latest release (also not in Ubuntu's apt repos).
RUN --mount=type=bind,source=scripts/setup-argocd.sh,target=/opt/build-scripts/setup-argocd.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /opt/build-scripts/setup-argocd.sh

# GitHub CLI, latest release straight from GitHub (Ubuntu's apt package trails).
RUN --mount=type=bind,source=scripts/setup-gh.sh,target=/opt/build-scripts/setup-gh.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /opt/build-scripts/setup-gh.sh

# Shared PATH config for ~/.local/bin (see scripts/setup-path.sh).
RUN --mount=type=bind,source=scripts/setup-path.sh,target=/opt/build-scripts/setup-path.sh \
    bash /opt/build-scripts/setup-path.sh

# Non-root dev user, no sudo: this runs a headless agent, not an
# interactive human, so it gets no built-in path to root.
RUN useradd -m -s /bin/bash dev \
 && mkdir -p /workspace \
 && chown dev:dev /workspace

USER dev
WORKDIR /home/dev

# Claude Code (auto-updates on), the helm unittest plugin, and ~/.claude
# config, all installed as `dev` so they land under `dev`'s home, not root's.
RUN --mount=type=bind,source=scripts/setup-dev.sh,target=/opt/build-scripts/setup-dev.sh \
    --mount=type=bind,source=.claude/output-styles/ste100-adhd.md,target=/opt/build-scripts/ste100-adhd.md \
    --mount=type=bind,source=charts/cc-rc/files/scripts/rescue-sessions.sh,target=/opt/build-scripts/rescue-sessions.sh \
    --mount=type=bind,source=.claude/CLAUDE.md,target=/opt/build-scripts/CLAUDE.md \
    --mount=type=bind,source=scripts/cc-rc-pr-update.sh,target=/opt/build-scripts/cc-rc-pr-update.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /opt/build-scripts/setup-dev.sh

WORKDIR /workspace
CMD ["/bin/bash"]
