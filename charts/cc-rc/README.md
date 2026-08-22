# cc-rc

![Version: 0.0.0](https://img.shields.io/badge/Version-0.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.0](https://img.shields.io/badge/AppVersion-1.0.0-informational?style=flat-square)

Headless Claude Code remote-control agents (one StatefulSet per GitHub repo) behind a locked-down Squid egress proxy

Helm chart that runs headless [Claude Code](https://claude.ai/) agents, one per GitHub
repo, each behind a locked-down [Squid](https://www.squid-cache.org/) egress proxy.

## What it deploys

- A Squid `Deployment` + `Service`, configured from `values.yaml` (allow list / deny
  list / default-blocked cluster-internal ranges). This is the only workload in the
  chart with unrestricted egress.
- A pre-install/pre-upgrade hook `Job` (see "SSH deploy key" below) that generates an
  ED25519 key and registers it against a GitHub account using one org's PAT (see
  "Configuring GitHub auth" below), storing it in a `Secret`.
- One `StatefulSet` (replicas: 1) per entry in `values.repos`, running the
  `ghcr.io/vince-riv/cc-rc` image. Each gets:
  - a 5Gi PVC mounted at `/home/dev` — the `dev` user's entire home directory, not
    just `~/.claude`
  - a 5Gi PVC mounted at `/workspace`
  - a `seed-home` init container that syncs the image's baked-in `/home/dev` onto the
    home PVC on every start, with different rules for `~/.claude/` vs. everywhere else:
    `~/.claude/` files the image ships (e.g. `~/.claude/settings.json`) are always
    overwritten, but anything else already there — extra files, claude's own
    credentials/session state (`~/.claude/.credentials.json`) — is never deleted;
    everywhere else on the PVC is fully reset to match the image (deleting anything
    the image doesn't ship), except `~/.cc-rc/` (this chart's own login-complete
    marker — see "Claude login and remote-control" below) and `~/.claude.json`
    (claude's own account/session state — a file sibling to the `~/.claude/`
    directory, not inside it, so it needs its own exclusion)
  - a `seed-ssh` init container that copies the deploy key onto `~/.ssh/id_ed25519`
    (`0600`, `~/.ssh` itself `0700`) and seeds `~/.ssh/known_hosts` with GitHub's host
    keys if it isn't already there — see "SSH deploy key" below
  - a `clone-repo` init container that clones the repo, over SSH, into
    `/workspace/repo` (skipped if already cloned)
  - `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (+ lowercase variants) pointed at the Squid
    `Service`, and `GH_TOKEN` from the `Secret` key matching this StatefulSet's own
    `repos[].org`
  - a startup script that runs `claude` in a `screen` session: see
    "Claude login and remote-control" below
- A `NetworkPolicy` that denies all egress from the agent `StatefulSet` pods except to
  the Squid `Service` and to cluster DNS — git+ssh needs no separate rule, since it
  tunnels through that same squid egress (see "SSH deploy key" below). Never applied to
  the SSH-key `Job`'s pods either, which — like squid's — keep unrestricted egress.
- A `ConfigMap` rendering `~/.gitconfig` and `~/.gitignore_global` for the `dev` user,
  mounted read-only into every agent.
- A `ConfigMap` holding the `seed-home`/`seed-ssh`/`clone-repo`/`create-ssh-key`/
  agent-entrypoint scripts (`charts/cc-rc/files/scripts/`), mounted read-only at
  `/opt/cc-rc/scripts` rather than baked into the image — so a custom
  `image.repository`/`image.tag` only needs to provide the underlying tools (`claude`,
  `screen`, `git`, `rsync`, `ssh-keygen`, `connect` (from `connect-proxy`), `gh`,
  `kubectl`), not this orchestration
  logic. A `checksum/scripts` pod annotation rolls the `StatefulSet`s on any script
  change.

## Installing

Published releases (see `.github/workflows/chart-release.yml`) are pushed to GHCR as an
OCI artifact:

```sh
helm install cc-rc oci://ghcr.io/vince-riv/charts/cc-rc --version 0.1.0 \
  --set repos[0].org=myorg --set repos[0].repo=myrepo \
  --set github.tokens.myorg=ghp_... \
  --set git.name="CI Bot" --set git.email=ci@example.com
```

They're also published to the gh-pages-backed Helm repo at
`https://vince-riv.github.io/cc-rc/`:

```sh
helm repo add cc-rc https://vince-riv.github.io/cc-rc/
helm repo update
helm install cc-rc cc-rc/cc-rc --version 0.1.0 \
  --set repos[0].org=myorg --set repos[0].repo=myrepo \
  --set github.tokens.myorg=ghp_... \
  --set git.name="CI Bot" --set git.email=ci@example.com
```

## Configuring GitHub auth

GitHub PATs are scoped to a single org and/or user, so one flat token rarely covers
every `repos[]` entry — each per-repo agent's `GH_TOKEN` comes from the key matching
its own `repos[].org`, within one shared Secret. Set exactly one of:

```yaml
github:
  tokens:                    # chart creates a Secret for you, one key per org
    myorg: "ghp_..."
    otherorg: "ghp_..."
# or
github:
  existingSecret: "my-secret"  # holds the same shape: one key per org, key == org name
```

For anything beyond quick testing, prefer `existingSecret` together with
`scripts/manage-github-tokens.sh` (run from your own machine, needs `kubectl` access) —
it keeps every PAT out of `values.yaml`/git entirely. It prompts for a PAT per org,
pre-filled with that org's current value if the Secret already has one (so adding a new
org, or rotating one, never means re-typing every other org's PAT), then
`kubectl apply --server-side`s the merged result in one shot:

```sh
scripts/manage-github-tokens.sh -n my-namespace -s my-secret myorg otherorg
```

Run it with no `ORG` arguments to be prompted for org names interactively instead.

## Configuring per-repo resources

`repos[].resources` is deep-merged over the top-level `resources` default, so a repo
can override just `cpu` or just `memory` without repeating the other:

```yaml
resources:
  requests:
    cpu: 250m
    memory: 512Mi

repos:
  - org: myorg
    repo: myrepo
    resources:
      requests:
        cpu: "2"          # memory still comes from the default above
```

## Configuring git identity

`git.name` and `git.email` are required — the chart fails to render without them, since
they're the commit identity every agent uses. Commit signing is intentionally not
configured. The rest of `git.*` mirrors common `~/.gitconfig` defaults (push/log/init
behavior, `color.ui`), plus `git.globalIgnore`, a list of patterns written to
`~/.gitignore_global`:

```yaml
git:
  name: "CI Bot"
  email: "ci@example.com"
```

## SSH deploy key

Every agent clones and pushes over SSH, using one ED25519 key shared by all repos in
the release. A pre-install/pre-upgrade hook `Job` (`create-ssh-key.sh`, run as the
`dev` image with a scoped `ServiceAccount`) creates it:

1. Skip entirely if `sshKey.secretName` already exists — makes the whole thing
   idempotent across every `helm install`/`upgrade`.
2. `ssh-keygen -t ed25519` a fresh key pair.
3. `gh api /user/keys` to register the public half against the GitHub account behind
   `sshKey.tokenOrg`'s PAT (defaults to `repos[0].org`'s; that token needs the
   `write:public_key` scope), titled `sshKey.keyTitle`. SSH keys are account-level, not
   org-scoped, so this one key is shared by every `repos[]` entry — `tokenOrg` only
   needs to name an org whose PAT belongs to an account that can reach all of them.
4. `kubectl create secret generic sshKey.secretName` holding both halves. If this step
   fails, the just-added GitHub key is deleted again (`gh api -X DELETE /user/keys/<id>`)
   so a retry doesn't pile up orphaned keys on the account — the public key only stays
   registered if the `Secret` write actually succeeded.

The Job's `ServiceAccount` can only `create` `Secret`s, and `get`/`delete` the one named
by `sshKey.secretName` — nothing broader. It isn't proxied and isn't subject to the
agent `NetworkPolicy` either (see "What it deploys" above): it talks to the Kubernetes
API and `api.github.com` directly.

Each agent's `seed-ssh` init container then copies that `Secret` onto the home PVC on
every boot (`~/.ssh/id_ed25519` at `0600`, `~/.ssh` at `0700`) and seeds
`~/.ssh/known_hosts` with GitHub's published host keys — but only if `known_hosts`
doesn't already exist, so it's never clobbered once present. It also (re)writes
`~/.ssh/config` on every boot, pointing `git@github.com` at a `ProxyCommand` (the
`connect-proxy` package's `connect`) that tunnels the SSH connection through squid via
`CONNECT` — squid's own config unconditionally allows `CONNECT` to `github.com:22`
(regardless of `proxy.allowList`/`proxy.denyList`, unless `github.com` is itself denied)
— so no separate `NetworkPolicy` rule is needed: agent pods already have egress to the
squid `Service`, and squid's own egress is unrestricted.

Set `sshKey.enabled: false` to skip the Job (e.g. you manage `sshKey.secretName`
yourself, out of band) — the per-repo `StatefulSet`s still expect it to hold
`id_ed25519`/`id_ed25519.pub` either way.

## Claude login and remote-control

On its first boot, each agent starts a detached, logged `screen` session with an
interactive login shell in it (checked via a `~/.cc-rc/login-complete` marker file on
the home PVC, so this only happens once per repo, ever — it persists across restarts):

```sh
screen -L -Logfile /tmp/cc-rc-claude-login.log -dmS claude-login bash -lic 'cd /workspace/repo && exec bash -li'
```

`-L -Logfile` matters: `screen` sessions are otherwise invisible to `kubectl logs`/
stern entirely. The agent `tail -F`s that log into its own stdout, so session output —
including any errors — shows up there too; attach interactively if needed:

```sh
kubectl exec -it <pod> -- screen -r claude-login
```

Every interactive bash shell in the container — that session, or any ad-hoc
`kubectl exec -it <pod> -- bash` — runs `files/scripts/bash-prompt-hook.sh` (via
`$PROMPT_COMMAND`, chart-set, not baked into the image) once per shell session. While
login is incomplete it prints instructions (`claude`, then `/login`) and defines a
`cc-rc-finish-login` helper. Completion is **only** signaled by explicitly running
`cc-rc-finish-login` — never auto-detected from a running `claude remote-control`
process, since its first real run can take a few minutes to configure, and treating
its mere appearance as "done" risks moving on before that finishes. Running
`cc-rc-finish-login` writes the marker file; the agent then exits — the pod restarts
(StatefulSet pods always use `restartPolicy: Always`) into steady-state mode, where
every subsequent boot instead prunes stale worktrees (see below) and then runs:

```sh
screen -L -Logfile /tmp/cc-rc-remote-control.log -dmS remote-control bash -lic 'cd /workspace/repo && claude remote-control --name <name> --permission-mode <mode> --spawn <mode> --capacity <n>'
```

(`--continue` was tried here to reattach the last-recorded session instead of always
starting fresh, and dropped: `claude remote-control` rejects `--continue` combined with
`--spawn`/`--capacity`, and confirmed by hand that it doesn't reattach worktree sessions
the way we need anyway — see "Worktree pruning and orphaned-session recovery" below for
the recovery path that does work.)

`--name` defaults to the pod's hostname (e.g. `cc-rc-myorg-myrepo-0`) plus a
`-<timestamp>` suffix, unless `repos[].remoteControl.name` is set — the suffix keeps
each boot's session visibly distinct in claude.ai/code. `--permission-mode`, `--spawn`,
`--capacity`, and the settings below come from `remoteControl.*` (global defaults) or
`repos[].remoteControl.*` (per-repo override):

```yaml
remoteControl:
  permissionMode: bypassPermissions   # acceptEdits | auto | bypassPermissions | default | dontAsk | plan
  spawn: worktree                     # same-dir | worktree | session
  capacity: 8
  unhealthyTimeoutSeconds: 45         # steady-state: how long remote-control may be down before restarting
  firstBootTimeoutSeconds: 900        # first boot: how long to wait for a human to finish /login
  worktreeMaxAgeDays: 10              # remove .claude/worktrees/ checkouts inactive this long, on boot
```

The container's readiness probe checks for a running `claude remote-control` process
directly (no grace period). There's deliberately no `livenessProbe`: the agent
container manages its own exit-on-unhealthy instead, so `unhealthyTimeoutSeconds` is
actually honored rather than being pre-empted by kubelet on its own schedule — the
container exits (triggering a restart) once the process has been down that long.
Raise it (e.g. `--set remoteControl.unhealthyTimeoutSeconds=600`) to get more time to
`kubectl exec -it <pod> -- bash` in and debug a startup failure — the tailed log and
`screen -r remote-control` both stay attachable throughout that window.

### Graceful shutdown

On `SIGTERM` (pod termination — rollout, eviction, delete), the agent forwards
`SIGINT` to any running `claude remote-control` process and waits for it to exit
before exiting itself (confirmed `claude` exits cleanly on `SIGINT`, same as
interactive `Ctrl-C`). This matters because a hard kill mid-write can leave a
worktree locked. Kubernetes' default `terminationGracePeriodSeconds` (30s) is short
for this, so the chart raises it — `terminationGracePeriodSeconds: 60` at the
top level (not per-repo).

### Worktree pruning and orphaned-session recovery ([issue #9](https://github.com/vince-riv/cc-rc/issues/9))

`claude remote-control --spawn worktree` isolates each on-demand session in its own
git worktree under `.claude/worktrees/`, and nothing removes them. On every boot,
before starting `remote-control`, the agent removes any worktree whose transcript
(`~/.claude/projects/.../*.jsonl`) hasn't been written to in `worktreeMaxAgeDays` days.

Separately — and this is an upstream `claude remote-control` gap, not something this
chart can fully fix (tracked in issue #9) — a worktree session whose host process
dies (pod restart mid-conversation) becomes unreachable from claude.ai/code ("session
not found"), even though its local transcript survives. The image ships a manual
recovery tool for this, `rescue-sessions.sh` (not chart-delivered — baked into the
image directly, so it works regardless of chart version):

```sh
kubectl exec -it <pod> -- rescue-sessions.sh                              # list orphaned sessions
kubectl exec -it <pod> -- rescue-sessions.sh --rescue <bridgeSessionId>   # start a rescue screen session
kubectl exec -it <pod> -- screen -r rescue-<bridgeSessionId>              # attach to it
```
`--rescue` runs `claude remote-control --session-id <bridgeSessionId>` in the
worktree it was orphaned in, which re-registers that exact session with
claude.ai/code. It's manual only — orphaned sessions are surfaced for a human to
decide on, never auto-resumed on boot.

## Scheduling (nodeSelector / affinity / tolerations / PDB)

Squid (`proxy.nodeSelector`/`proxy.affinity`/`proxy.tolerations`) and the per-repo
agent StatefulSets (top-level `nodeSelector`/`affinity`/`tolerations`, overridable
per-repo via `repos[].nodeSelector`/`repos[].affinity`/`repos[].tolerations` — a full
replace, not a merge, when set) are configured independently; there's no single
shared/global setting covering both.

When `proxy.replicaCount > 1` and `proxy.affinity` is left empty, a preferred
`podAntiAffinity` (`topologyKey: kubernetes.io/hostname`) is generated automatically,
spreading squid replicas across nodes — set `proxy.affinity` explicitly to take full
control instead (it's used as-is, replacing the auto-generation entirely).

`proxy.podDisruptionBudget.enabled` (default `false`) creates a PDB for squid, but
only when `proxy.replicaCount > 1` too — a single-replica PDB just blocks voluntary
eviction of the only pod that exists:

```yaml
proxy:
  replicaCount: 2
  podDisruptionBudget:
    enabled: true
    minAvailable: 1
```

## Configuring egress

`proxy.allowList` empty (default) = open-web mode: any destination is reachable on
`proxy.allowedPortsWhenOpen`, plus `github.com:22` for git+ssh, except `proxy.denyList`
and the baked-in cluster-internal ranges (`cluster.local`, `192.168.0.0/16`,
`10.0.0.0/8`, `172.16.0.0/12`).

Setting `proxy.allowList` switches to strict mode: only those domains/CIDRs (ports
80/443) are reachable — `github.com:22` is still carved out in this mode too (every
agent needs it for its own deploy key; see "SSH deploy key" above), unless `github.com`
is itself in `proxy.denyList`, which always wins over both.

Squid's access/cache logs go to `kubectl logs`/`stern` on the squid `Deployment` pod —
`squid.conf` sends them to `/dev/stdout`, and `PEBBLE_VERBOSE=1` makes the base image's
Pebble entrypoint relay that to its own stdout (otherwise it's only visible via
`kubectl exec <squid-pod> -- pebble logs squid`).

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Default affinity for every per-repo agent StatefulSet. Override per-repo via `repos[].affinity` (full replace, not merged with this default). |
| git | object | `{"autoSetupRemote":true,"colorUi":"auto","defaultBranch":"main","editor":"","email":"","globalIgnore":["*~",".*.swp",".DS_Store","/target","*.egg-info","*.pyc","__pycache__","**/.claude/settings.local.json","**/.claude/worktrees/"],"logDecorate":"short","name":"","pushDefault":"upstream"}` | Git identity and global config for the `dev` user inside each agent, rendered into ~/.gitconfig and ~/.gitignore_global via a ConfigMap. Commit signing is intentionally not configured here. |
| git.autoSetupRemote | bool | `true` | push.autoSetupRemote |
| git.colorUi | string | `"auto"` | color.ui |
| git.defaultBranch | string | `"main"` | init.defaultBranch |
| git.editor | string | `""` | core.editor. Left unset (no editor configured) when empty. |
| git.email | string | `""` | Commit author email. Required. |
| git.globalIgnore | list | `["*~",".*.swp",".DS_Store","/target","*.egg-info","*.pyc","__pycache__","**/.claude/settings.local.json","**/.claude/worktrees/"]` | Patterns written to ~/.gitignore_global and wired up via core.excludesfile. |
| git.logDecorate | string | `"short"` | log.decorate |
| git.name | string | `""` | Commit author name. Required. |
| git.pushDefault | string | `"upstream"` | push.default |
| github | object | `{"existingSecret":"","secretName":"","tokens":{}}` | GitHub auth for cloning repos and for the `gh`/`git` CLIs inside each agent. One GitHub PAT per org - GitHub PATs are scoped to a single org and/or user, so a single flat token rarely covers every repos[] entry. Every per-repo agent's GH_TOKEN comes from the key matching ITS OWN repos[].org within one Secret. Set EXACTLY ONE of `tokens` or `existingSecret`. |
| github.existingSecret | string | `""` | Name of a pre-existing Secret to use instead of `tokens`, holding one key per org (key name == org name, matching repos[].org) - see `scripts/manage-github-tokens.sh`. Mutually exclusive with `tokens`. |
| github.secretName | string | `""` | Name of the Secret the chart creates when `tokens` is set. Defaults to "<release>-cc-rc-github-tokens" when left empty. |
| github.tokens | object | `{}` | Map of org name -> GitHub PAT. Chart creates a Secret from this map (one key per org, keyed by org name) if set. Fine for quick testing, but for anything long-lived prefer `existingSecret` plus `scripts/manage-github-tokens.sh`, which keeps tokens out of values.yaml/git entirely. |
| image | object | `{"pullPolicy":"Always","repository":"ghcr.io/vince-riv/cc-rc","tag":"latest"}` | Image for the per-repo agent StatefulSets |
| networkPolicy | object | `{"dns":{"namespace":"kube-system","podSelector":{"k8s-app":"kube-dns"},"port":53},"enabled":true}` | NetworkPolicy that denies all egress from per-repo agent pods except to the squid proxy Service and to cluster DNS. Never applied to the squid Deployment's own pods, which keep unrestricted egress. |
| networkPolicy.dns.namespace | string | `"kube-system"` | Namespace running the cluster's DNS resolver. |
| networkPolicy.dns.podSelector | object | `{"k8s-app":"kube-dns"}` | Label selector matching the DNS resolver pods. Varies by distro/cluster (kubeadm/k3s/EKS default to k8s-app=kube-dns; some CoreDNS installs use k8s-app=coredns instead). |
| nodeSelector | object | `{}` | Default nodeSelector for every per-repo agent StatefulSet. Override per-repo via `repos[].nodeSelector` (full replace, not merged with this default). |
| podFsGroup | int | `1000` | Group ID applied via pod securityContext.fsGroup so freshly-mounted PVCs are writable by the image's non-root `dev` user (created via `useradd -m`, uid/gid 1000). |
| proxy | object | `{"affinity":{},"allowList":[],"allowedPortsWhenOpen":[80,443,8080,8443,3000,5000,8000,9000],"defaultBlocked":["cluster.local","192.168.0.0/16","10.0.0.0/8","172.16.0.0/12"],"denyList":[],"image":{"pullPolicy":"IfNotPresent","repository":"ubuntu/squid","tag":"7.2-26.04_edge"},"nodeSelector":{},"podDisruptionBudget":{"enabled":false,"minAvailable":1},"probes":{"quiet":true},"replicaCount":1,"resources":{},"revisionHistoryLimit":5,"service":{"port":3128,"type":"ClusterIP"},"tolerations":[]}` | Squid egress proxy configuration. |
| proxy.affinity | object | `{}` | affinity for the squid Deployment. When left empty AND replicaCount > 1, a preferred podAntiAffinity (topologyKey: kubernetes.io/hostname) is generated automatically, spreading squid replicas across nodes. Set this explicitly to take full control instead (it's used as-is, replacing that auto-generation). |
| proxy.allowList | list | `[]` | Destinations agents are allowed to reach. Each entry is either a domain (e.g. "example.com", or ".example.com" to also match subdomains) or a CIDR (detected by the presence of "/", e.g. "140.82.112.0/20").  When EMPTY: all web traffic is permitted (subject to denyList/defaultBlocked below), on the ports listed in allowedPortsWhenOpen, plus github.com:22 for git+ssh. When NON-EMPTY: only these destinations are reachable (on ports 80/443), plus github.com:22 for git+ssh - that carve-out applies in BOTH modes (agents always clone/push over SSH, tunneled through squid; see sshKey above), unless github.com is itself in denyList. |
| proxy.allowedPortsWhenOpen | list | `[80,443,8080,8443,3000,5000,8000,9000]` | Ports permitted for any destination when allowList is EMPTY (open-web mode). Ignored in strict allow-list mode (only 80/443 are opened there). |
| proxy.defaultBlocked | list | `["cluster.local","192.168.0.0/16","10.0.0.0/8","172.16.0.0/12"]` | Baked-in destinations that are ALWAYS blocked on top of denyList. Not intended to be overridden — these protect cluster-internal networks. |
| proxy.denyList | list | `[]` | Destinations that are always blocked, regardless of allow-list mode. Takes precedence over allowList and over the github.com:22 git+ssh carve-out. |
| proxy.nodeSelector | object | `{}` | nodeSelector for the squid Deployment. |
| proxy.podDisruptionBudget | object | `{"enabled":false,"minAvailable":1}` | PodDisruptionBudget for the squid Deployment. Only created when `enabled` is true AND `replicaCount` > 1 (a PDB with a single replica just blocks voluntary eviction of the only pod). |
| proxy.podDisruptionBudget.minAvailable | int | `1` | minAvailable, per the same semantics as PodDisruptionBudgetSpec.minAvailable. |
| proxy.probes | object | `{"quiet":true}` | Readiness/liveness probe behavior. The startup probe always uses tcpSocket, regardless of this setting. |
| proxy.probes.quiet | bool | `true` | When true (default), readiness/liveness probes check for a LISTEN socket via /proc/net/tcp[6] instead of connecting - squid can't log a connection it never saw, so this keeps NONE_NONE/000 error:transaction-end-before-headers noise out of the access log. This is a weaker check than tcpSocket: it confirms squid is listening, not that it's actually accepting connections. Set to false to use tcpSocket instead, at the cost of that log noise on every probe. |
| proxy.revisionHistoryLimit | int | `5` | Number of old ReplicaSets to keep for rollback (Deployment's revisionHistoryLimit). |
| proxy.tolerations | list | `[]` | tolerations for the squid Deployment. |
| remoteControl | object | `{"capacity":8,"firstBootTimeoutSeconds":900,"permissionMode":"bypassPermissions","spawn":"worktree","unhealthyTimeoutSeconds":45,"worktreeMaxAgeDays":10}` | Defaults for the `claude remote-control` invocation each agent runs once login is complete (see the seed-home/clone-repo init containers and the agent container's startup logic). Any of these can be overridden per-repo via `repos[].remoteControl`. |
| remoteControl.firstBootTimeoutSeconds | int | `900` | Seconds to wait, on first boot (no login-complete marker yet), for a human to finish `claude`'s /login flow before the agent container exits and the pod restarts to retry. Much longer than unhealthyTimeoutSeconds since it's bounding an interactive human step, not a crash. |
| remoteControl.unhealthyTimeoutSeconds | int | `45` | Seconds `claude remote-control` may be down (never started, or crashed) before the agent container exits, restarting the pod. Kept fairly short by default so a genuine crash self-heals promptly; raise it (e.g. via --set) while debugging a startup failure, since it's also the window you have to `kubectl exec` in and inspect before the container cycles. |
| remoteControl.worktreeMaxAgeDays | int | `10` | Days of inactivity (no transcript writes) before a `.claude/worktrees/` checkout is removed via `git worktree remove`. Checked once per boot, before remote-control starts. |
| repos | list | `[]` | One StatefulSet is created per entry. `org`/`repo` are the GitHub org and repo name. Optional per-entry `resources`, `storage`, and `remoteControl` override the defaults below. `resources` is deep-merged over the top-level `resources` default, so a repo can override just cpu or just memory without having to repeat the other. `nodeSelector`/`affinity`, if set, fully replace (not merge with) the top-level `nodeSelector`/`affinity` defaults for that repo's StatefulSet. |
| resources | object | `{}` | Default container resources for the per-repo agent container. Empty means no requests/limits are set. |
| revisionHistoryLimit | int | `5` | Number of old ControllerRevisions to keep for rollback (StatefulSet's revisionHistoryLimit) for each per-repo agent StatefulSet. |
| sshKey | object | `{"enabled":true,"keyTitle":"cc-rc","resources":{},"secretName":"","tokenOrg":""}` | ED25519 SSH deploy key, generated once by a pre-install/pre-upgrade hook Job and added to a GitHub account (via `gh api /user/keys` - that account's PAT needs the `write:public_key` scope). Every per-repo agent then clones/pushes over SSH using this key instead of an HTTPS URL with an embedded token. SSH keys are account-level, not org-scoped, so ONE key is generated and shared across every repos[] entry - it just needs registering with a token from an account that can reach all of them. |
| sshKey.enabled | bool | `true` | Set false to skip the key-generation Job (e.g. you manage `secretName` yourself out of band). Per-repo agents always clone over SSH and expect `secretName` to hold `id_ed25519`/`id_ed25519.pub` either way. |
| sshKey.keyTitle | string | `"cc-rc"` | Title shown for this key under the GitHub account's SSH keys settings. |
| sshKey.resources | object | `{}` | Container resources for the key-generation Job. |
| sshKey.secretName | string | `""` | Name of the Secret holding the generated key. The Job creates it only if it doesn't already exist, and is a no-op otherwise. Defaults to "<release>-cc-rc-ssh-key" when left empty. |
| sshKey.tokenOrg | string | `""` | Which org's PAT (a key in the github Secret) to use when registering the deploy key. Defaults to repos[0].org when left empty - only matters if your orgs' tokens belong to different GitHub accounts, since the "right" one has to be able to see every repo you want the shared key to reach. |
| storage | object | `{"homeSize":"5Gi","storageClassName":"","workspaceSize":"5Gi"}` | Default persistent volume sizes for each per-repo agent. |
| storage.homeSize | string | `"5Gi"` | Size of the PVC mounted at /home/dev (the dev user's entire home directory — claude config/credentials, shell history, etc. — not just ~/.claude). |
| storage.storageClassName | string | `""` | StorageClass for both PVCs. "" uses the cluster default. |
| storage.workspaceSize | string | `"5Gi"` | Size of the PVC mounted at /workspace |
| terminationGracePeriodSeconds | int | `60` | Seconds kubelet waits after sending SIGTERM before sending SIGKILL to the agent container. Raised above Kubernetes' 30s default so claude has real time to exit cleanly (agent-entrypoint.sh forwards SIGINT to it on SIGTERM) rather than getting killed mid-write and leaving a worktree locked. |
| tolerations | list | `[]` | Default tolerations for every per-repo agent StatefulSet. Override per-repo via `repos[].tolerations` (full replace, not merged with this default). |

## Rendering and testing locally

```sh
helm lint charts/cc-rc
helm template cc-rc charts/cc-rc \
  --set repos[0].org=myorg --set repos[0].repo=myrepo \
  --set github.tokens.myorg=dummy \
  --set git.name="CI Bot" --set git.email=ci@example.com
helm unittest charts/cc-rc
```

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
