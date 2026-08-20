#!/usr/bin/env bash
set -euo pipefail

# Puts ~/.local/bin on PATH for every user, via shared config in /etc
# instead of an image-wide ENV PATH.
echo 'export PATH="$HOME/.local/bin:$PATH"' > /etc/profile.d/local-bin-path.sh
chmod 644 /etc/profile.d/local-bin-path.sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /etc/bash.bashrc
