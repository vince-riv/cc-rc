# cc-rc

![Version: 0.0.0](https://img.shields.io/badge/Version-0.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.0](https://img.shields.io/badge/AppVersion-1.0.0-informational?style=flat-square)

Headless Claude Code remote-control agents (one StatefulSet per GitHub repo) behind a locked-down Squid egress proxy

Helm chart that runs headless [Claude Code](https://claude.ai/) agents, one per GitHub
repo, each behind a locked-down [Squid](https://www.squid-cache.org/) egress proxy.

## What it deploys

- A Squid `Deployment` + `Service`, configured from `values.yaml` (allow list / deny
  list / default-blocked cluster-internal ranges). This is the only workload in the
  chart with unrestricted egress.
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
  - a `clone-repo` init container that clones the repo into `/workspace/repo` (skipped
    if already cloned)
  - `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (+ lowercase variants) pointed at the Squid
    `Service`, and `GH_TOKEN` from a `Secret`
  - a startup script that runs `claude` in a `screen` session: see
    "Claude login and remote-control" below
- A `NetworkPolicy` that denies all egress from the agent `StatefulSet` pods except to
  the Squid `Service` and to cluster DNS.
- A `ConfigMap` rendering `~/.gitconfig` and `~/.gitignore_global` for the `dev` user,
  mounted read-only into every agent.
- A `ConfigMap` holding the `seed-home`/`clone-repo`/agent-entrypoint scripts
  (`charts/cc-rc/files/scripts/`), mounted read-only at `/opt/cc-rc/scripts` rather
  than baked into the image — so a custom `image.repository`/`image.tag` only needs to
  provide the underlying tools (`claude`, `screen`, `git`, `rsync`), not this
  orchestration logic. A `checksum/scripts` pod annotation rolls the `StatefulSet`s on
  any script change.

## Installing

Published releases (see `.github/workflows/chart-release.yml`) are pushed to GHCR as an
OCI artifact:

```sh
helm install cc-rc oci://ghcr.io/vince-riv/charts/cc-rc --version 0.1.0 \
  --set repos[0].org=myorg --set repos[0].repo=myrepo \
  --set github.token=ghp_... \
  --set git.name="CI Bot" --set git.email=ci@example.com
```

They're also published to the gh-pages-backed Helm repo at
`https://vince-riv.github.io/cc-rc/`:

```sh
helm repo add cc-rc https://vince-riv.github.io/cc-rc/
helm repo update
helm install cc-rc cc-rc/cc-rc --version 0.1.0 \
  --set repos[0].org=myorg --set repos[0].repo=myrepo \
  --set github.token=ghp_... \
  --set git.name="CI Bot" --set git.email=ci@example.com
```

## Configuring GitHub auth

Set exactly one of:

```yaml
github:
  token: "ghp_..."          # chart creates a Secret for you
# or
github:
  existingSecret: "my-secret"
  existingSecretKey: "token"  # defaults to "token"
```

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
every subsequent boot instead runs:

```sh
screen -L -Logfile /tmp/cc-rc-remote-control.log -dmS remote-control bash -lic 'cd /workspace/repo && claude remote-control --name <name> --permission-mode <mode> --spawn <mode> --capacity <n>'
```

`--name` defaults to the pod's hostname (e.g. `cc-rc-myorg-myrepo-0`) unless
`repos[].remoteControl.name` is set. `--permission-mode`, `--spawn`, `--capacity`, and
both timeouts below come from `remoteControl.*` (global defaults) or
`repos[].remoteControl.*` (per-repo override):

```yaml
remoteControl:
  permissionMode: bypassPermissions   # acceptEdits | auto | bypassPermissions | default | dontAsk | plan
  spawn: worktree                     # same-dir | worktree | session
  capacity: 8
  unhealthyTimeoutSeconds: 45         # steady-state: how long remote-control may be down before restarting
  firstBootTimeoutSeconds: 900        # first boot: how long to wait for a human to finish /login
```

The container's readiness probe checks for a running `claude remote-control` process
directly (no grace period). There's deliberately no `livenessProbe`: the agent
container manages its own exit-on-unhealthy instead, so `unhealthyTimeoutSeconds` is
actually honored rather than being pre-empted by kubelet on its own schedule — the
container exits (triggering a restart) once the process has been down that long.
Raise it (e.g. `--set remoteControl.unhealthyTimeoutSeconds=600`) to get more time to
`kubectl exec -it <pod> -- bash` in and debug a startup failure — the tailed log and
`screen -r remote-control` both stay attachable throughout that window.

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
80/443) are reachable. There is **no** automatic `github.com:22` carve-out in strict
mode — add `github.com` to `proxy.allowList` yourself if you need it there.
`proxy.denyList` always wins over `proxy.allowList`.

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
| github | object | `{"existingSecret":"","existingSecretKey":"token","secretKey":"token","secretName":"cc-rc-github-token","token":""}` | GitHub auth for cloning repos and for the `gh`/`git` CLIs inside each agent. Set EXACTLY ONE of `token` or `existingSecret`. |
| github.existingSecret | string | `""` | Name of a pre-existing Secret to use instead of `token`. Mutually exclusive with `token`. |
| github.existingSecretKey | string | `"token"` | Key within `existingSecret` that holds the token. |
| github.secretKey | string | `"token"` | Key used inside the chart-managed Secret. |
| github.secretName | string | `"cc-rc-github-token"` | Name of the Secret the chart creates when `token` is set. |
| github.token | string | `""` | Set this to a GitHub PAT to have the chart create a Secret for you. |
| image | object | `{"pullPolicy":"Always","repository":"ghcr.io/vince-riv/cc-rc","tag":"latest"}` | Image for the per-repo agent StatefulSets |
| networkPolicy | object | `{"dns":{"namespace":"kube-system","podSelector":{"k8s-app":"kube-dns"},"port":53},"enabled":true}` | NetworkPolicy that denies all egress from per-repo agent pods except to the squid proxy Service and to cluster DNS. Never applied to the squid Deployment's own pods, which keep unrestricted egress. |
| networkPolicy.dns.namespace | string | `"kube-system"` | Namespace running the cluster's DNS resolver. |
| networkPolicy.dns.podSelector | object | `{"k8s-app":"kube-dns"}` | Label selector matching the DNS resolver pods. Varies by distro/cluster (kubeadm/k3s/EKS default to k8s-app=kube-dns; some CoreDNS installs use k8s-app=coredns instead). |
| nodeSelector | object | `{}` | Default nodeSelector for every per-repo agent StatefulSet. Override per-repo via `repos[].nodeSelector` (full replace, not merged with this default). |
| podFsGroup | int | `1000` | Group ID applied via pod securityContext.fsGroup so freshly-mounted PVCs are writable by the image's non-root `dev` user (created via `useradd -m`, uid/gid 1000). |
| proxy | object | `{"affinity":{},"allowList":[],"allowedPortsWhenOpen":[80,443,8080,8443,3000,5000,8000,9000],"defaultBlocked":["cluster.local","192.168.0.0/16","10.0.0.0/8","172.16.0.0/12"],"denyList":[],"image":{"pullPolicy":"IfNotPresent","repository":"ubuntu/squid","tag":"7.2-26.04_edge"},"nodeSelector":{},"podDisruptionBudget":{"enabled":false,"minAvailable":1},"probes":{"quiet":true},"replicaCount":1,"resources":{},"revisionHistoryLimit":5,"service":{"port":3128,"type":"ClusterIP"},"tolerations":[]}` | Squid egress proxy configuration. |
| proxy.affinity | object | `{}` | affinity for the squid Deployment. When left empty AND replicaCount > 1, a preferred podAntiAffinity (topologyKey: kubernetes.io/hostname) is generated automatically, spreading squid replicas across nodes. Set this explicitly to take full control instead (it's used as-is, replacing that auto-generation). |
| proxy.allowList | list | `[]` | Destinations agents are allowed to reach. Each entry is either a domain (e.g. "example.com", or ".example.com" to also match subdomains) or a CIDR (detected by the presence of "/", e.g. "140.82.112.0/20").  When EMPTY: all web traffic is permitted (subject to denyList/defaultBlocked below), on the ports listed in allowedPortsWhenOpen, plus github.com:22 for git+ssh. When NON-EMPTY: only these destinations are reachable (on ports 80/443). There is NO automatic github.com:22 carve-out in this mode — add github.com yourself if ssh access to it is needed. |
| proxy.allowedPortsWhenOpen | list | `[80,443,8080,8443,3000,5000,8000,9000]` | Ports permitted for any destination when allowList is EMPTY (open-web mode). Ignored in strict allow-list mode (only 80/443 are opened there). |
| proxy.defaultBlocked | list | `["cluster.local","192.168.0.0/16","10.0.0.0/8","172.16.0.0/12"]` | Baked-in destinations that are ALWAYS blocked on top of denyList. Not intended to be overridden — these protect cluster-internal networks. |
| proxy.denyList | list | `[]` | Destinations that are always blocked, regardless of allow-list mode. Takes precedence over allowList and over the open-web-mode github.com:22 rule. |
| proxy.nodeSelector | object | `{}` | nodeSelector for the squid Deployment. |
| proxy.podDisruptionBudget | object | `{"enabled":false,"minAvailable":1}` | PodDisruptionBudget for the squid Deployment. Only created when `enabled` is true AND `replicaCount` > 1 (a PDB with a single replica just blocks voluntary eviction of the only pod). |
| proxy.podDisruptionBudget.minAvailable | int | `1` | minAvailable, per the same semantics as PodDisruptionBudgetSpec.minAvailable. |
| proxy.probes | object | `{"quiet":true}` | Readiness/liveness probe behavior. The startup probe always uses tcpSocket, regardless of this setting. |
| proxy.probes.quiet | bool | `true` | When true (default), readiness/liveness probes check for a LISTEN socket via /proc/net/tcp[6] instead of connecting - squid can't log a connection it never saw, so this keeps NONE_NONE/000 error:transaction-end-before-headers noise out of the access log. This is a weaker check than tcpSocket: it confirms squid is listening, not that it's actually accepting connections. Set to false to use tcpSocket instead, at the cost of that log noise on every probe. |
| proxy.revisionHistoryLimit | int | `5` | Number of old ReplicaSets to keep for rollback (Deployment's revisionHistoryLimit). |
| proxy.tolerations | list | `[]` | tolerations for the squid Deployment. |
| remoteControl | object | `{"capacity":8,"firstBootTimeoutSeconds":900,"permissionMode":"bypassPermissions","spawn":"worktree","unhealthyTimeoutSeconds":45}` | Defaults for the `claude remote-control` invocation each agent runs once login is complete (see the seed-home/clone-repo init containers and the agent container's startup logic). Any of these can be overridden per-repo via `repos[].remoteControl`. |
| remoteControl.firstBootTimeoutSeconds | int | `900` | Seconds to wait, on first boot (no login-complete marker yet), for a human to finish `claude`'s /login flow before the agent container exits and the pod restarts to retry. Much longer than unhealthyTimeoutSeconds since it's bounding an interactive human step, not a crash. |
| remoteControl.unhealthyTimeoutSeconds | int | `45` | Seconds `claude remote-control` may be down (never started, or crashed) before the agent container exits, restarting the pod. Kept fairly short by default so a genuine crash self-heals promptly; raise it (e.g. via --set) while debugging a startup failure, since it's also the window you have to `kubectl exec` in and inspect before the container cycles. |
| repos | list | `[]` | One StatefulSet is created per entry. `org`/`repo` are the GitHub org and repo name. Optional per-entry `resources`, `storage`, and `remoteControl` override the defaults below. `resources` is deep-merged over the top-level `resources` default, so a repo can override just cpu or just memory without having to repeat the other. `nodeSelector`/`affinity`, if set, fully replace (not merge with) the top-level `nodeSelector`/`affinity` defaults for that repo's StatefulSet. |
| resources | object | `{}` | Default container resources for the per-repo agent container. Empty means no requests/limits are set. |
| revisionHistoryLimit | int | `5` | Number of old ControllerRevisions to keep for rollback (StatefulSet's revisionHistoryLimit) for each per-repo agent StatefulSet. |
| storage | object | `{"homeSize":"5Gi","storageClassName":"","workspaceSize":"5Gi"}` | Default persistent volume sizes for each per-repo agent. |
| storage.homeSize | string | `"5Gi"` | Size of the PVC mounted at /home/dev (the dev user's entire home directory — claude config/credentials, shell history, etc. — not just ~/.claude). |
| storage.storageClassName | string | `""` | StorageClass for both PVCs. "" uses the cluster default. |
| storage.workspaceSize | string | `"5Gi"` | Size of the PVC mounted at /workspace |
| tolerations | list | `[]` | Default tolerations for every per-repo agent StatefulSet. Override per-repo via `repos[].tolerations` (full replace, not merged with this default). |

## Rendering and testing locally

```sh
helm lint charts/cc-rc
helm template cc-rc charts/cc-rc \
  --set repos[0].org=myorg --set repos[0].repo=myrepo \
  --set github.token=dummy \
  --set git.name="CI Bot" --set git.email=ci@example.com
helm unittest charts/cc-rc
```

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
