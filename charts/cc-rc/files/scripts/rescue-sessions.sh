#!/usr/bin/env bash
# Manual recovery tool, baked into the Docker image (not chart-delivered -
# works regardless of which chart version a pod is running).
#
# Background: when the agent container restarts, claude remote-control
# always starts fresh with no resume logic (see cc-rc issue #9 - an
# upstream claude-code bug, not fixable in this chart). Any worktree
# sub-session that was still running loses its host process and becomes
# unreachable from claude.ai/code ("session not found").
#
# ~/.claude/sessions/<pid>.json records one file per session host
# process and is never cleaned up when that process dies - so a stale
# entry (pid no longer running) marks an orphaned session. Each one
# carries a bridgeSessionId (e.g. session_01MPCoAVnDNiku2pQtppbc2j) -
# confirmed live that `claude remote-control --session-id
# <bridgeSessionId>`, run from the worktree it was orphaned in,
# re-registers that exact session with claude.ai/code.
#
# Usage:
#   rescue-sessions.sh                       list orphaned sessions
#   rescue-sessions.sh --rescue <bridgeSessionId>
#                                             start a screen session that
#                                             reattaches that session to
#                                             claude.ai/code
set -uo pipefail

SESSIONS_DIR="/home/dev/.claude/sessions"

list_orphaned() {
  found=0
  for f in "$SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r '.pid' "$f")
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    bridge_id=$(jq -r '.bridgeSessionId // empty' "$f")
    [ -n "$bridge_id" ] || continue
    cwd=$(jq -r '.cwd' "$f")
    session_id=$(jq -r '.sessionId' "$f")
    transcript="/home/dev/.claude/projects/$(printf '%s' "$cwd" | sed 's/[\/.]/-/g')/${session_id}.jsonl"
    mtime="unknown"
    if [ -f "$transcript" ]; then
      mtime=$(date -d "@$(stat -c %Y "$transcript")" 2>/dev/null || echo "unknown")
    fi
    found=1
    printf '%-40s %-60s %s\n' "$bridge_id" "$cwd" "$mtime"
  done
  if [ "$found" -eq 0 ]; then
    echo "No orphaned sessions found."
  fi
}

rescue_session() {
  bridge_id="$1"
  cwd=""
  for f in "$SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r '.bridgeSessionId // empty' "$f")" = "$bridge_id" ]; then
      cwd=$(jq -r '.cwd' "$f")
      break
    fi
  done
  if [ -z "$cwd" ]; then
    echo "No session found with bridgeSessionId $bridge_id (see 'rescue-sessions.sh' with no args for the current list)." >&2
    exit 1
  fi
  if [ ! -d "$cwd" ]; then
    echo "Worktree $cwd no longer exists - it may have been pruned (see agent-entrypoint.sh's worktree pruning). Nothing to rescue." >&2
    exit 1
  fi
  screen_name="rescue-${bridge_id}"
  log="/tmp/cc-rc-${screen_name}.log"
  : > "$log"
  screen -L -Logfile "$log" -dmS "$screen_name" \
    bash -lic "cd '${cwd}' && claude remote-control --session-id ${bridge_id} --permission-mode bypassPermissions"
  echo "Started. Attach with:"
  echo "  kubectl exec -it \$(hostname) -- screen -r ${screen_name}"
}

case "${1:-}" in
  --rescue)
    [ -n "${2:-}" ] || { echo "Usage: rescue-sessions.sh --rescue <bridgeSessionId>" >&2; exit 1; }
    rescue_session "$2"
    ;;
  "")
    list_orphaned
    ;;
  *)
    echo "Usage: rescue-sessions.sh [--rescue <bridgeSessionId>]" >&2
    exit 1
    ;;
esac
