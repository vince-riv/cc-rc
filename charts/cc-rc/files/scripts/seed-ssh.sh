set -euo pipefail
: "${SQUID_HOST:?}" "${SQUID_PORT:?}"
SSH_DIR="/mnt/home-pvc/.ssh"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Re-copied from the Secret on every boot (cheap, and keeps the PVC copy in
# sync if the Secret is ever rotated) - unlike known_hosts below, there's no
# reason to preserve a stale key.
install -m 600 /mnt/ssh-key/id_ed25519 "$SSH_DIR/id_ed25519"
install -m 644 /mnt/ssh-key/id_ed25519.pub "$SSH_DIR/id_ed25519.pub"

# Always rewritten (unlike known_hosts below): squid's host/port are
# chart-derived, not user data, so a stale copy should never win. Tunnels
# git+ssh through squid via connect-proxy's `connect` (CONNECT method) -
# squid's own squid.conf allows CONNECT to github.com:22 unconditionally,
# see configmap-squid.yaml.
cat > "$SSH_DIR/config" <<EOF
Host github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    ProxyCommand connect -H ${SQUID_HOST}:${SQUID_PORT} %h %p
EOF
chmod 644 "$SSH_DIR/config"

KNOWN_HOSTS="$SSH_DIR/known_hosts"
if [ ! -f "$KNOWN_HOSTS" ]; then
  echo "No known_hosts at $KNOWN_HOSTS - seeding with GitHub's published host keys."
  cat > "$KNOWN_HOSTS" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
  chmod 644 "$KNOWN_HOSTS"
else
  echo "known_hosts already present at $KNOWN_HOSTS - leaving it alone."
fi
