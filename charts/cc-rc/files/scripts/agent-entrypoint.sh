set -uo pipefail
MARKER_DIR="/home/dev/.cc-rc"
MARKER="$MARKER_DIR/login-complete"
mkdir -p "$MARKER_DIR"

LOGIN_LOG="/tmp/cc-rc-claude-login.log"
RC_LOG="/tmp/cc-rc-remote-control.log"
WARMUP_LOG="/tmp/cc-rc-warmup.log"
RC_WORKTREE_MAX_AGE_DAYS="${RC_WORKTREE_MAX_AGE_DAYS:-10}"
RC_SHUTDOWN_WAIT="${RC_SHUTDOWN_WAIT:-55}"
RC_WARMUP_TIMEOUT="${RC_WARMUP_TIMEOUT:-120}"

# pgrep -f matches full command lines, including this very
# script's own (it echoes "claude remote-control" in its
# instructions below) - exclude our own PID or this always
# "detects" a false positive against ourselves.
is_remote_control_running() {
  pgrep -f "claude remote-control" | grep -qv "^$$\$"
}

# On SIGTERM (pod termination), give any claude remote-control process
# (the steady-state one below, or a manually started rescue-sessions.sh
# one) a chance to exit cleanly via SIGINT before kubelet's own
# terminationGracePeriodSeconds runs out and sends SIGKILL - a hard kill
# gives claude no chance to release its worktree locks.
graceful_shutdown() {
  echo "Received termination signal - sending SIGINT to claude remote-control process(es)..."
  pids=$(pgrep -f "claude remote-control" | grep -v "^$$\$" || true)
  for pid in $pids; do
    kill -INT "$pid" 2>/dev/null || true
  done
  waited=0
  while [ -n "$(pgrep -f "claude remote-control" | grep -v "^$$\$" || true)" ] && [ "$waited" -lt "$RC_SHUTDOWN_WAIT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  echo "Exiting after ${waited}s of shutdown wait."
  exit 0
}
trap graceful_shutdown TERM

# Removes worktrees under .claude/worktrees/ that are either untracked
# by any ~/.claude/sessions/ record, or tracked but stale
# (RC_WORKTREE_MAX_AGE_DAYS+ since the session's last recorded activity).
# Runs once per boot, before starting remote-control, since PVCs are
# ReadWriteOnce and already mounted here - a separate cleanup CronJob
# couldn't attach to them while this pod is up.
#
# --force --force (not just --force): a worktree still in active use by
# claude remote-control may be *locked* (git worktree lock), not just
# dirty - single --force only overrides an unclean worktree, not a lock.
#
# Fails pod startup (exit 1) rather than silently mis-pruning if
# ~/.claude/sessions/*.json or ccr-tip.json don't match the shape this
# script depends on - claude may have changed its format, and guessing
# wrong here risks deleting an in-use worktree.
prune_stale_worktrees() {
  cd /workspace/repo 2>/dev/null || return 0
  shopt -s nullglob
  worktrees=(.claude/worktrees/*/)
  shopt -u nullglob
  [ ${#worktrees[@]} -gt 0 ] || return 0

  declare -A session_file_for_cwd=()
  for f in /home/dev/.claude/sessions/*.json; do
    [ -f "$f" ] || continue
    if ! jq -e 'has("pid") and has("cwd") and has("sessionId")' "$f" >/dev/null 2>&1; then
      echo "FATAL: $f does not match the expected session JSON shape" \
           "(pid/cwd/sessionId) - claude may have changed its format." \
           "Refusing to prune worktrees blind until this script is updated." >&2
      exit 1
    fi
    session_file_for_cwd["$(jq -r '.cwd' "$f")"]="$f"
  done

  now=$(date +%s)
  max_age_seconds=$(( RC_WORKTREE_MAX_AGE_DAYS * 86400 ))

  for wt in "${worktrees[@]}"; do
    [ -d "$wt" ] || continue
    abs_path="/workspace/repo/${wt%/}"
    session_file="${session_file_for_cwd[$abs_path]:-}"

    if [ -z "$session_file" ]; then
      echo "Pruning worktree $wt - no matching entry in ~/.claude/sessions/."
      git worktree remove --force --force "$wt" 2>&1 || echo "Failed to remove worktree $wt"
      continue
    fi

    session_id=$(jq -r '.sessionId' "$session_file")
    # claude encodes a worktree's absolute path into its
    # ~/.claude/projects/ dirname by replacing "/" and "." with "-".
    encoded=$(printf '%s' "$abs_path" | sed 's/[\/.]/-/g')
    tip_file="/home/dev/.claude/projects/${encoded}/${session_id}/ccr-tip.json"

    if [ ! -f "$tip_file" ]; then
      echo "Skipping prune check for $wt - session recorded ($session_file) but no ccr-tip.json to determine activity."
      continue
    fi
    if ! jq -e 'has("updatedAt")' "$tip_file" >/dev/null 2>&1; then
      echo "FATAL: $tip_file does not match the expected ccr-tip JSON shape" \
           "(updatedAt) - claude may have changed its format." \
           "Refusing to prune worktrees blind until this script is updated." >&2
      exit 1
    fi

    updated_epoch=$(date -d "$(jq -r '.updatedAt' "$tip_file")" +%s 2>/dev/null || echo 0)
    if [ "$updated_epoch" -eq 0 ]; then
      echo "Skipping prune check for $wt - couldn't parse updatedAt from $tip_file."
      continue
    fi

    age=$(( now - updated_epoch ))
    if [ "$age" -ge "$max_age_seconds" ]; then
      echo "Pruning worktree $wt (last activity $(( age / 86400 )) days ago) and its session record."
      git worktree remove --force --force "$wt" 2>&1 || echo "Failed to remove worktree $wt"
      pid=$(jq -r '.pid' "$session_file")
      rm -f "$session_file" "/home/dev/.claude/sessions/${pid}."*.key
      rm -rf "/home/dev/.claude/session-env/${session_id}"
    fi
  done
  git worktree prune 2>&1 || true
}

if [ ! -f "$MARKER" ]; then
  echo "No login marker at $MARKER - starting first-time claude login setup."
  echo "Attach with: kubectl exec -it \$(hostname) -- screen -r claude-login"
  echo "That drops you into an interactive shell with instructions printed"
  echo "(the same instructions show up in any 'kubectl exec -it ... -- bash' too)."
  echo "Session output is also tailed below (and kept at $LOGIN_LOG)."
  : > "$LOGIN_LOG"
  screen -L -Logfile "$LOGIN_LOG" -dmS claude-login bash -lic 'cd /workspace/repo && exec bash -li'
  tail -F "$LOGIN_LOG" &
  login_tail_pid=$!

  echo "Waiting up to ${RC_FIRST_BOOT_TIMEOUT}s for cc-rc-finish-login to be run" \
       "(not auto-detected - claude remote-control's first real run can take" \
       "a few minutes to configure, so its mere appearance isn't treated as done)."
  start_time=$(date +%s)
  while [ ! -f "$MARKER" ]; do
    now=$(date +%s)
    if [ $(( now - start_time )) -ge "$RC_FIRST_BOOT_TIMEOUT" ]; then
      echo "No login completed within ${RC_FIRST_BOOT_TIMEOUT}s - exiting so the pod restarts and retries."
      exit 1
    fi
    sleep 5
  done
  kill "$login_tail_pid" 2>/dev/null || true

  echo "Login marker present - exiting so the pod restarts into steady-state mode."
  exit 0
fi

# Timestamp suffix keeps each boot's session visibly distinct in
# claude.ai/code from any prior boot's.
NAME="${RC_NAME:-$(hostname)}-$(date +%Y%m%d-%H%M%S)"
echo "Login already complete - starting claude remote-control (name=$NAME)."
echo "Session output tailed below (and kept at $RC_LOG). To debug interactively:"
echo "  kubectl exec -it \$(hostname) -- screen -r remote-control"

prune_stale_worktrees

# remote-control doesn't refresh stale authentication on startup, but an
# ordinary `claude` run does - so after a roll it comes up unauthenticated
# until someone runs `claude` by hand. What the run actually refreshes is
# unknown: ~/.claude/.credentials.json is untouched across it, so the state
# lives elsewhere. One run at boot is enough (confirmed), hence no timer.
# bash -lic: ~/.local/bin only reaches PATH via /etc/profile.d and
# /etc/bash.bashrc (scripts/setup-path.sh); cd avoids a trust prompt.
# Bounded and non-fatal: no livenessProbe would rescue a hung warm-up, and
# remote-control is still worth starting if this fails.
: > "$WARMUP_LOG"
if timeout "$RC_WARMUP_TIMEOUT" bash -lic 'cd /workspace/repo && claude -p "ok" --max-turns 1' > "$WARMUP_LOG" 2>&1; then
  echo "Auth warm-up run completed (output at $WARMUP_LOG)."
else
  echo "Auth warm-up run failed or timed out after ${RC_WARMUP_TIMEOUT}s -" \
       "starting remote-control anyway; it may fail to authenticate. Output:"
  cat "$WARMUP_LOG"
fi

: > "$RC_LOG"
# --continue was tried here and dropped: claude remote-control rejects
# --continue combined with --spawn/--capacity ("cannot be used with
# --spawn, --capacity, or --create-session-in-dir"), and confirmed by
# hand that it doesn't reattach worktree sessions the way we need anyway.
# Recovery for an already-orphaned worktree session is rescue-sessions.sh
# instead (see charts/cc-rc/files/scripts/rescue-sessions.sh).
screen -L -Logfile "$RC_LOG" -dmS remote-control bash -lic "cd /workspace/repo && claude remote-control --name ${NAME} --permission-mode ${RC_PERMISSION_MODE} --spawn ${RC_SPAWN} --capacity ${RC_CAPACITY}"
tail -F "$RC_LOG" &

down_since=0
while true; do
  if is_remote_control_running; then
    down_since=0
  else
    now=$(date +%s)
    if [ "$down_since" -eq 0 ]; then
      down_since=$now
      echo "claude remote-control is not running - exiting in up to ${RC_UNHEALTHY_TIMEOUT}s" \
           "unless it (re)starts. Debug now: kubectl exec -it \$(hostname) -- bash"
    fi
    elapsed=$(( now - down_since ))
    if [ "$elapsed" -ge "$RC_UNHEALTHY_TIMEOUT" ]; then
      echo "claude remote-control has not been running for ${RC_UNHEALTHY_TIMEOUT}s - exiting."
      exit 1
    fi
  fi
  sleep 5 &
  wait $!
done
