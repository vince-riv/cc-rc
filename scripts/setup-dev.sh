#!/usr/bin/env bash
set -euo pipefail

# Claude Code: native installer, lands in ~/.local/bin. Auto-updates are off
# (DISABLE_AUTOUPDATER=1, set in the Dockerfile) - this image is rebuilt
# regularly, so the version installed here is what runs.
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    https://claude.ai/install.sh | bash
"$HOME/.local/bin/claude" --version

# Manual session-recovery tool (see charts/cc-rc/files/scripts/rescue-sessions.sh
# for what it does and why it's baked into the image instead of chart-delivered).
install -m 755 /opt/build-scripts/rescue-sessions.sh "$HOME/.local/bin/rescue-sessions.sh"

# helm unittest plugin. --verify=false: no published provenance.
# https://github.com/helm-unittest/helm-unittest/issues/777
helm plugin install https://github.com/helm-unittest/helm-unittest --verify=false
helm plugin list

# Claude Code config: output style, telemetry off, workspace permissions,
# and the git/PR workflow instructions every coding-task agent follows.
# attribution.sessionUrl is off: agents here run as Remote Control sessions,
# and the claude.ai session link they'd otherwise add to every commit trailer
# and PR body is not resolvable by anyone reviewing the repo.
mkdir -p ~/.claude/output-styles
cp /opt/build-scripts/ste100-adhd.md ~/.claude/output-styles/ste100-adhd.md
cp /opt/build-scripts/CLAUDE.md ~/.claude/CLAUDE.md

# cc-rc-pr-update: agent-facing helper that creates/updates a task's PR
# (see ~/.claude/CLAUDE.md). ~/.local/bin is already on PATH for every
# shell (see scripts/setup-path.sh).
install -m 0755 /opt/build-scripts/cc-rc-pr-update.sh ~/.local/bin/cc-rc-pr-update

cat > ~/.claude/settings.json <<'EOF'
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "0"
  },
  "permissions": {
    "allow": [
      "Read(/workspace/**)",
      "Edit(/workspace/repo/**)"
    ]
  },
  "outputStyle": "STE100 + ADHD",
  "theme": "auto",
  "attribution": {
    "sessionUrl": false
  }
}
EOF

# nvm itself, for anything that expects `nvm use`/.nvmrc to work. The
# actual node 22/24/26 binaries are NOT downloaded here — they're already
# installed system-wide under /usr/local/node-<major>/ (setup-node.sh, run
# as root earlier in the Dockerfile). Symlinking them into nvm's version
# directory "registers" them with nvm without a second download/extract,
# which is what used to make ~/.nvm hundreds of MB bigger than it needed
# to be.
# renovate: datasource=github-releases depName=nvm-sh/nvm
NVM_VERSION=v0.40.7
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
\. "$HOME/.nvm/nvm.sh"
nvm --version

mkdir -p "$NVM_DIR/versions/node"
default_version=""
for major in 22 24 26; do
    full_version="$("/usr/local/node-${major}/bin/node" --version)"
    version_dir="$NVM_DIR/versions/node/${full_version}"
    # A symlinked version_dir itself doesn't work here: nvm's own version
    # scan looks for real directories and skips symlinks, so it would
    # report the version as "not installed" despite the binary working
    # fine. Make the directory real, symlink its contents instead — same
    # near-zero extra space, but nvm's scan sees it.
    mkdir -p "${version_dir}"
    ln -sfn "/usr/local/node-${major}"/* "${version_dir}/"
    [ "${major}" = "26" ] && default_version="${full_version}"
done
nvm alias default "${default_version}"
nvm use default
node -v
npm -v

# Build-time smoke test: nvm must actually recognize each registered
# version, not just have a directory with a working binary sitting in it -
# `nvm ls` alone wouldn't have caught the symlinked-directory bug above,
# since that only lists what nvm sees. Running node THROUGH nvm for each
# version is what proves `nvm use`/`nvm exec` work, so check it every
# build instead of only after it breaks.
nvm ls
for major in 22 24 26; do
    echo "== node ${major} via nvm =="
    nvm exec "${major}" node --version
done
