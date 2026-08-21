set -uo pipefail
MARKER_DIR="/home/dev/.cc-rc"
MARKER="$MARKER_DIR/login-complete"
mkdir -p "$MARKER_DIR"

LOGIN_LOG="/tmp/cc-rc-claude-login.log"
RC_LOG="/tmp/cc-rc-remote-control.log"

# pgrep -f matches full command lines, including this very
# script's own (it echoes "claude remote-control" in its
# instructions below) - exclude our own PID or this always
# "detects" a false positive against ourselves.
is_remote_control_running() {
  pgrep -f "claude remote-control" | grep -qv "^$$\$"
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

NAME="${RC_NAME:-$(hostname)}"
echo "Login already complete - starting claude remote-control (name=$NAME)."
echo "Session output tailed below (and kept at $RC_LOG). To debug interactively:"
echo "  kubectl exec -it \$(hostname) -- screen -r remote-control"
: > "$RC_LOG"
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
  sleep 5
done
