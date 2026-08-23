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
  "theme": "auto"
}
EOF

# nvm, plus node 22/24/26 — 26 is nvm's default.
# renovate: datasource=github-releases depName=nvm-sh/nvm
NVM_VERSION=v0.40.7
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
\. "$HOME/.nvm/nvm.sh"
nvm --version
nvm install 22
nvm install 24
nvm install 26
nvm alias default 26
node -v
npm -v
