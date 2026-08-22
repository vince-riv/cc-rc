#!/usr/bin/env bash
set -euo pipefail

# cc-rc-pr-update: create or update the current task's PR, keeping its body
# in a consistent Summary / Plan / Progress-ledger format so a fresh agent
# can resume the task from the PR alone if the session that opened it is
# lost. Agent-facing: unlike cc-rc-finish-login (a shell function sourced
# via $PROMPT_COMMAND, for an attended interactive shell), this is a real
# executable on PATH so it works from non-interactive tool calls too.
#
# Usage:
#   cc-rc-pr-update --title TITLE --summary-file F --plan-file F \
#     --ledger-file F [--ready]
#   cc-rc-pr-update --ready
#
# --title/--summary-file/--plan-file/--ledger-file must all be given
# together (there's no partial-section patching - the whole body is always
# regenerated from all three, so they can't drift out of the template).
# Each *-file value may be "-" to read that section from stdin.
#
# --ready marks the branch's existing PR ready for review. It can be
# combined with the flags above (edits the body, then marks ready) or used
# alone (just marks ready, no body change) - but the PR must already exist
# either way; --ready never creates one.
#
# On the first call for a branch (no PR open yet), this creates a Draft PR.
# Later calls find that PR and edit it in place.

usage() {
  cat >&2 <<'EOF'
Usage:
  cc-rc-pr-update --title TITLE --summary-file F --plan-file F --ledger-file F [--ready]
  cc-rc-pr-update --ready
EOF
  exit 1
}

title=""
summary_file=""
plan_file=""
ledger_file=""
ready=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) title="${2:?--title needs a value}"; shift 2 ;;
    --summary-file) summary_file="${2:?--summary-file needs a value}"; shift 2 ;;
    --plan-file) plan_file="${2:?--plan-file needs a value}"; shift 2 ;;
    --ledger-file) ledger_file="${2:?--ledger-file needs a value}"; shift 2 ;;
    --ready) ready=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

content_flags_given=0
[[ -n "$title$summary_file$plan_file$ledger_file" ]] && content_flags_given=1

if [[ "$content_flags_given" -eq 1 ]]; then
  if [[ -z "$title" || -z "$summary_file" || -z "$plan_file" || -z "$ledger_file" ]]; then
    echo "--title, --summary-file, --plan-file, and --ledger-file must all be given together." >&2
    usage
  fi
elif [[ "$ready" -ne 1 ]]; then
  usage
fi

read_section() {
  local f="$1"
  if [[ "$f" == "-" ]]; then
    cat
  else
    cat "$f"
  fi
}

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" == "HEAD" ]]; then
  echo "Detached HEAD - checkout a branch before running cc-rc-pr-update." >&2
  exit 1
fi

pr_number="$(gh pr view "$branch" --json number -q .number 2>/dev/null || true)"

if [[ "$content_flags_given" -eq 1 ]]; then
  summary="$(read_section "$summary_file")"
  plan="$(read_section "$plan_file")"
  ledger="$(read_section "$ledger_file")"
  [[ -n "$ledger" ]] || ledger="_Not started yet._"

  body="$(cat <<BODYEOF
${summary}

<details>
<summary>Plan</summary>

${plan}

</details>

<details>
<summary>Progress ledger (for a resuming agent)</summary>

${ledger}

</details>
BODYEOF
)"

  if [[ -z "$pr_number" ]]; then
    gh pr create --draft --title "$title" --body "$body" --head "$branch"
    pr_number="$(gh pr view "$branch" --json number -q .number)"
    echo "Created draft PR #$pr_number"
  else
    gh pr edit "$pr_number" --title "$title" --body "$body"
    echo "Updated PR #$pr_number"
  fi
fi

if [[ "$ready" -eq 1 ]]; then
  if [[ -z "$pr_number" ]]; then
    echo "No PR found for branch '$branch' - open one first (omit --ready)." >&2
    exit 1
  fi
  gh pr ready "$pr_number"
  echo "Marked PR #$pr_number ready for review"
fi
