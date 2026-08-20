#!/usr/bin/env bash
set -euo pipefail

# Claude Code: native installer, lands in ~/.local/bin. Auto-updates stay on.
curl -fsSL https://claude.ai/install.sh | bash

# helm unittest plugin. --verify=false: no published provenance.
# https://github.com/helm-unittest/helm-unittest/issues/777
helm plugin install https://github.com/helm-unittest/helm-unittest --verify=false

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
      "Edit(/workspace/repo/**)",
      "Edit(/workspace/worktrees/**)"
    ]
  },
  "outputStyle": "STE100 + ADHD"
}
EOF
