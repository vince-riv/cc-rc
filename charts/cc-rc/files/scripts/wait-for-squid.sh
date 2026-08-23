set -euo pipefail
: "${SQUID_HOST:?}" "${SQUID_PORT:?}" "${WAIT_TIMEOUT:?}"

# Guards pod startup ordering against squid not being up yet: clone-repo.sh's
# git clone (tunneled through squid) has no retry of its own, so without
# this a cold install just crashloops until squid catches up.
echo "Waiting up to ${WAIT_TIMEOUT}s for squid at ${SQUID_HOST}:${SQUID_PORT}..."
waited=0
until timeout 2 bash -c "exec 3<>/dev/tcp/${SQUID_HOST}/${SQUID_PORT}" 2>/dev/null; do
  if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
    echo "Gave up after ${waited}s waiting for squid." >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done
echo "squid reachable after ${waited}s."
