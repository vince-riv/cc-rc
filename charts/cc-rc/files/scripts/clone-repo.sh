set -euo pipefail
DEST="/workspace/repo"
if [ -d "$DEST/.git" ]; then
  echo "Already cloned at $DEST, skipping."
else
  git clone "git@github.com:${REPO_ORG}/${REPO_NAME}.git" "$DEST"
fi
