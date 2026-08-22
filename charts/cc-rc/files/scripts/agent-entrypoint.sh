set -uo pipefail
MARKER_DIR="/home/dev/.cc-rc"
MARKER="$MARKER_DIR/login-complete"
mkdir -p "$MARKER_DIR"

LOGIN_LOG="/tmp/cc-rc-claude-login.log"
RC_LOG="/tmp/cc-rc-remote-control.log"
RC_WORKTREE_MAX_AGE_DAYS="${RC_WORKTREE_MAX_AGE_DAYS:-10}"
RC_SHUTDOWN_WAIT="${RC_SHUTDOWN_WAIT:-55}"

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

# Removes worktrees under .claude/worktrees/ whose most recent transcript
# activity (~/.claude/projects/<encoded-worktree-path>/*.jsonl mtime) is
# older than RC_WORKTREE_MAX_AGE_DAYS. Runs once per boot, before
# starting remote-control, since PVCs are ReadWriteOnce and already
# mounted here - a separate cleanup CronJob couldn't attach to them
# while this pod is up.
prune_stale_worktrees() {
  cd /workspace/repo 2>/dev/null || return 0
  [ -d .claude/worktrees ] || return 0
  now=$(date +%s)
  max_age_seconds=$(( RC_WORKTREE_MAX_AGE_DAYS * 86400 ))
  for wt in .claude/worktrees/*/; do
    [ -d "$wt" ] || continue
    name=$(basename "$wt")
    # claude encodes a worktree's absolute path into its
    # ~/.claude/projects/ dirname by replacing "/" and "." with "-".
    encoded=$(printf '%s' "/workspace/repo/.claude/worktrees/${name}" | sed 's/[\/.]/-/g')
    project_dir="/home/dev/.claude/projects/${encoded}"
    newest=0
    if [ -d "$project_dir" ]; then
      newest=$(find "$project_dir" -name '*.jsonl' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
      newest=${newest%.*}
      newest=${newest:-0}
    fi
    if [ "$newest" -gt 0 ]; then
      age=$(( now - newest ))
      if [ "$age" -ge "$max_age_seconds" ]; then
        echo "Pruning stale worktree $wt (last transcript activity $(( age / 86400 )) days ago)."
        git worktree remove --force "$wt" 2>&1 || echo "Failed to remove worktree $wt"
      fi
    else
      echo "Skipping prune check for $wt - no transcript found to determine activity."
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

# Timestamp suffix keeps each boot's session name visibly distinct in
# claude.ai/code, whether --continue reattaches an existing session or a
# fresh one gets created below.
NAME="${RC_NAME:-$(hostname)}-$(date +%Y%m%d-%H%M%S)"
echo "Login already complete - starting claude remote-control (name=$NAME)."
echo "Session output tailed below (and kept at $RC_LOG). To debug interactively:"
echo "  kubectl exec -it \$(hostname) -- screen -r remote-control"

prune_stale_worktrees

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
