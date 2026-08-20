#!/usr/bin/env bash
set -euo pipefail

# Claude Code: native installer, lands in ~/.local/bin. Auto-updates stay on.
curl -fsSL https://claude.ai/install.sh | bash

# helm unittest plugin. --verify=false: no published provenance.
# https://github.com/helm-unittest/helm-unittest/issues/777
helm plugin install https://github.com/helm-unittest/helm-unittest --verify=false
