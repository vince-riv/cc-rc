set -euo pipefail
: "${NAMESPACE:?}" "${SECRET_NAME:?}" "${KEY_TITLE:?}" "${GH_TOKEN:?}"

if kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists in $NAMESPACE - nothing to do."
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
KEY_PATH="$WORKDIR/id_ed25519"

ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "$KEY_TITLE" -q
echo "Generated a new ED25519 key pair."

# gh picks up GH_TOKEN from the environment automatically.
KEY_ID="$(gh api /user/keys -f "title=${KEY_TITLE}" -f "key=$(cat "${KEY_PATH}.pub")" --jq .id)"
echo "Added SSH key to the GitHub account (key id: $KEY_ID)."

# Idempotent by construction: the public key only stays on the GitHub account
# if the Secret write below actually succeeds. If it doesn't, the key is
# deleted again so a retry (this Job re-running) starts from a clean slate
# instead of accumulating orphaned keys on the account.
if ! kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    --from-file=id_ed25519="$KEY_PATH" \
    --from-file=id_ed25519.pub="${KEY_PATH}.pub"; then
  echo "Secret creation failed - rolling back: deleting GitHub SSH key id $KEY_ID" >&2
  gh api -X DELETE "/user/keys/${KEY_ID}" \
    || echo "WARNING: failed to delete GitHub SSH key id $KEY_ID - remove it manually." >&2
  exit 1
fi

echo "Created secret $SECRET_NAME in $NAMESPACE."
