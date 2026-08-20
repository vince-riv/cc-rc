set -uo pipefail
MARKER_DIR="/home/dev/.cc-rc"
MARKER="$MARKER_DIR/login-complete"
mkdir -p "$MARKER_DIR"

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
  echo "Then run /login, and once logged in, run: claude remote-control"
  screen -dmS claude-login bash -lic 'claude --no-chrome'

  echo "Waiting for 'claude remote-control' to be started inside that session..."
  while ! is_remote_control_running; do
    sleep 5
  done

  echo "Detected claude remote-control running - marking login complete."
  touch "$MARKER"
  echo "Exiting so the pod restarts into steady-state mode."
  exit 0
fi

NAME="${RC_NAME:-$(hostname)}"
echo "Login already complete - starting claude remote-control (name=$NAME)."
screen -dmS remote-control bash -lic "claude remote-control --name ${NAME} --permission-mode ${RC_PERMISSION_MODE} --spawn ${RC_SPAWN} --capacity ${RC_CAPACITY}"

down_since=0
while true; do
  if is_remote_control_running; then
    down_since=0
  else
    now=$(date +%s)
    if [ "$down_since" -eq 0 ]; then
      down_since=$now
    fi
    elapsed=$(( now - down_since ))
    if [ "$elapsed" -ge 45 ]; then
      echo "claude remote-control has not been running for 45s - exiting."
      exit 1
    fi
  fi
  sleep 5
done
