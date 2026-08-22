#!/usr/bin/env bash
# Interactively creates/updates the Kubernetes Secret cc-rc's per-repo agents
# read GH_TOKEN from - one GitHub PAT per org (see charts/cc-rc/values.yaml's
# github.tokens/github.existingSecret docs). Meant to be run by a human on
# their own machine (needs kubectl access to the cluster), not inside a
# container - this is how you manage github.existingSecret's contents
# without ever putting a PAT in values.yaml/git.
#
# For each org given (or entered interactively if none are given as
# arguments), prompts for that org's PAT, pre-filled with its current value
# if the Secret already has one - so rotating one org's PAT, or adding a
# brand new org, never requires re-typing (or even knowing) every other
# org's PAT. Nothing is written to the cluster until the end, applied once
# in a single `kubectl apply --server-side` covering every org already in
# the Secret plus whatever was just entered.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "This script needs bash >= 4 (for 'read -e -i', to pre-fill the token prompt)." >&2
  echo "macOS ships bash 3.2 by default - try: brew install bash, then run this with that bash." >&2
  exit 1
fi

for bin in kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "This script needs '$bin' on PATH." >&2; exit 1; }
done

SECRET_NAME="cc-rc-github-tokens"
NAMESPACE=""
SERVER_SIDE=1
FORCE_CONFLICTS=0

usage() {
  cat <<USAGE
Usage: $0 [-n NAMESPACE] [-s SECRET_NAME] [-c] [-f] [ORG...]

  -n NAMESPACE   Kubernetes namespace (default: current kubectl context's)
  -s SECRET_NAME Secret name (default: ${SECRET_NAME})
  -c             Client-side apply instead of the default --server-side
  -f             Pass --force-conflicts (server-side apply only)
  -h             This help

ORG arguments are optional - with none given, you're prompted for org names
one at a time (blank line to stop).
USAGE
}

while getopts "n:s:cfh" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    s) SECRET_NAME="$OPTARG" ;;
    c) SERVER_SIDE=0 ;;
    f) FORCE_CONFLICTS=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

NS_ARGS=()
[ -n "$NAMESPACE" ] && NS_ARGS=(-n "$NAMESPACE")

# Existing Secret contents (org -> token), if any - missing/absent is fine,
# every org just starts with no pre-filled default in that case.
declare -A CURRENT
EXISTING_JSON="$(mktemp)"
trap 'rm -f "$EXISTING_JSON"' EXIT
if kubectl "${NS_ARGS[@]}" get secret "$SECRET_NAME" -o json >"$EXISTING_JSON" 2>/dev/null; then
  while IFS=$'\t' read -r key value; do
    CURRENT["$key"]="$value"
  done < <(jq -r '.data // {} | to_entries[] | [.key, (.value | @base64d)] | @tsv' "$EXISTING_JSON")
fi

ORGS=("$@")
if [ ${#ORGS[@]} -eq 0 ]; then
  echo "Enter org names one at a time; blank line to stop."
  while true; do
    read -r -p "Org (blank to finish): " org
    [ -z "$org" ] && break
    ORGS+=("$org")
  done
fi

if [ ${#ORGS[@]} -eq 0 ]; then
  echo "No orgs given - nothing to do." >&2
  exit 0
fi

declare -A UPDATED
for org in "${ORGS[@]}"; do
  default="${CURRENT[$org]:-}"
  # -e -i pre-fills the prompt with the current token (if any) as editable
  # text - Enter alone keeps it as-is, or edit/replace it before submitting.
  read -e -i "$default" -r -p "GitHub PAT for org '$org': " token
  if [ -z "$token" ]; then
    echo "Empty token for '$org' - skipping (leaving it unchanged)." >&2
    continue
  fi
  UPDATED["$org"]="$token"
done

if [ ${#UPDATED[@]} -eq 0 ]; then
  echo "Nothing entered - not touching the Secret." >&2
  exit 0
fi

# Merge: everything already in the Secret, overlaid with what was just
# entered - orgs not touched this run keep their existing PAT untouched.
for org in "${!UPDATED[@]}"; do
  CURRENT["$org"]="${UPDATED[$org]}"
done

MANIFEST="$(mktemp)"
trap 'rm -f "$EXISTING_JSON" "$MANIFEST"' EXIT
{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "metadata:"
  echo "  name: $SECRET_NAME"
  [ -n "$NAMESPACE" ] && echo "  namespace: $NAMESPACE"
  echo "type: Opaque"
  echo "stringData:"
  for org in "${!CURRENT[@]}"; do
    printf '  %s: %s\n' "$org" "$(printf '%s' "${CURRENT[$org]}" | jq -Rs .)"
  done
} > "$MANIFEST"

APPLY_ARGS=(apply "${NS_ARGS[@]}" -f "$MANIFEST")
if [ "$SERVER_SIDE" -eq 1 ]; then
  APPLY_ARGS+=(--server-side)
  [ "$FORCE_CONFLICTS" -eq 1 ] && APPLY_ARGS+=(--force-conflicts)
fi

kubectl "${APPLY_ARGS[@]}"
echo "Updated org(s): ${!UPDATED[*]}"
