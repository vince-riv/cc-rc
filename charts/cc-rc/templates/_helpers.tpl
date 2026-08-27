{{/*
Chart name.
*/}}
{{- define "cc-rc.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
*/}}
{{- define "cc-rc.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart label value.
*/}}
{{- define "cc-rc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "cc-rc.labels" -}}
helm.sh/chart: {{ include "cc-rc.chart" . }}
{{ include "cc-rc.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels.
*/}}
{{- define "cc-rc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cc-rc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Sanitize an {org, repo} dict into an RFC1123-safe slug, truncated to keep the
resulting StatefulSet name (plus "-0" ordinal and PVC-template prefixes) under
the 63-char DNS label limit.
*/}}
{{- define "cc-rc.repoSlug" -}}
{{- $raw := printf "%s-%s" .org .repo | lower -}}
{{- $s := regexReplaceAll "[^a-z0-9-]+" $raw "-" | trimAll "-" -}}
{{- if gt (len $s) 40 -}}
{{- $s = substr 0 40 $s | trimAll "-" -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{/*
Name of the Secret holding one GH_TOKEN per org, whether chart-managed or
pre-existing. Falls back to "<fullname>-github-tokens" when github.secretName
is unset. The key to read within it is always the org name itself (see
cc-rc.validateGithubAuth) - there's no separate "secretKey" concept anymore,
since one token per org means the org name IS the key.
*/}}
{{- define "cc-rc.githubSecretName" -}}
{{- .Values.github.existingSecret | default (.Values.github.secretName | default (printf "%s-github-tokens" (include "cc-rc.fullname" .))) -}}
{{- end -}}

{{/*
Name of the Secret holding the SSH deploy key. Falls back to
"<fullname>-ssh-key" when sshKey.secretName is unset.
*/}}
{{- define "cc-rc.sshKeySecretName" -}}
{{- .Values.sshKey.secretName | default (printf "%s-ssh-key" (include "cc-rc.fullname" .)) -}}
{{- end -}}

{{/*
Which org's PAT (a key in the github Secret) the sshKey Job registers the
deploy key with - sshKey.tokenOrg if set, else repos[0].org.
*/}}
{{- define "cc-rc.sshKeyTokenOrg" -}}
{{- .Values.sshKey.tokenOrg | default (first .Values.repos).org -}}
{{- end -}}

{{/*
Fully qualified squid Service name.
*/}}
{{- define "cc-rc.squidServiceName" -}}
{{- printf "%s-squid" (include "cc-rc.fullname" .) -}}
{{- end -}}

{{/*
Preferred podAntiAffinity spreading squid replicas across nodes, keyed on the
proxy selector labels. Only meant to be used when proxy.affinity is empty and
proxy.replicaCount > 1 - explicit proxy.affinity always takes precedence.
*/}}
{{- define "cc-rc.squidAntiAffinity" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            {{- include "cc-rc.selectorLabels" . | nindent 12 }}
            app.kubernetes.io/component: proxy
{{- end -}}

{{/*
Validate github token configuration. Call from any template that needs the
Secret to exist (fails the whole render if misconfigured).
*/}}
{{- define "cc-rc.validateGithubAuth" -}}
{{- if and .Values.github.tokens .Values.github.existingSecret -}}
{{ fail "github.tokens and github.existingSecret are mutually exclusive; set only one." }}
{{- end -}}
{{- if not (or .Values.github.tokens .Values.github.existingSecret) -}}
{{ fail "one of github.tokens or github.existingSecret must be set." }}
{{- end -}}
{{- /* Only checkable for the chart-managed Secret - an existingSecret's
   keys aren't known at render time, so this can't validate that case. */ -}}
{{- if .Values.github.tokens -}}
{{- range .Values.repos -}}
{{- if not (hasKey $.Values.github.tokens .org) -}}
{{ fail (printf "github.tokens has no entry for org %q (used by repos[]) - add one, or set github.existingSecret to a Secret with that key instead." .org) }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate git identity configuration. Call from any template that needs
the .gitconfig ConfigMap to exist (fails the whole render if unset).
*/}}
{{- define "cc-rc.validateGitIdentity" -}}
{{- if not .Values.git.name -}}
{{ fail "git.name must be set (the commit identity used inside each agent)." }}
{{- end -}}
{{- if not .Values.git.email -}}
{{ fail "git.email must be set (the commit identity used inside each agent)." }}
{{- end -}}
{{- end -}}

{{/*
Validate remoteControl.permissionMode/spawn, both the top-level defaults and
any per-repo overrides, against claude remote-control's accepted values.
*/}}
{{- define "cc-rc.validateRemoteControl" -}}
{{- $permissionModes := list "acceptEdits" "auto" "bypassPermissions" "default" "dontAsk" "plan" -}}
{{- $spawnModes := list "same-dir" "worktree" "session" -}}
{{- if not (has .Values.remoteControl.permissionMode $permissionModes) -}}
{{ fail (printf "remoteControl.permissionMode must be one of %s; got %q" (join ", " $permissionModes) .Values.remoteControl.permissionMode) }}
{{- end -}}
{{- if not (has .Values.remoteControl.spawn $spawnModes) -}}
{{ fail (printf "remoteControl.spawn must be one of %s; got %q" (join ", " $spawnModes) .Values.remoteControl.spawn) }}
{{- end -}}
{{- range .Values.repos -}}
{{- $rc := .remoteControl | default dict -}}
{{- if $rc.permissionMode -}}
{{- if not (has $rc.permissionMode $permissionModes) -}}
{{ fail (printf "repos[].remoteControl.permissionMode must be one of %s; got %q" (join ", " $permissionModes) $rc.permissionMode) }}
{{- end -}}
{{- end -}}
{{- if $rc.spawn -}}
{{- if not (has $rc.spawn $spawnModes) -}}
{{ fail (printf "repos[].remoteControl.spawn must be one of %s; got %q" (join ", " $spawnModes) $rc.spawn) }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Fail the render if a user-supplied label/annotation map sets a key the chart
already emits in that same slot. Such a key always loses the merge in
cc-rc.mergedMeta, so accepting it silently would leave the user with a value
that has no effect - and, for the pod-selector labels, an apparent way to break
an immutable field. Pass `values` (the user map), `path` (its values.yaml path,
for the message) and `reserved` (the list of chart-owned keys for that slot).
*/}}
{{- define "cc-rc.validateExtraMeta" -}}
{{- $reserved := .reserved -}}
{{- $path := .path -}}
{{- range $k, $v := (.values | default dict) -}}
{{- if has $k $reserved -}}
{{ fail (printf "%s may not set %q - the chart owns that key and always wins the merge, so setting it here would have no effect. Remove it." $path $k) }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Render `base` (chart-owned) merged over `extra` (user-supplied) as YAML.
Chart-owned keys always win. Every value is coerced to a string on the way out:
labels and annotations are string-valued in the Kubernetes API, so an unquoted
`version: 3` or `prometheus.io/scrape: true` in values.yaml would otherwise
render as an int/bool and be rejected by the API server at apply time. (A YAML
float like `2.0` still loses its trailing zero - that happens when values.yaml
is parsed, before the chart sees it, so quote such values at the source.)
Emits "{}" when both maps are empty, so callers must guard that themselves if
an empty metadata block would be wrong.
*/}}
{{- define "cc-rc.mergedMeta" -}}
{{- $merged := merge (deepCopy (.base | default dict)) (deepCopy (.extra | default dict)) -}}
{{- $out := dict -}}
{{- range $k, $v := $merged -}}
{{- $_ := set $out $k (printf "%v" $v) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Chart-owned labels for the squid Deployment and its pods.
*/}}
{{- define "cc-rc.squidChartLabels" -}}
{{- merge (dict "app.kubernetes.io/component" "proxy") (fromYaml (include "cc-rc.labels" .)) | toYaml -}}
{{- end -}}

{{/*
Chart-owned annotation keys on the squid pods: the squid.conf checksum that
rolls the Deployment whenever the rendered config changes. The Deployment
object itself carries no chart-owned annotations, so proxy.annotations has
nothing to collide with and is not validated against anything.
*/}}
{{- define "cc-rc.squidReservedPodAnnotations" -}}
- checksum/config
{{- end -}}

{{/*
Object-level labels for the squid Deployment: chart labels plus proxy.labels.
*/}}
{{- define "cc-rc.squidLabels" -}}
{{- $chart := fromYaml (include "cc-rc.squidChartLabels" .) -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" .Values.proxy.labels "path" "proxy.labels" "reserved" (keys $chart)) -}}
{{- include "cc-rc.mergedMeta" (dict "base" $chart "extra" .Values.proxy.labels) -}}
{{- end -}}

{{/*
Pod-level labels for the squid Deployment: chart labels plus proxy.podLabels.
*/}}
{{- define "cc-rc.squidPodLabels" -}}
{{- $chart := fromYaml (include "cc-rc.squidChartLabels" .) -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" .Values.proxy.podLabels "path" "proxy.podLabels" "reserved" (keys $chart)) -}}
{{- include "cc-rc.mergedMeta" (dict "base" $chart "extra" .Values.proxy.podLabels) -}}
{{- end -}}

{{/*
Object-level annotations for the squid Deployment: proxy.annotations only.
*/}}
{{- define "cc-rc.squidAnnotations" -}}
{{- include "cc-rc.mergedMeta" (dict "base" (dict) "extra" .Values.proxy.annotations) -}}
{{- end -}}

{{/*
Pod-level annotations for the squid Deployment: the squid.conf checksum plus
proxy.podAnnotations.
*/}}
{{- define "cc-rc.squidPodAnnotations" -}}
{{- $reserved := fromYamlArray (include "cc-rc.squidReservedPodAnnotations" .) -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" .Values.proxy.podAnnotations "path" "proxy.podAnnotations" "reserved" $reserved) -}}
{{- $base := dict "checksum/config" (include (print .Template.BasePath "/configmap-squid.yaml") . | sha256sum) -}}
{{- include "cc-rc.mergedMeta" (dict "base" $base "extra" .Values.proxy.podAnnotations) -}}
{{- end -}}

{{/*
Chart-owned labels for one per-repo agent StatefulSet, its pods and its headless
Service. org/repo go through printf so a numeric-looking values.yaml entry still
renders as a string (label values must be strings).
*/}}
{{- define "cc-rc.agentChartLabels" -}}
{{- $identity := dict
      "app.kubernetes.io/component" "agent"
      "cc-rc.io/org" (printf "%v" .repo.org)
      "cc-rc.io/repo" (printf "%v" .repo.repo) -}}
{{- merge $identity (fromYaml (include "cc-rc.labels" .root)) | toYaml -}}
{{- end -}}

{{/*
Chart-owned annotation keys on a per-repo agent, by slot. The StatefulSet object
carries the ArgoCD sync-wave hint, which stays chart-controlled: it exists to
order the first sync after squid, so letting a user rewrite it would reintroduce
the race it was added to close. The pods carry the scripts-ConfigMap checksum
that rolls them when a mounted script changes.
*/}}
{{- define "cc-rc.agentReservedAnnotations" -}}
- argocd.argoproj.io/sync-wave
{{- end -}}
{{- define "cc-rc.agentReservedPodAnnotations" -}}
- checksum/scripts
{{- end -}}

{{/*
Effective extra labels/annotations for ONE per-repo agent, as YAML: the per-repo
map (repos[].<key>) merged over the top-level default (<key>), per key - so a
repo can add a single entry without repeating the shared set, the same way
repos[].resources deep-merges over resources. Pass `root`, `repo`, and `key`
(one of labels, annotations, podLabels, podAnnotations).

The chart-owned keys each slot is validated against are derived from what the
chart actually emits into that slot, rather than hard-coded, so renaming an
emitted label keeps this guard in step automatically.
*/}}
{{- define "cc-rc.agentExtraMeta" -}}
{{- $chartLabelKeys := keys (fromYaml (include "cc-rc.agentChartLabels" (dict "root" .root "repo" .repo))) -}}
{{- $reserved := index (dict
      "labels" $chartLabelKeys
      "podLabels" $chartLabelKeys
      "annotations" (fromYamlArray (include "cc-rc.agentReservedAnnotations" .))
      "podAnnotations" (fromYamlArray (include "cc-rc.agentReservedPodAnnotations" .))) .key -}}
{{- $global := (index .root.Values .key) | default dict -}}
{{- $perRepo := (index (.repo | default dict) .key) | default dict -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" $global "path" .key "reserved" $reserved) -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" $perRepo "path" (printf "repos[].%s" .key) "reserved" $reserved) -}}
{{- toYaml (merge (deepCopy $perRepo) (deepCopy $global)) -}}
{{- end -}}
