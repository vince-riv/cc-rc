#!/usr/bin/env bash
# Runs one cc-rc agent locally under docker or podman, in the same shape as the
# per-repo StatefulSet the chart deploys: same image, the same orchestration
# scripts (charts/cc-rc/files/scripts, copied and mounted where the chart
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
#
# KNOWN GAPS - to fix once someone can test on a real host. Podman and rootless
# engines are EXPERIMENTAL: only rootful Docker (Docker Desktop on WSL2) has run
# a real agent. The other engine paths were exercised with shims standing in
# for podman or a rootless dockerd, which prove this script's control flow,
# not how those engines really behave. Code sites are marked "Gap N".
#   1. Real podman is untested: both keep-id forms, the podman < 4.3 fallback
#      (plain keep-id + --match-host-uid), detecting podman behind a `docker`
#      command (podman-docker), and stopping on a podman whose info lacks
#      .Host.Security.Rootless. Rootful podman takes the Docker-style chown
#      path, also untested.
#   2. The keep-id:uid=,gid= probe discards its output. If it fails for a
#      reason other than missing support, the script silently falls back to
#      plain keep-id + --match-host-uid - that still works, but hides the real
#      error and costs a derived-image build.
#   3. Rootless dockerd is untested. Detection relies on "name=rootless" in
#      docker info's SecurityOptions.
#   4. Docker Desktop for Linux is unverified. If its daemon reports
#      name=rootless, the rootless-Docker stop blocks it, although its bind
#      mounts may translate ownership (Docker Desktop on Windows/WSL2 does not
#      report it). Fix idea: in that branch, probe whether dev can create a
#      file in the code dir, and stop only if it cannot.
#   5. macOS is untested. Ownership checks are skipped on Darwin, on the
#      assumption that its engines (Docker Desktop, podman machine) translate
#      bind-mount ownership.
#   6. --match-host-uid images pile up - one per base image ID, uid:gid and
#      recipe - and nothing removes old ones.
#   7. In a derived image, a dozen ~/.nvm symlinks can keep the old gid (an
#      lchown quirk seen on Docker Desktop/overlayfs). Harmless; see the recipe.
#   8. SELinux :z relabeling (both engines) is untested on a real SELinux host.
#      :z relabels a host path recursively: --code-dir gets relabeled, while
#      the scripts are mounted from a copy in the state dir, so your cc-rc
#      checkout does not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "$0: $*" >&2; exit 1; }

# Every option except the one-shot actions (--stop, --purge, --recreate,
# --help) also reads a CC_RC_* env var: the flag's name in upper case, with
# "-" as "_". A flag on the command line always wins over its env var.
#
# env_bool OUT_VAR ENV_VAR DEFAULT - for on/off options. Anything but
# 1/true/yes/on or 0/false/no/off is an error, not a silent "off".
env_bool() {
  local env_name="$2" raw
  raw="${!env_name:-}"
  [ -n "$raw" ] || raw="$3"
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) printf -v "$1" '%s' 1 ;;
    0|false|no|off) printf -v "$1" '%s' 0 ;;
    *) die "$env_name must be 1/true/yes/on or 0/false/no/off, got: '$raw'" ;;
  esac
}

IMAGE="${CC_RC_IMAGE:-ghcr.io/vince-riv/cc-rc:latest}"
ENGINE="${CC_RC_ENGINE:-}"
SCRIPTS_DIR="${CC_RC_SCRIPTS_DIR:-$SCRIPT_DIR/../charts/cc-rc/files/scripts}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cc-rc"

REPO="${CC_RC_REPO:-}"
SSH_KEY="${CC_RC_SSH_KEY:-}"
TOKEN_ENV="${CC_RC_TOKEN_ENV:-}"
CODE_DIR="${CC_RC_CODE_DIR:-}"
BASE_CODE_DIR="${CC_RC_BASE_CODE_DIR:-}"
CONTAINER="${CC_RC_NAME:-}"
VOLUME="${CC_RC_VOLUME:-}"
GIT_NAME="${CC_RC_GIT_NAME:-}"
GIT_EMAIL="${CC_RC_GIT_EMAIL:-}"
RESTART="${CC_RC_RESTART:-unless-stopped}"
CHOWN="${CC_RC_CHOWN:-auto}"
env_bool PULL CC_RC_PULL 0
env_bool ATTACH CC_RC_ATTACH 0
env_bool FOLLOW CC_RC_FOLLOW 0
env_bool MATCH_HOST_UID CC_RC_MATCH_HOST_UID 0
ACTION="run"
RECREATE=0

# Defaults mirror charts/cc-rc/values.yaml's remoteControl block.
RC_NAME="${CC_RC_RC_NAME:-}"
RC_PERMISSION_MODE="${CC_RC_PERMISSION_MODE:-bypassPermissions}"
RC_SPAWN="${CC_RC_SPAWN:-worktree}"
RC_CAPACITY="${CC_RC_CAPACITY:-8}"
RC_UNHEALTHY_TIMEOUT="45"
RC_FIRST_BOOT_TIMEOUT="900"
RC_WORKTREE_MAX_AGE_DAYS="10"
STOP_TIMEOUT="60"

usage() {
  cat <<USAGE
Usage: $0 [--repo ORG/REPO] --ssh-key PATH --token-env VAR
         (--code-dir DIR | --base-code-dir DIR) [options]

Required (for the default "run" action):
  -k, --ssh-key PATH       Private SSH key registered with GitHub (read-only)
  -t, --token-env VAR      Name of the env var holding the GitHub PAT. Its
                           value becomes GH_TOKEN inside the container.
  -d, --code-dir DIR       Host directory mounted at /workspace (created if
                           missing). The repo is cloned to DIR/repo; one
                           DIR holds a clone of one repo only.
      --base-code-dir DIR  Instead of --code-dir: use DIR/<org>/<repo> (in
                           lower case), one code dir per repo under DIR. An
                           explicit --code-dir wins when both are set.
  -r, --repo ORG/REPO      GitHub repository to clone. Default: detected from
                           the git repo in the current directory - its
                           branch's upstream remote, then origin, then its
                           only github.com remote

Options:
  -i, --image REF          Image (default: $IMAGE)
  -e, --engine NAME        docker or podman (default: first one found).
                           Podman and rootless engines are experimental - see
                           KNOWN GAPS at the top of this script
  -n, --name NAME          Container name (default: cc-rc-<org>-<repo>)
      --volume NAME        Home volume name (default: cc-rc-home-<org>-<repo>)
      --scripts-dir DIR    Orchestration scripts, copied into the state dir and
                           mounted at /opt/cc-rc/scripts
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

--stop/--purge need only --repo or --name, or neither inside a clone of the repo.

Environment - every option except --stop, --purge, --recreate and --help also
reads CC_RC_<OPTION> (upper case, "-" as "_"); a flag on the command line wins:
  CC_RC_REPO           CC_RC_SSH_KEY        CC_RC_TOKEN_ENV
  CC_RC_CODE_DIR       CC_RC_BASE_CODE_DIR  CC_RC_IMAGE
  CC_RC_ENGINE         CC_RC_NAME           CC_RC_VOLUME
  CC_RC_SCRIPTS_DIR    CC_RC_GIT_NAME       CC_RC_GIT_EMAIL
  CC_RC_RC_NAME        CC_RC_SPAWN          CC_RC_CAPACITY
  CC_RC_RESTART        CC_RC_PERMISSION_MODE
  CC_RC_CHOWN          auto, yes (as --chown) or no (as --no-chown)
  CC_RC_PULL  CC_RC_ATTACH  CC_RC_FOLLOW  CC_RC_MATCH_HOST_UID
                       1/true/yes/on or 0/false/no/off
A leading ~/ in a path (CC_RC_SSH_KEY, CC_RC_CODE_DIR, CC_RC_BASE_CODE_DIR,
CC_RC_SCRIPTS_DIR) is expanded.
USAGE
}

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
    --base-code-dir) BASE_CODE_DIR="$(val "$1" "${2:-}")"; shift 2 ;;
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

case "$CHOWN" in
  auto|yes|no) ;;
  *) die "CC_RC_CHOWN must be auto, yes or no, got: '$CHOWN'" ;;
esac

# A value from an env var (or a quoted flag) can still hold a literal ~ that no
# shell expanded, e.g. one loaded from a .env file.
for path_var in SSH_KEY CODE_DIR BASE_CODE_DIR SCRIPTS_DIR; do
  path_val="${!path_var}"
  case "$path_val" in
    "~") printf -v "$path_var" '%s' "$HOME" ;;
    "~/"*) printf -v "$path_var" '%s' "$HOME/${path_val#"~/"}" ;;
  esac
done

# --- repo -------------------------------------------------------------------

# Prints ORG/REPO for a github.com remote URL - scp-style (git@github.com:o/r),
# ssh://, https:// or git://, with or without .git, a user, or a port (as in
# ssh://git@ssh.github.com:443/o/r) - and nothing for any other URL. An ssh
# config Host alias hides the real host, so it cannot be recognized.
github_repo_from_url() {
  printf '%s\n' "${1%/}" | sed -nE \
    -e 's#^(ssh|https?|git)://([^@/]+@)?(ssh\.)?github\.com(:[0-9]+)?/([^/]+)/([^/]+)$#\5/\6#p' \
    -e 's#^([^@/:]+@)?(ssh\.)?github\.com:([^/]+)/([^/]+)$#\3/\4#p' \
    | sed -e 's#\.git$##'
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

host_uid_of() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null || echo -1
}

# Sets REPO from the git repo in the current directory: the current branch's
# upstream remote first, then origin, then the only github.com remote if there
# is exactly one. On failure, leaves the reason in DETECT_WHY for the error
# that follows. Never prints a remote's URL - an https one can embed a token.
DETECT_WHY="no detection was attempted"
detect_repo() {
  local branch="" upstream="" remote="" parsed="" only="" only_remote="" count=0
  if ! command -v git >/dev/null 2>&1; then
    DETECT_WHY="git is not installed"
    return 1
  fi
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    DETECT_WHY="$PWD is not inside a git repository"
    return 1
  fi
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ -z "$branch" ] || upstream="$(git config --get "branch.$branch.remote" 2>/dev/null || true)"
  # "." is git's name for a branch that tracks another local branch.
  [ "$upstream" != "." ] || upstream=""
  for remote in ${upstream:+"$upstream"} origin; do
    parsed="$(github_repo_from_url "$(git remote get-url "$remote" 2>/dev/null || true)")"
    if [ -n "$parsed" ]; then
      REPO="$parsed"
      echo "No --repo given - using $REPO, from remote '$remote' of the git repo in $PWD."
      return 0
    fi
  done
  while IFS= read -r remote; do
    parsed="$(github_repo_from_url "$(git remote get-url "$remote" 2>/dev/null || true)")"
    [ -n "$parsed" ] || continue
    count=$((count + 1))
    only="$parsed"
    only_remote="$remote"
  done < <(git remote)
  if [ "$count" -eq 1 ]; then
    REPO="$only"
    echo "No --repo given - using $REPO, from remote '$only_remote' of the git repo in $PWD."
    return 0
  fi
  if [ "$count" -eq 0 ]; then
    DETECT_WHY="the git repo in $PWD has no github.com remote"
  else
    DETECT_WHY="the git repo in $PWD has $count github.com remotes, and neither its branch's upstream nor origin is one of them"
  fi
  return 1
}

# Needed for "run" even with --name, since the clone needs a repo; for --stop
# and --purge only when no --name says which container to act on.
if [ -z "$REPO" ] && { [ "$ACTION" = "run" ] || [ -z "$CONTAINER" ]; }; then
  detect_repo || true
fi

# --- engine -----------------------------------------------------------------

if [ -z "$ENGINE" ]; then
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then ENGINE="$candidate"; break; fi
  done
fi
[ -n "$ENGINE" ] || die "neither docker nor podman is on PATH - install one, or pass --engine"
command -v "$ENGINE" >/dev/null 2>&1 || die "engine '$ENGINE' is not on PATH"
"$ENGINE" info >/dev/null 2>&1 || die "'$ENGINE info' failed - is the engine running (and are you in its group)?"

# Which engine this really is, asked of the engine rather than read from its
# command name: Fedora/RHEL's podman-docker package installs a `docker` that
# runs podman, and the search above tries `docker` first. podman's info has
# .Host.Security.Rootless and Docker's has no .Host at all, so that single
# template both identifies podman and says whether it runs rootless.
#
# Rootless engines map your host uid to container root, and container uids to
# host subuids. That changes who can write a bind-mounted code dir - see the
# rootless checks under "validate run inputs". Docker's security options are
# captured before matching: grep -q under pipefail can fail a pipeline that
# did match, by closing the pipe on docker early. (Gaps 1, 3 and 4.)
ENGINE_IS_PODMAN=0
ROOTLESS_PODMAN=0
ROOTLESS_DOCKER=0
if podman_rootless="$("$ENGINE" info --format '{{.Host.Security.Rootless}}' 2>/dev/null)"; then
  ENGINE_IS_PODMAN=1
  [ "$podman_rootless" != "true" ] || ROOTLESS_PODMAN=1
  # Only for "run": --stop and --purge use nothing engine-specific.
  [ "$ACTION" != "run" ] || echo "Note: podman support is experimental - see KNOWN GAPS at the top of $0." >&2
else
  # The template also fails on a podman whose info lacks that field (podman
  # 2.x used another schema, and a future rename would do the same). Taking
  # that podman for Docker would skip every rootless guard and end in a chown
  # to a host subuid, so ask the command what it is before assuming Docker.
  # Only "run" is at risk; --stop and --purge work the same on both engines.
  if [ "$ACTION" = "run" ]; then
    case "$("$ENGINE" --version 2>/dev/null || true)" in
      [Pp]odman*) die "$ENGINE reports itself as podman, but its info has no .Host.Security.Rootless, so this script cannot tell whether it runs rootless - it stops rather than guess. Use a newer podman." ;;
    esac
  fi
  security_opts="$("$ENGINE" info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
  case "$security_opts" in
    *name=rootless*) ROOTLESS_DOCKER=1 ;;
  esac
fi

# --- names ------------------------------------------------------------------

# Whether --volume/CC_RC_VOLUME named the volume, before a name gets derived.
VOLUME_GIVEN=0
[ -z "$VOLUME" ] || VOLUME_GIVEN=1

ORG=""
NAME_PART=""
if [ -n "$REPO" ]; then
  case "$REPO" in
    */*/*|/*|*/) die "--repo must be ORG/REPO, got: $REPO" ;;
    */*) ORG="${REPO%%/*}"; NAME_PART="${REPO#*/}" ;;
    *) die "--repo must be ORG/REPO, got: $REPO" ;;
  esac
  [ -n "$ORG" ] && [ -n "$NAME_PART" ] || die "--repo must be ORG/REPO, got: $REPO"
  # GitHub's own character set. Also what keeps --base-code-dir's
  # DIR/<org>/<repo> inside DIR - an org or repo of ".." would escape it.
  for repo_part in "$ORG" "$NAME_PART"; do
    case "$repo_part" in
      .|..|*[![:alnum:]._-]*) die "--repo '$REPO' is not a valid GitHub ORG/REPO" ;;
    esac
  done
  # Same slug rules as the chart's cc-rc.repoSlug helper, so a local container
  # is named after its repo the way its StatefulSet would be.
  SLUG="$(printf '%s-%s' "$ORG" "$NAME_PART" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9-][^a-z0-9-]*/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-40 | sed -e 's/-*$//')"
  [ -n "$SLUG" ] || die "--repo '$REPO' does not reduce to a usable name"
  CONTAINER="${CONTAINER:-cc-rc-$SLUG}"
  VOLUME="${VOLUME:-cc-rc-home-$SLUG}"
fi
if [ -z "$CONTAINER" ]; then
  [ "$ACTION" = "run" ] && die "--repo ORG/REPO (or CC_RC_REPO) is required, and none could be detected: $DETECT_WHY"
  die "--stop/--purge need --repo ORG/REPO or --name to know which container to act on, and no repo could be detected: $DETECT_WHY"
fi
# Docker's own container-name rule, [a-zA-Z0-9][a-zA-Z0-9_.-]+. It also keeps
# $STATE_ROOT/$CONTAINER - written on every run, deleted by --purge - inside
# $STATE_ROOT: no "/" can get in, and no name can be "." or "..".
case "$CONTAINER" in
  ?|[![:alnum:]]*|*[![:alnum:]_.-]*) die "--name '$CONTAINER' is not a valid container name ([a-zA-Z0-9][a-zA-Z0-9_.-]+)" ;;
esac
VOLUME="${VOLUME:-cc-rc-home-${CONTAINER#cc-rc-}}"

container_exists() { "$ENGINE" container inspect "$CONTAINER" >/dev/null 2>&1; }
container_running() { [ "$("$ENGINE" container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]; }

# --- stop / purge -----------------------------------------------------------

if [ "$ACTION" = "stop" ] || [ "$ACTION" = "purge" ]; then
  # The volume --purge removes, best source first: an explicit --volume; the
  # volume the container really has at /home/dev; the name recorded at run
  # time (still there after an earlier --stop); the name derived above. That
  # last one alone can be wrong: a run with a custom --name still names its
  # volume after the repo, not after the container.
  if [ "$ACTION" = "purge" ] && [ "$VOLUME_GIVEN" -eq 0 ]; then
    known_volume=""
    if container_exists; then
      known_volume="$("$ENGINE" container inspect -f '{{range .Mounts}}{{if eq .Destination "/home/dev"}}{{.Name}}{{end}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
    fi
    if [ -z "$known_volume" ] && [ -f "$STATE_ROOT/$CONTAINER/volume" ]; then
      known_volume="$(cat "$STATE_ROOT/$CONTAINER/volume")"
    fi
    VOLUME="${known_volume:-$VOLUME}"
  fi
  if container_exists; then
    echo "Stopping $CONTAINER (up to ${STOP_TIMEOUT}s for claude to exit cleanly)..."
    "$ENGINE" stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null || true
    "$ENGINE" rm "$CONTAINER" >/dev/null
    echo "Removed container $CONTAINER."
  else
    echo "No container named $CONTAINER."
  fi
  if [ "$ACTION" = "purge" ]; then
    if ! "$ENGINE" volume inspect "$VOLUME" >/dev/null 2>&1; then
      # Never a quiet success: whoever runs --purge expects the claude login
      # state to be gone afterwards.
      echo "$0: no volume named $VOLUME - nothing was purged." >&2
      leftover="$("$ENGINE" volume ls --format '{{.Name}}' 2>/dev/null | grep '^cc-rc-home-' || true)"
      if [ -n "$leftover" ]; then
        echo "These cc-rc home volumes still exist; pass --volume NAME to purge one:" >&2
        printf '%s\n' "$leftover" | sed 's/^/  /' >&2
      fi
      exit 1
    fi
    "$ENGINE" volume rm "$VOLUME" >/dev/null
    echo "Removed home volume $VOLUME (claude login state is gone - next run logs in again)."
    rm -rf "${STATE_ROOT:?}/$CONTAINER"
    echo "Left the code directory alone - delete it yourself if you want it gone."
  fi
  exit 0
fi

# --- validate run inputs ----------------------------------------------------

[ -n "$REPO" ] || die "--repo ORG/REPO (or CC_RC_REPO) is required, and none could be detected: $DETECT_WHY"
[ -n "$SSH_KEY" ] || die "--ssh-key PATH (or CC_RC_SSH_KEY) is required"
[ -n "$TOKEN_ENV" ] || die "--token-env VAR (or CC_RC_TOKEN_ENV) is required"
# --base-code-dir: one code dir per repo under a shared base, so it can be set
# once (CC_RC_BASE_CODE_DIR) for every repo without ever tripping the
# one-clone-per-code-dir guard below. Lower case, because GitHub names ignore
# case - Org/Repo and org/repo must not end up as two separate clones.
if [ -n "$BASE_CODE_DIR" ]; then
  if [ -z "$CODE_DIR" ]; then
    CODE_DIR="${BASE_CODE_DIR%/}/$(lower "$ORG")/$(lower "$NAME_PART")"
    echo "Using code dir $CODE_DIR (from the base code dir)."
  else
    echo "Note: a code dir and a base code dir are both set - using the code dir, $CODE_DIR."
  fi
fi
[ -n "$CODE_DIR" ] || die "--code-dir DIR or --base-code-dir DIR (or CC_RC_CODE_DIR / CC_RC_BASE_CODE_DIR) is required"
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

# clone-repo.sh skips any existing clone, so a --code-dir shared between repos
# (easy once CC_RC_CODE_DIR is set for all of them) would silently run this
# agent on another repo's clone. safe.directory: the clone may belong to the
# image's dev uid rather than to you.
if [ -d "$CODE_DIR/repo/.git" ] && command -v git >/dev/null 2>&1; then
  existing_repo="$(github_repo_from_url "$(git -c safe.directory='*' -C "$CODE_DIR/repo" remote get-url origin 2>/dev/null || true)")"
  if [ -n "$existing_repo" ] && [ "$(lower "$existing_repo")" != "$(lower "$REPO")" ]; then
    die "$CODE_DIR/repo is already a clone of $existing_repo, not $REPO - use another --code-dir"
  fi
fi

# The rootless checks run here, before the pull, the probes and any
# --match-host-uid build: nothing they read changes after this point, and a
# user they stop should not wait through a build first.
#
# Rootless Docker maps your uid to container root while the agent runs as dev,
# so dev can only write the code dir once it belongs to a host subuid - which
# takes it away from you. Docker has no keep-id to map you onto dev, and
# --match-host-uid cannot help either (dev would have to be container root).
# (Gap 3: untested on a real rootless dockerd. Gap 4: may wrongly stop Docker
# Desktop for Linux, if its daemon reports name=rootless.)
if [ "$ROOTLESS_DOCKER" -eq 1 ] && [ "$CHOWN" != "no" ]; then
  die "rootless Docker maps your uid to container root, but the agent runs as the image's dev user, so it cannot write $CODE_DIR unless the dir is handed to a host subuid you cannot write as. Use rootful Docker, or rootless podman (it maps your uid onto dev with --userns=keep-id) - or pass --no-chown to try anyway."
fi

# Rootless podman, with either keep-id form: the agent writes as you, so the
# code dir must be yours on the host. No chown run from a container can get it
# there - its ids land on host subuids - so this is a check with a way out,
# never a chown. Skipped on macOS, like needs_chown: podman machine's bind
# mounts cross the VM with ownership translated, and `podman unshare` runs in
# that VM, where it cannot fix a macOS path. (Gap 5: untested on macOS.)
if [ "$ROOTLESS_PODMAN" -eq 1 ] && [ "$(uname -s)" != "Darwin" ] && [ "$CHOWN" != "no" ] && [ "$(host_uid_of "$CODE_DIR")" != "$(id -u)" ]; then
  die "$CODE_DIR is owned by uid $(host_uid_of "$CODE_DIR"), not by you (uid $(id -u)). Under rootless podman the agent writes as you, and a chown from inside a container would hand the dir to a host subuid. Fix the owner on the host - for a dir an earlier container left on a subuid: podman unshare chown -R 0:0 '$CODE_DIR' - or pass --no-chown to try anyway."
fi
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

# SELinux-enforcing hosts (the default on Fedora and RHEL) deny a container access to an
# unlabeled bind mount; :z relabels it as shared container content. Suffixes
# rather than a bare flag, because read-only mounts already carry a mode
# field (":ro,z") and read-write ones do not (":z").
MOUNT_RO=":ro"
MOUNT_RW=""
# Docker and podman both support :z, so this applies to either engine. :z
# relabels a host path recursively, which is why the scripts get mounted from
# a copy in the state dir (see "staged files") rather than from your cc-rc
# checkout: the only dir of yours that gets relabeled is --code-dir.
# (Gap 8: untested on a real SELinux host.)
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  MOUNT_RO=":ro,z"
  MOUNT_RW=":z"
fi

# Rootless podman maps your host uid to container root, which would leave the
# bind-mounted /workspace unwritable by `dev`. keep-id fixes that without a
# chown, in one of two forms - probed, not version-checked:
# - podman >= 4.3: keep-id:uid=,gid= maps your uid straight onto dev's.
# - older podman (Ubuntu 22.04 ships 3.4): plain keep-id maps your uid onto the
#   same uid inside, so dev must have your uid. --match-host-uid's derived
#   image gives it exactly that, so it gets turned on.
# A chown is never the answer here: inside a rootless container, files chowned
# to dev land on a host subuid that you cannot write as.
USERNS=()
KEEP_ID=0
# (Gap 1: untested on real podman. Gap 2: this first probe's output is
# discarded, so any failure falls through to the plain keep-id form.)
if [ "$ROOTLESS_PODMAN" -eq 1 ]; then
  if "$ENGINE" run --rm "--userns=keep-id:uid=$DEV_UID,gid=$DEV_GID" "$IMAGE" true >/dev/null 2>&1; then
    USERNS=("--userns=keep-id:uid=$DEV_UID,gid=$DEV_GID")
    KEEP_ID=1
  elif keep_id_err="$("$ENGINE" run --rm --userns=keep-id "$IMAGE" true 2>&1 >/dev/null)"; then
    USERNS=("--userns=keep-id")
    if [ "$MATCH_HOST_UID" -eq 0 ]; then
      echo "Note: this podman has no --userns=keep-id:uid=,gid= - turning on --match-host-uid, so plain keep-id maps your uid onto dev."
      MATCH_HOST_UID=1
    fi
  else
    # All this code knows is that --userns=keep-id failed, so the message says
    # only that, with podman's own error attached. The image itself does
    # start: the explicit pull and the "Checking which uid:gid" probe - a
    # plain run, with no --userns - both succeeded before this point.
    die "podman could not start $IMAGE with --userns=keep-id: $(printf '%s' "$keep_id_err" | tail -n 3). Without keep-id, a chown would hand $CODE_DIR to a host subuid you cannot write as - use a podman with keep-id support, rootful podman, or rootful Docker."
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
    # First moves any other user or group holding the target uid or gid to a
    # free id (Ubuntu images ship `ubuntu` at 1000:1000). Moved, not deleted:
    # a group that is still some user's primary group cannot be deleted, and
    # dev itself holding one of the ids (only the other one differs) is no
    # conflict at all. Then renumbers dev and re-owns what it owns in its home
    # and in /workspace. Not the whole filesystem: tarballs extracted as root keep
    # their packager's uid - nodejs.org's is 1001, the same as dev's - and
    # re-owning those only copies hundreds of MB into the new layer. A dozen
    # of ~/.nvm's symlinks can keep the old gid - in testing (Docker Desktop,
    # overlayfs) lchown left their gid unchanged, even at runtime as root.
    # Harmless: symlink ownership grants nothing, and the home volume hides
    # the image's /home/dev at runtime anyway. (Gap 7.)
    BUILD_CTX="$(mktemp -d)"
    cat > "$BUILD_CTX/Dockerfile" <<DOCKERFILE
FROM $IMAGE
USER root
RUN set -eu; \\
    free_id() { i=60000; while getent "\$1" "\$i" >/dev/null; do i=\$((i - 1)); done; echo "\$i"; }; \\
    u="\$(getent passwd $HOST_UID | cut -d: -f1)"; \\
    if [ -n "\$u" ] && [ "\$u" != dev ]; then usermod -u "\$(free_id passwd)" "\$u"; fi; \\
    g="\$(getent group $HOST_GID | cut -d: -f1)"; \\
    if [ -n "\$g" ] && [ "\$g" != dev ]; then groupmod -g "\$(free_id group)" "\$g"; fi; \\
    groupmod -g $HOST_GID dev; \\
    usermod -u $HOST_UID -g $HOST_GID dev; \\
    find /home/dev /workspace -xdev \( -uid $DEV_UID -o -gid $DEV_GID \) -exec chown -h $HOST_UID:$HOST_GID {} +
USER dev
LABEL io.cc-rc.local.base-image="$IMAGE" io.cc-rc.local.base-id="sha256:$base_id"
DOCKERFILE
    # (Gap 6: every base image ID, uid:gid and recipe gets its own tag, and
    # nothing removes the old ones.)
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

# macOS engines translate ownership on bind mounts already, and both rootless
# engines got settled under "validate run inputs" - a chown from a rootless
# container would only hand the code dir to a host subuid. In all of these
# cases there is nothing to chown. (Gap 5: macOS untested. Gap 1: rootful
# podman takes the chown below, untested.)
needs_chown() {
  [ "$(uname -s)" = "Darwin" ] && return 1
  [ "$ROOTLESS_PODMAN" -eq 1 ] && return 1
  [ "$ROOTLESS_DOCKER" -eq 1 ] && return 1
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
# Recorded for --purge, which may run after --stop removed the container, and
# without the --volume or --repo this run derived the volume name from.
printf '%s\n' "$VOLUME" > "$STATE_DIR/volume"

# The orchestration scripts get mounted from this copy, not from --scripts-dir:
# :z on SELinux hosts relabels whatever host path it is given, and
# --scripts-dir defaults to a dir inside your cc-rc checkout. Refreshed on every
# run, so edited scripts take effect on the next run of this script - not on a
# restart of a running container, which keeps the copy it started with, the
# same way a pod keeps its ConfigMap until it rolls. rm first, so a script
# removed from --scripts-dir does not linger in the copy.
STAGED_SCRIPTS="$STATE_DIR/scripts"
rm -rf "$STAGED_SCRIPTS"
mkdir -p "$STAGED_SCRIPTS"
cp -R "$SCRIPTS_DIR/." "$STAGED_SCRIPTS/"
chmod -R a+rX "$STAGED_SCRIPTS"
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
  -v "$STAGED_SCRIPTS:/opt/cc-rc/scripts$MOUNT_RO" \
  "$IMAGE" bash /opt/cc-rc/scripts/seed-home.sh

# SQUID_HOST/SQUID_PORT empty: seed-ssh.sh then writes an ~/.ssh/config with
# no ProxyCommand, so git+ssh goes straight out to github.com.
phase "seed-ssh (install the key, ssh config and known_hosts)" \
  -e SQUID_HOST= -e SQUID_PORT= \
  -v "$VOLUME:/mnt/home-pvc" \
  -v "$KEY_MOUNT:/mnt/ssh-key$MOUNT_RO" \
  -v "$STAGED_SCRIPTS:/opt/cc-rc/scripts$MOUNT_RO" \
  "$IMAGE" bash /opt/cc-rc/scripts/seed-ssh.sh

phase "clone-repo ($REPO -> $CODE_DIR/repo)" \
  -e "REPO_ORG=$ORG" -e "REPO_NAME=$NAME_PART" \
  -v "$VOLUME:/home/dev" \
  -v "$CODE_DIR:/workspace$MOUNT_RW" \
  -v "$STATE_DIR/gitconfig:/home/dev/.gitconfig$MOUNT_RO" \
  -v "$STATE_DIR/gitignore_global:/home/dev/.gitignore_global$MOUNT_RO" \
  -v "$STAGED_SCRIPTS:/opt/cc-rc/scripts$MOUNT_RO" \
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
  -v "$STAGED_SCRIPTS:/opt/cc-rc/scripts$MOUNT_RO" \
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
