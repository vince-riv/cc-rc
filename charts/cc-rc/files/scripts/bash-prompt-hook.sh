# Sourced via $PROMPT_COMMAND in every interactive bash shell in the agent
# container - the claude-login screen session, and any ad-hoc
# `kubectl exec -it <pod> -- bash`. While login hasn't completed yet,
# prints instructions once per shell session and defines a helper to
# signal completion explicitly. Completion is deliberately never
# auto-detected from a running `claude remote-control` process here -
# its first real run can take a few minutes to configure, and treating
# its mere appearance as "done" risks moving on before that finishes.

cc-rc-finish-login() {
  touch /home/dev/.cc-rc/login-complete
  echo "Marked login complete - the agent will detect this and restart into steady-state mode within a few seconds."
}

if [ -z "${CC_RC_INSTRUCTIONS_SHOWN:-}" ] && [ ! -f /home/dev/.cc-rc/login-complete ]; then
  export CC_RC_INSTRUCTIONS_SHOWN=1
  cat <<'EOF'

=== cc-rc: claude is not logged in yet ===
Run: claude
Then inside claude, run: /login
Once you're logged in - and, if you want to verify it, once
claude remote-control is configured and working the way you want -
run: cc-rc-finish-login
That's the only way this step completes; nothing here is
auto-detected. Once you do, this pod restarts on its own within a
few seconds - no need to exit or kill anything yourself.
===========================================

EOF
fi
