#!/usr/bin/env bash
set -euo pipefail

# Claude Code: native installer, lands in ~/.local/bin. Auto-updates stay on.
curl -fsSL https://claude.ai/install.sh | bash
"$HOME/.local/bin/claude" --version

# helm unittest plugin. --verify=false: no published provenance.
# https://github.com/helm-unittest/helm-unittest/issues/777
helm plugin install https://github.com/helm-unittest/helm-unittest --verify=false
helm plugin list

# Claude Code config: output style, telemetry off, and workspace permissions.
mkdir -p ~/.claude/output-styles
cp /opt/build-scripts/ste100-adhd.md ~/.claude/output-styles/ste100-adhd.md

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
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
\. "$HOME/.nvm/nvm.sh"
nvm --version
nvm install 22
nvm install 24
nvm install 26
nvm alias default 26
node -v
npm -v
