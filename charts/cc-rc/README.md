# cc-rc

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: latest](https://img.shields.io/badge/AppVersion-latest-informational?style=flat-square)

Headless Claude Code remote-control agents (one StatefulSet per GitHub repo) behind a locked-down Squid egress proxy

Helm chart that runs headless [Claude Code](https://claude.ai/) agents, one per GitHub
repo, each behind a locked-down [Squid](https://www.squid-cache.org/) egress proxy.

## What it deploys

- A Squid `Deployment` + `Service`, configured from `values.yaml` (allow list / deny
  list / default-blocked cluster-internal ranges). This is the only workload in the
  chart with unrestricted egress.
- One `StatefulSet` (replicas: 1) per entry in `values.repos`, running the
  `ghcr.io/vince-riv/cc-rc` image. Each gets:
  - a 500Mi PVC mounted at `/home/dev/.claude`
  - a 5Gi PVC mounted at `/workspace`
  - an init container that clones the repo into `/workspace` (skipped if already cloned)
  - `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` (+ lowercase variants) pointed at the Squid
    `Service`, and `GH_TOKEN` from a `Secret`
- A `NetworkPolicy` that denies all egress from the agent `StatefulSet` pods except to
  the Squid `Service` and to cluster DNS.

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

## Configuring egress

`proxy.allowList` empty (default) = open-web mode: any destination is reachable on
`proxy.allowedPortsWhenOpen`, plus `github.com:22` for git+ssh, except `proxy.denyList`
and the baked-in cluster-internal ranges (`cluster.local`, `192.168.0.0/16`,
`10.0.0.0/8`, `172.16.0.0/12`).

Setting `proxy.allowList` switches to strict mode: only those domains/CIDRs (ports
80/443) are reachable. There is **no** automatic `github.com:22` carve-out in strict
mode — add `github.com` to `proxy.allowList` yourself if you need it there.
`proxy.denyList` always wins over `proxy.allowList`.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
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
| podFsGroup | int | `1000` | Group ID applied via pod securityContext.fsGroup so freshly-mounted PVCs are writable by the image's non-root `dev` user (created via `useradd -m`, uid/gid 1000). |
| proxy | object | `{"allowList":[],"allowedPortsWhenOpen":[80,443,8080,8443,3000,5000,8000,9000],"defaultBlocked":["cluster.local","192.168.0.0/16","10.0.0.0/8","172.16.0.0/12"],"denyList":[],"image":{"pullPolicy":"IfNotPresent","repository":"ubuntu/squid","tag":"7.2-26.04_edge"},"replicaCount":1,"resources":{},"service":{"port":3128,"type":"ClusterIP"}}` | Squid egress proxy configuration. |
| proxy.allowList | list | `[]` | Destinations agents are allowed to reach. Each entry is either a domain (e.g. "example.com", or ".example.com" to also match subdomains) or a CIDR (detected by the presence of "/", e.g. "140.82.112.0/20").  When EMPTY: all web traffic is permitted (subject to denyList/defaultBlocked below), on the ports listed in allowedPortsWhenOpen, plus github.com:22 for git+ssh. When NON-EMPTY: only these destinations are reachable (on ports 80/443). There is NO automatic github.com:22 carve-out in this mode — add github.com yourself if ssh access to it is needed. |
| proxy.allowedPortsWhenOpen | list | `[80,443,8080,8443,3000,5000,8000,9000]` | Ports permitted for any destination when allowList is EMPTY (open-web mode). Ignored in strict allow-list mode (only 80/443 are opened there). |
| proxy.defaultBlocked | list | `["cluster.local","192.168.0.0/16","10.0.0.0/8","172.16.0.0/12"]` | Baked-in destinations that are ALWAYS blocked on top of denyList. Not intended to be overridden — these protect cluster-internal networks. |
| proxy.denyList | list | `[]` | Destinations that are always blocked, regardless of allow-list mode. Takes precedence over allowList and over the open-web-mode github.com:22 rule. |
| repos | list | `[]` | One StatefulSet is created per entry. `org`/`repo` are the GitHub org and repo name. Optional per-entry `resources` and `storage` override the defaults below. `resources` is deep-merged over the top-level `resources` default, so a repo can override just cpu or just memory without having to repeat the other. |
| resources | object | `{}` | Default container resources for the per-repo agent container. Empty means no requests/limits are set. |
| storage | object | `{"claudeSize":"500Mi","storageClassName":"","workspaceSize":"5Gi"}` | Default persistent volume sizes for each per-repo agent. |
| storage.claudeSize | string | `"500Mi"` | Size of the PVC mounted at /home/dev/.claude |
| storage.storageClassName | string | `""` | StorageClass for both PVCs. "" uses the cluster default. |
| storage.workspaceSize | string | `"5Gi"` | Size of the PVC mounted at /workspace |

## Rendering and testing locally

```sh
helm lint charts/cc-rc
helm template cc-rc charts/cc-rc \
  --set repos[0].org=myorg --set repos[0].repo=myrepo \
  --set github.token=dummy
helm unittest charts/cc-rc
```

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
