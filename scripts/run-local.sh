#!/usr/bin/env bash
# Runs one cc-rc agent locally under docker or podman, in the same shape as the
# per-repo StatefulSet the chart deploys: same image, the same orchestration
# scripts (charts/cc-rc/files/scripts, bind-mounted where the chart
# ConfigMap-mounts them), the same /home/dev + /workspace split, and the same
# `claude remote-control` startup and first-boot /login flow.
#
# Differences from the pod, all deliberate:
#   - No squid, so local egress is unrestricted: no HTTP(S)_PROXY is set, and
#     git+ssh reaches github.com directly instead of CONNECT-tunneling through
#     the proxy (seed-ssh.sh writes no ProxyCommand when SQUID_HOST is unset).
#   - The SSH key is one you already have (--ssh-key), not one generated and
#     registered by the chart's create-ssh-key Job.
#   - GH_TOKEN is read from an env var you name (--token-env) and passed to the
#     engine by name only, so the PAT never lands in argv (and so never in `ps`
#     output or your shell history).
#   - /home/dev is a named volume (the home PVC's stand-in), /workspace is a
#     host directory you pick (--code-dir), so clones stay editable from the
#     host. Both survive --recreate; only --purge deletes the home volume.
#
# Example:
#   export GITHUB_TOKEN=ghp_...
#   scripts/run-local.sh --repo myorg/myrepo --ssh-key ~/.ssh/id_ed25519 \
#     --token-env GITHUB_TOKEN --code-dir ~/src/cc-rc-agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${CC_RC_IMAGE:-ghcr.io/vince-riv/cc-rc:latest}"
ENGINE="${CC_RC_ENGINE:-}"
SCRIPTS_DIR="${CC_RC_SCRIPTS_DIR:-$SCRIPT_DIR/../charts/cc-rc/files/scripts}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cc-rc"

REPO=""
SSH_KEY=""
TOKEN_ENV=""
CODE_DIR=""
CONTAINER=""
VOLUME=""
GIT_NAME=""
GIT_EMAIL=""
RESTART="unless-stopped"
ACTION="run"
RECREATE=0
ATTACH=0
FOLLOW=0
PULL=0
CHOWN="auto"
MATCH_HOST_UID=0

# Defaults mirror charts/cc-rc/values.yaml's remoteControl block.
RC_NAME=""
RC_PERMISSION_MODE="bypassPermissions"
RC_SPAWN="worktree"
RC_CAPACITY="8"
RC_UNHEALTHY_TIMEOUT="45"
RC_FIRST_BOOT_TIMEOUT="900"
RC_WORKTREE_MAX_AGE_DAYS="10"
STOP_TIMEOUT="60"

usage() {
  cat <<USAGE
Usage: $0 --repo ORG/REPO --ssh-key PATH --token-env VAR --code-dir DIR [options]

Required (for the default "run" action):
  -r, --repo ORG/REPO      GitHub repository to clone into <code-dir>/repo
  -k, --ssh-key PATH       Private SSH key registered with GitHub (read-only)
  -t, --token-env VAR      Name of the env var holding the GitHub PAT. Its
                           value becomes GH_TOKEN inside the container.
  -d, --code-dir DIR       Host directory mounted at /workspace (created if
                           missing). The repo is cloned to DIR/repo.

Options:
  -i, --image REF          Image (default: $IMAGE)
  -e, --engine NAME        docker or podman (default: first one found)
  -n, --name NAME          Container name (default: cc-rc-<org>-<repo>)
      --volume NAME        Home volume name (default: cc-rc-home-<org>-<repo>)
      --scripts-dir DIR    Orchestration scripts to mount at /opt/cc-rc/scripts
                           (default: charts/cc-rc/files/scripts in this repo)
      --git-name NAME      git user.name (default: your global git config)
      --git-email EMAIL    git user.email (default: your global git config)
      --rc-name NAME       claude remote-control --name (default: hostname)
      --permission-mode M  --permission-mode (default: $RC_PERMISSION_MODE)
      --spawn MODE         --spawn (default: $RC_SPAWN)
      --capacity N         --capacity (default: $RC_CAPACITY)
      --restart POLICY     Engine restart policy (default: $RESTART). The
                           agent exits on purpose after login and after a
                           crash, and relies on a restart to come back.
      --pull               Pull the image before starting
      --recreate           Remove an existing container first, then run
      --attach             Attach to the agent's screen session when up
      --follow             Follow container logs after starting
      --match-host-uid     Build (once per base image) a derived image whose
                           dev user has your uid:gid, so --code-dir needs no
                           chown and the clone stays owned by you
      --chown / --no-chown Force or skip chowning --code-dir to the image's
                           uid:gid (default: ask when it does not match)
      --stop               Stop and remove the container, then exit
      --purge              --stop, and also delete the home volume
  -h, --help               This help

Only --repo (or --name) is needed for --stop/--purge.
USAGE
}

die() { echo "$0: $*" >&2; exit 1; }

# Temp dirs this script creates, removed on any exit - including a die().
KEY_STAGE=""
BUILD_CTX=""
cleanup() {
  [ -z "$KEY_STAGE" ] || rm -rf "$KEY_STAGE"
  [ -z "$BUILD_CTX" ] || rm -rf "$BUILD_CTX"
}
trap cleanup EXIT

# Every long option takes its value as the next argument; fail loudly rather
# than silently consuming the following flag as a value.
val() {
  [ -n "${2:-}" ] || die "$1 requires a value"
  printf '%s' "$2"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--repo) REPO="$(val "$1" "${2:-}")"; shift 2 ;;
    -k|--ssh-key) SSH_KEY="$(val "$1" "${2:-}")"; shift 2 ;;
    -t|--token-env) TOKEN_ENV="$(val "$1" "${2:-}")"; shift 2 ;;
    -d|--code-dir) CODE_DIR="$(val "$1" "${2:-}")"; shift 2 ;;
    -i|--image) IMAGE="$(val "$1" "${2:-}")"; shift 2 ;;
    -e|--engine) ENGINE="$(val "$1" "${2:-}")"; shift 2 ;;
    -n|--name) CONTAINER="$(val "$1" "${2:-}")"; shift 2 ;;
    --volume) VOLUME="$(val "$1" "${2:-}")"; shift 2 ;;
    --scripts-dir) SCRIPTS_DIR="$(val "$1" "${2:-}")"; shift 2 ;;
    --git-name) GIT_NAME="$(val "$1" "${2:-}")"; shift 2 ;;
    --git-email) GIT_EMAIL="$(val "$1" "${2:-}")"; shift 2 ;;
    --rc-name) RC_NAME="$(val "$1" "${2:-}")"; shift 2 ;;
    --permission-mode) RC_PERMISSION_MODE="$(val "$1" "${2:-}")"; shift 2 ;;
    --spawn) RC_SPAWN="$(val "$1" "${2:-}")"; shift 2 ;;
    --capacity) RC_CAPACITY="$(val "$1" "${2:-}")"; shift 2 ;;
    --restart) RESTART="$(val "$1" "${2:-}")"; shift 2 ;;
    --pull) PULL=1; shift ;;
    --recreate) RECREATE=1; shift ;;
    --attach) ATTACH=1; shift ;;
    --follow) FOLLOW=1; shift ;;
    --match-host-uid) MATCH_HOST_UID=1; shift ;;
    --chown) CHOWN="yes"; shift ;;
    --no-chown) CHOWN="no"; shift ;;
    --stop) ACTION="stop"; shift ;;
    --purge) ACTION="purge"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

# --- engine -----------------------------------------------------------------

if [ -z "$ENGINE" ]; then
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then ENGINE="$candidate"; break; fi
  done
fi
[ -n "$ENGINE" ] || die "neither docker nor podman is on PATH - install one, or pass --engine"
command -v "$ENGINE" >/dev/null 2>&1 || die "engine '$ENGINE' is not on PATH"
"$ENGINE" info >/dev/null 2>&1 || die "'$ENGINE info' failed - is the engine running (and are you in its group)?"

# --- names ------------------------------------------------------------------

ORG=""
NAME_PART=""
if [ -n "$REPO" ]; then
  case "$REPO" in
    */*/*|/*|*/) die "--repo must be ORG/REPO, got: $REPO" ;;
    */*) ORG="${REPO%%/*}"; NAME_PART="${REPO#*/}" ;;
    *) die "--repo must be ORG/REPO, got: $REPO" ;;
  esac
  [ -n "$ORG" ] && [ -n "$NAME_PART" ] || die "--repo must be ORG/REPO, got: $REPO"
  # Same slug rules as the chart's cc-rc.repoSlug helper, so a local container
  # is named after its repo the way its StatefulSet would be.
  SLUG="$(printf '%s-%s' "$ORG" "$NAME_PART" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-][^a-z0-9-]*/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-40 | sed -e 's/-*$//')"
  [ -n "$SLUG" ] || die "--repo '$REPO' does not reduce to a usable name"
  CONTAINER="${CONTAINER:-cc-rc-$SLUG}"
  VOLUME="${VOLUME:-cc-rc-home-$SLUG}"
fi
if [ -z "$CONTAINER" ]; then
  [ "$ACTION" = "run" ] && die "--repo ORG/REPO is required"
  die "--stop/--purge need --repo ORG/REPO (or --name) to know which container to act on"
fi
VOLUME="${VOLUME:-cc-rc-home-${CONTAINER#cc-rc-}}"

container_exists() { "$ENGINE" container inspect "$CONTAINER" >/dev/null 2>&1; }
container_running() { [ "$("$ENGINE" container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]; }

# --- stop / purge -----------------------------------------------------------

if [ "$ACTION" = "stop" ] || [ "$ACTION" = "purge" ]; then
  if container_exists; then
    echo "Stopping $CONTAINER (up to ${STOP_TIMEOUT}s for claude to exit cleanly)..."
    "$ENGINE" stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null || true
    "$ENGINE" rm "$CONTAINER" >/dev/null
    echo "Removed container $CONTAINER."
  else
    echo "No container named $CONTAINER."
  fi
  if [ "$ACTION" = "purge" ]; then
    if "$ENGINE" volume inspect "$VOLUME" >/dev/null 2>&1; then
      "$ENGINE" volume rm "$VOLUME" >/dev/null
      echo "Removed home volume $VOLUME (claude login state is gone - next run logs in again)."
    else
      echo "No volume named $VOLUME."
    fi
    echo "Left the code directory alone - delete it yourself if you want it gone."
  fi
  exit 0
fi

# --- validate run inputs ----------------------------------------------------

[ -n "$REPO" ] || die "--repo ORG/REPO is required"
[ -n "$SSH_KEY" ] || die "--ssh-key PATH is required"
[ -n "$TOKEN_ENV" ] || die "--token-env VAR is required"
[ -n "$CODE_DIR" ] || die "--code-dir DIR is required"
[ -f "$SSH_KEY" ] || die "--ssh-key '$SSH_KEY' is not a file"
[ -r "$SSH_KEY" ] || die "--ssh-key '$SSH_KEY' is not readable"
[ -d "$SCRIPTS_DIR" ] || die "--scripts-dir '$SCRIPTS_DIR' is not a directory"
for s in seed-home.sh seed-ssh.sh clone-repo.sh agent-entrypoint.sh bash-prompt-hook.sh; do
  [ -f "$SCRIPTS_DIR/$s" ] || die "'$SCRIPTS_DIR' has no $s - point --scripts-dir at charts/cc-rc/files/scripts"
done

# Read the PAT by variable name, never as an argument: it is passed to the
# engine as a bare `-e GH_TOKEN`, which copies the value from this process's
# environment instead of putting it on a command line.
TOKEN="${!TOKEN_ENV:-}"
[ -n "$TOKEN" ] || die "env var \$$TOKEN_ENV is empty or unset - export your GitHub PAT there first"
export GH_TOKEN="$TOKEN"

mkdir -p "$CODE_DIR"
CODE_DIR="$(cd "$CODE_DIR" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPTS_DIR" && pwd)"

GIT_NAME="${GIT_NAME:-$(git config --get user.name || true)}"
GIT_EMAIL="${GIT_EMAIL:-$(git config --get user.email || true)}"
[ -n "$GIT_NAME" ] || die "no git user.name found - pass --git-name"
[ -n "$GIT_EMAIL" ] || die "no git user.email found - pass --git-email"

if [ "$PULL" -eq 1 ] || ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Pulling $IMAGE..."
  "$ENGINE" pull "$IMAGE"
fi

# --- existing container -----------------------------------------------------

if container_exists; then
  if [ "$RECREATE" -eq 1 ]; then
    echo "Removing existing container $CONTAINER (--recreate)..."
    "$ENGINE" stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null 2>&1 || true
    "$ENGINE" rm "$CONTAINER" >/dev/null
  elif container_running; then
    echo "$CONTAINER is already running. Attach with:"
    echo "  $ENGINE exec -it $CONTAINER screen -r remote-control"
    echo "Re-run with --recreate to replace it."
    exit 0
  else
    echo "Starting existing container $CONTAINER (use --recreate to rebuild it)..."
    "$ENGINE" start "$CONTAINER" >/dev/null
    echo "Started. Logs: $ENGINE logs -f $CONTAINER"
    exit 0
  fi
fi

# --- uid/gid and mount flags ------------------------------------------------

# The image's `dev` user, asked for rather than assumed: its uid depends on
# what the base image already allocated (Ubuntu ships an `ubuntu` user at
# 1000), so it is not a constant this script can hardcode.
# Captured first, then split via a here-string: `read` returns non-zero when
# its input has no trailing newline, which under `set -e` would end the script
# with no message at all.
echo "Checking which uid:gid $IMAGE runs as..."
DEV_IDS="$("$ENGINE" run --rm "$IMAGE" sh -c 'echo "$(id -u) $(id -g)"')" \
  || die "could not start a container from $IMAGE - check that '$ENGINE run' works at all"
read -r DEV_UID DEV_GID <<<"$DEV_IDS"
case "${DEV_UID:-}:${DEV_GID:-}" in
  *[!0-9:]*|:*|*:) die "could not read the image's uid/gid (got: '$DEV_IDS')" ;;
esac

# SELinux-enforcing hosts (podman's usual home) deny a container access to an
# unlabeled bind mount; :z relabels it as shared container content. Suffixes
# rather than a bare flag, because read-only mounts already carry a mode
# field (":ro,z") and read-write ones do not (":z").
MOUNT_RO=":ro"
MOUNT_RW=""
if [ "$(basename "$ENGINE")" = "podman" ] && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  MOUNT_RO=":ro,z"
  MOUNT_RW=":z"
fi

# Rootless podman maps your host uid to container root, which would leave the
# bind-mounted /workspace unwritable by `dev`. keep-id remaps it so your host
# uid *is* `dev` inside the container - no chown of your files needed. Probed
# rather than version-checked: the uid=/gid= form needs podman >= 4.3.
USERNS=()
KEEP_ID=0
if [ "$(basename "$ENGINE")" = "podman" ] && [ "$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)" = "true" ]; then
  if "$ENGINE" run --rm "--userns=keep-id:uid=$DEV_UID,gid=$DEV_GID" "$IMAGE" true >/dev/null 2>&1; then
    USERNS=("--userns=keep-id:uid=$DEV_UID,gid=$DEV_GID")
    KEEP_ID=1
  else
    echo "Note: this podman does not support --userns=keep-id:uid=,gid= - falling back to chowning mounts." >&2
  fi
fi

# --match-host-uid: Docker has no per-container uid mapping (no keep-id, no
# idmapped bind mounts), so the mapping gets baked into a derived image
# instead. `dev` is renumbered to your uid:gid, which makes chowning
# --code-dir unnecessary and leaves every file in the clone owned by you on
# the host. The tag embeds the base image's ID and a hash of the recipe, so a
# newly pulled base or an edited recipe gets its own derived image rather than
# silently reusing a stale one.
if [ "$MATCH_HOST_UID" -eq 1 ]; then
  HOST_UID="$(id -u)"
  HOST_GID="$(id -g)"
  [ "$HOST_UID" -ne 0 ] || die "--match-host-uid would give dev uid 0 - run this as your normal user"
  if [ "$KEEP_ID" -eq 1 ]; then
    echo "--match-host-uid: not needed - podman keep-id already maps your uid to dev."
  elif [ "$HOST_UID:$HOST_GID" = "$DEV_UID:$DEV_GID" ]; then
    echo "--match-host-uid: $IMAGE already runs as $HOST_UID:$HOST_GID - using it as is."
  else
    base_id="$("$ENGINE" image inspect -f '{{.Id}}' "$IMAGE")"
    base_id="${base_id#sha256:}"
    # Frees the target ids first (Ubuntu images ship an `ubuntu` user at
    # 1000), then renumbers dev and re-owns what it owns in its home and in
    # /workspace. Not the whole filesystem: tarballs extracted as root keep
    # their packager's uid - nodejs.org's is 1001, the same as dev's - and
    # re-owning those only copies hundreds of MB into the new layer. A dozen
    # of ~/.nvm's symlinks can keep the old gid - in testing (Docker Desktop,
    # overlayfs) lchown left their gid unchanged, even at runtime as root.
    # Harmless: symlink ownership grants nothing, and the home volume hides
    # the image's /home/dev at runtime anyway.
    BUILD_CTX="$(mktemp -d)"
    cat > "$BUILD_CTX/Dockerfile" <<DOCKERFILE
FROM $IMAGE
USER root
RUN set -eu; \\
    u="\$(getent passwd $HOST_UID | cut -d: -f1)"; \\
    if [ -n "\$u" ] && [ "\$u" != dev ]; then userdel -r "\$u" 2>/dev/null || true; fi; \\
    if getent passwd $HOST_UID >/dev/null; then echo "uid $HOST_UID is still taken" >&2; exit 1; fi; \\
    g="\$(getent group $HOST_GID | cut -d: -f1)"; \\
    if [ -n "\$g" ] && [ "\$g" != dev ]; then groupdel "\$g"; fi; \\
    groupmod -g $HOST_GID dev; \\
    usermod -u $HOST_UID -g $HOST_GID dev; \\
    find /home/dev /workspace -xdev \( -uid $DEV_UID -o -gid $DEV_GID \) -exec chown -h $HOST_UID:$HOST_GID {} +
USER dev
LABEL io.cc-rc.local.base-image="$IMAGE" io.cc-rc.local.base-id="sha256:$base_id"
DOCKERFILE
    recipe_hash="$({ sha256sum "$BUILD_CTX/Dockerfile" 2>/dev/null || shasum -a 256 "$BUILD_CTX/Dockerfile"; } | cut -c1-8)"
    DERIVED_IMAGE="localhost/cc-rc-local:${base_id:0:12}-u${HOST_UID}-g${HOST_GID}-${recipe_hash}"
    if "$ENGINE" image inspect "$DERIVED_IMAGE" >/dev/null 2>&1; then
      echo "--match-host-uid: reusing $DERIVED_IMAGE."
    else
      echo "==> match-host-uid (building $DERIVED_IMAGE: dev $DEV_UID:$DEV_GID -> $HOST_UID:$HOST_GID)"
      "$ENGINE" build -t "$DERIVED_IMAGE" "$BUILD_CTX" \
        || die "building $DERIVED_IMAGE failed"
    fi
    IMAGE="$DERIVED_IMAGE"
    DEV_UID="$HOST_UID"
    DEV_GID="$HOST_GID"
  fi
fi

host_uid_of() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || echo -1
}

# macOS engines translate ownership on bind mounts already, and keep-id makes
# it moot on rootless podman - in both cases there is nothing to fix.
needs_chown() {
  [ "$(uname -s)" = "Darwin" ] && return 1
  [ "$KEEP_ID" -eq 1 ] && return 1
  [ "$(host_uid_of "$CODE_DIR")" != "$DEV_UID" ]
}

if [ "$CHOWN" != "no" ] && needs_chown; then
  do_chown=0
  if [ "$CHOWN" = "yes" ]; then
    do_chown=1
  elif [ -t 0 ]; then
    echo "$CODE_DIR is owned by uid $(host_uid_of "$CODE_DIR"), but the agent runs as uid $DEV_UID."
    # `|| reply=""`: Ctrl-D makes read return non-zero, which under `set -e`
    # would exit silently instead of taking the [N] default.
    read -r -p "Chown it (recursively) to $DEV_UID:$DEV_GID so the agent can clone into it? [y/N] " reply || reply=""
    case "$reply" in [yY]*) do_chown=1 ;; esac
  else
    die "$CODE_DIR is not owned by uid $DEV_UID and this is not a terminal - re-run with --chown (or --no-chown to try anyway)"
  fi
  if [ "$do_chown" -eq 1 ]; then
    echo "Chowning $CODE_DIR to $DEV_UID:$DEV_GID..."
    "$ENGINE" run --rm --user 0:0 -v "$CODE_DIR:/workspace$MOUNT_RW" "$IMAGE" \
      chown -R "$DEV_UID:$DEV_GID" /workspace
  else
    echo "Skipping chown - the clone step will fail if the agent cannot write there." >&2
  fi
fi

# --- staged files -----------------------------------------------------------

# ~/.gitconfig and ~/.gitignore_global are bind-mounted for the container's
# whole life (the chart mounts them from a ConfigMap), so they live in a
# durable state dir - not a temp dir this script deletes on exit. seed-home.sh
# would delete them anyway if they were written into the home volume: it
# resets everything outside ~/.claude, ~/.cc-rc and ~/.claude.json every boot.
STATE_DIR="$STATE_ROOT/$CONTAINER"
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/gitconfig" <<GITCONFIG
[user]
	name = $GIT_NAME
	email = $GIT_EMAIL
[color]
	ui = auto
[core]
	excludesfile = /home/dev/.gitignore_global
[push]
	default = simple
	autoSetupRemote = true
[log]
	decorate = short
[init]
	defaultBranch = main
[safe]
	directory = *
GITCONFIG
cat > "$STATE_DIR/gitignore_global" <<'GITIGNORE'
*~
.*.swp
.DS_Store
/target
*.egg-info
*.pyc
__pycache__
**/.claude/settings.local.json
**/.claude/worktrees/
GITIGNORE
chmod 644 "$STATE_DIR/gitconfig" "$STATE_DIR/gitignore_global"

# seed-ssh.sh expects both halves of the key under /mnt/ssh-key, so the key is
# staged (never mounted from its real path) - the public half is derived when
# you only have the private one. The image's `dev` uid usually differs from
# yours, so the mounted dir is 0755 and the copies 0644. Only that inner dir is
# mounted - its own mode is what the container sees - while the outer mktemp
# dir stays 0700, so no other user on the host can reach the copies.
KEY_STAGE="$(mktemp -d)"
chmod 700 "$KEY_STAGE"
KEY_MOUNT="$KEY_STAGE/ssh-key"
mkdir -m 755 "$KEY_MOUNT"
install -m 644 "$SSH_KEY" "$KEY_MOUNT/id_ed25519"
if [ -f "$SSH_KEY.pub" ]; then
  install -m 644 "$SSH_KEY.pub" "$KEY_MOUNT/id_ed25519.pub"
else
  ssh-keygen -y -f "$SSH_KEY" > "$KEY_MOUNT/id_ed25519.pub" \
    || die "no $SSH_KEY.pub and 'ssh-keygen -y' could not derive it (passphrase-protected key?)"
  chmod 644 "$KEY_MOUNT/id_ed25519.pub"
fi

# --- init phases, in the StatefulSet's order --------------------------------

"$ENGINE" volume inspect "$VOLUME" >/dev/null 2>&1 || "$ENGINE" volume create "$VOLUME" >/dev/null

phase() {
  local label="$1"; shift
  echo "==> $label"
  "$ENGINE" run --rm ${USERNS[@]+"${USERNS[@]}"} "$@"
}

# A new volume mounted where the image has no directory (/mnt/home-pvc) comes
# up root-owned, so seed-home - running as dev - could not write to it; the pod
# gets the same fix from fsGroup. Also re-owns a volume last used at another
# uid (e.g. before --match-host-uid), whose 0600 claude credentials would
# otherwise be unreadable. Recursive only when the top-level owner is wrong.
phase "prep-home (home volume owned by $DEV_UID:$DEV_GID)" \
  --user 0:0 \
  -v "$VOLUME:/mnt/home-pvc" \
  "$IMAGE" sh -c "[ \"\$(stat -c %u:%g /mnt/home-pvc)\" = $DEV_UID:$DEV_GID ] || chown -R $DEV_UID:$DEV_GID /mnt/home-pvc"

# wait-for-squid is skipped on purpose: there is no proxy to wait for here.
phase "seed-home (sync ~/.claude from the image onto the home volume)" \
  -v "$VOLUME:/mnt/home-pvc" \
  -v "$SCRIPTS_DIR:/opt/cc-rc/scripts$MOUNT_RO" \
  "$IMAGE" bash /opt/cc-rc/scripts/seed-home.sh

# SQUID_HOST/SQUID_PORT empty: seed-ssh.sh then writes an ~/.ssh/config with
# no ProxyCommand, so git+ssh goes straight out to github.com.
phase "seed-ssh (install the key, ssh config and known_hosts)" \
  -e SQUID_HOST= -e SQUID_PORT= \
  -v "$VOLUME:/mnt/home-pvc" \
  -v "$KEY_MOUNT:/mnt/ssh-key$MOUNT_RO" \
  -v "$SCRIPTS_DIR:/opt/cc-rc/scripts$MOUNT_RO" \
  "$IMAGE" bash /opt/cc-rc/scripts/seed-ssh.sh

phase "clone-repo ($REPO -> $CODE_DIR/repo)" \
  -e "REPO_ORG=$ORG" -e "REPO_NAME=$NAME_PART" \
  -v "$VOLUME:/home/dev" \
  -v "$CODE_DIR:/workspace$MOUNT_RW" \
  -v "$STATE_DIR/gitconfig:/home/dev/.gitconfig$MOUNT_RO" \
  -v "$STATE_DIR/gitignore_global:/home/dev/.gitignore_global$MOUNT_RO" \
  -v "$SCRIPTS_DIR:/opt/cc-rc/scripts$MOUNT_RO" \
  "$IMAGE" bash /opt/cc-rc/scripts/clone-repo.sh

# --- agent ------------------------------------------------------------------

# Whether claude has been through /login already, read before the agent starts
# so the right instructions get printed below.
FIRST_BOOT=1
if "$ENGINE" run --rm ${USERNS[@]+"${USERNS[@]}"} -v "$VOLUME:/home/dev" "$IMAGE" \
     test -f /home/dev/.cc-rc/login-complete >/dev/null 2>&1; then
  FIRST_BOOT=0
fi

# --restart: the agent exits on purpose once login completes, and again after
# RC_UNHEALTHY_TIMEOUT of a dead remote-control - both rely on a restart to
# come back, exactly as the StatefulSet's pod does.
echo "==> agent ($CONTAINER)"
"$ENGINE" run -d \
  --name "$CONTAINER" \
  --hostname "$CONTAINER" \
  --restart "$RESTART" \
  --init \
  --stop-timeout "$STOP_TIMEOUT" \
  ${USERNS[@]+"${USERNS[@]}"} \
  -e GH_TOKEN \
  -e "RC_NAME=$RC_NAME" \
  -e "RC_PERMISSION_MODE=$RC_PERMISSION_MODE" \
  -e "RC_SPAWN=$RC_SPAWN" \
  -e "RC_CAPACITY=$RC_CAPACITY" \
  -e "RC_UNHEALTHY_TIMEOUT=$RC_UNHEALTHY_TIMEOUT" \
  -e "RC_FIRST_BOOT_TIMEOUT=$RC_FIRST_BOOT_TIMEOUT" \
  -e "RC_WORKTREE_MAX_AGE_DAYS=$RC_WORKTREE_MAX_AGE_DAYS" \
  -e "RC_SHUTDOWN_WAIT=$((STOP_TIMEOUT - 5))" \
  -e "RC_EXEC_PREFIX=$ENGINE exec -it $CONTAINER" \
  -e PROMPT_COMMAND="source /opt/cc-rc/scripts/bash-prompt-hook.sh" \
  -v "$VOLUME:/home/dev" \
  -v "$CODE_DIR:/workspace$MOUNT_RW" \
  -v "$STATE_DIR/gitconfig:/home/dev/.gitconfig$MOUNT_RO" \
  -v "$STATE_DIR/gitignore_global:/home/dev/.gitignore_global$MOUNT_RO" \
  -v "$SCRIPTS_DIR:/opt/cc-rc/scripts$MOUNT_RO" \
  "$IMAGE" bash /opt/cc-rc/scripts/agent-entrypoint.sh >/dev/null

echo
echo "Container $CONTAINER is up. Repo is at $CODE_DIR/repo."
if [ "$FIRST_BOOT" -eq 1 ]; then
  cat <<FIRSTBOOT
claude is not logged in yet. Finish the one-time login:
  1. $ENGINE exec -it $CONTAINER screen -r claude-login
  2. Run: claude      then, inside claude: /login
  3. Run: cc-rc-finish-login
The container restarts itself into remote-control mode a few seconds later.
It gives up and restarts after ${RC_FIRST_BOOT_TIMEOUT}s if nobody logs in.
FIRSTBOOT
else
  echo "Login state was already on the home volume - it should reach remote-control on its own."
fi
cat <<HINTS

  Logs:            $ENGINE logs -f $CONTAINER
  Agent session:   $ENGINE exec -it $CONTAINER screen -r remote-control
  Shell:           $ENGINE exec -it $CONTAINER bash
  Stop + remove:   $0 --repo $REPO --stop
  Also drop login: $0 --repo $REPO --purge
HINTS

wait_for_screen() {
  local session="$1" waited=0
  while [ "$waited" -lt 60 ]; do
    if "$ENGINE" exec "$CONTAINER" screen -ls 2>/dev/null | grep -q "$session"; then return 0; fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

if [ "$ATTACH" -eq 1 ]; then
  session="remote-control"
  [ "$FIRST_BOOT" -eq 1 ] && session="claude-login"
  echo
  echo "Waiting for the '$session' screen session..."
  if wait_for_screen "$session"; then
    exec "$ENGINE" exec -it "$CONTAINER" screen -r "$session"
  fi
  echo "'$session' did not appear within 60s - check '$ENGINE logs $CONTAINER'." >&2
  exit 1
fi

if [ "$FOLLOW" -eq 1 ]; then
  exec "$ENGINE" logs -f "$CONTAINER"
fi
