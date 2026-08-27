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
Label and annotation keys the chart owns. User-supplied extra labels/annotations
(labels/annotations/podLabels/podAnnotations, their proxy.* equivalents, and the
repos[] per-repo overrides) are merged UNDER these, so a user value can never
silently change a pod selector (immutable after creation), the standard
app.kubernetes.io/* set, or the config-checksum annotations that trigger a
rollout when a ConfigMap changes. cc-rc.validateExtraMeta rejects such a key up
front rather than quietly ignoring it.
*/}}
{{- define "cc-rc.reservedMetaKeys" -}}
- app.kubernetes.io/name
- app.kubernetes.io/instance
- app.kubernetes.io/managed-by
- app.kubernetes.io/component
- helm.sh/chart
- cc-rc.io/org
- cc-rc.io/repo
- checksum/config
- checksum/scripts
{{- end -}}

{{/*
Fail the render if a user-supplied label/annotation map sets a chart-owned key.
Pass `values` (the map) and `path` (its values.yaml path, for the message).
*/}}
{{- define "cc-rc.validateExtraMeta" -}}
{{- $reserved := fromYamlArray (include "cc-rc.reservedMetaKeys" .) -}}
{{- $path := .path -}}
{{- range $k, $v := (.values | default dict) -}}
{{- if has $k $reserved -}}
{{ fail (printf "%s may not set %q - the chart owns that key (pod selectors, the app.kubernetes.io/* set, and config checksums). Remove it." $path $k) }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Render `base` (chart-owned) merged over `extra` (user-supplied) as YAML.
Chart-owned keys always win. Emits "{}" when both are empty, so callers should
only include this where an empty map is acceptable, or guard it themselves.
*/}}
{{- define "cc-rc.mergedMeta" -}}
{{- toYaml (merge (deepCopy (.base | default dict)) (deepCopy (.extra | default dict))) -}}
{{- end -}}

{{/*
Chart-owned labels for the squid Deployment and its pods.
*/}}
{{- define "cc-rc.squidChartLabels" -}}
{{- merge (dict "app.kubernetes.io/component" "proxy") (fromYaml (include "cc-rc.labels" .)) | toYaml -}}
{{- end -}}

{{/*
Object-level labels for the squid Deployment: chart labels plus proxy.labels.
*/}}
{{- define "cc-rc.squidLabels" -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" .Values.proxy.labels "path" "proxy.labels") -}}
{{- include "cc-rc.mergedMeta" (dict "base" (fromYaml (include "cc-rc.squidChartLabels" .)) "extra" .Values.proxy.labels) -}}
{{- end -}}

{{/*
Pod-level labels for the squid Deployment: chart labels plus proxy.podLabels.
*/}}
{{- define "cc-rc.squidPodLabels" -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" .Values.proxy.podLabels "path" "proxy.podLabels") -}}
{{- include "cc-rc.mergedMeta" (dict "base" (fromYaml (include "cc-rc.squidChartLabels" .)) "extra" .Values.proxy.podLabels) -}}
{{- end -}}

{{/*
Pod-level annotations for the squid Deployment: the squid.conf checksum (which
rolls the Deployment whenever the rendered config changes) plus
proxy.podAnnotations.
*/}}
{{- define "cc-rc.squidPodAnnotations" -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" .Values.proxy.podAnnotations "path" "proxy.podAnnotations") -}}
{{- $base := dict "checksum/config" (include (print .Template.BasePath "/configmap-squid.yaml") . | sha256sum) -}}
{{- include "cc-rc.mergedMeta" (dict "base" $base "extra" .Values.proxy.podAnnotations) -}}
{{- end -}}

{{/*
Effective extra labels/annotations for ONE per-repo agent, as YAML: the per-repo
map (repos[].<key>) merged over the top-level default (<key>), per key - so a
repo can add a single entry without repeating the shared set, the same way
repos[].resources deep-merges over resources. Pass `root`, `repo`, and `key`
(one of labels, annotations, podLabels, podAnnotations).
*/}}
{{- define "cc-rc.agentExtraMeta" -}}
{{- $global := (index .root.Values .key) | default dict -}}
{{- $perRepo := (index (.repo | default dict) .key) | default dict -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" $global "path" .key) -}}
{{- include "cc-rc.validateExtraMeta" (dict "values" $perRepo "path" (printf "repos[].%s" .key)) -}}
{{- toYaml (merge (deepCopy $perRepo) (deepCopy $global)) -}}
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
