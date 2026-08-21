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
Name of the Secret holding GH_TOKEN, whether chart-managed or pre-existing.
Falls back to "<fullname>-github-token" when github.secretName is unset.
*/}}
{{- define "cc-rc.githubSecretName" -}}
{{- .Values.github.existingSecret | default (.Values.github.secretName | default (printf "%s-github-token" (include "cc-rc.fullname" .))) -}}
{{- end -}}

{{/*
Key within the GH_TOKEN Secret, whether chart-managed or pre-existing.
*/}}
{{- define "cc-rc.githubSecretKey" -}}
{{- if .Values.github.existingSecret -}}
{{- .Values.github.existingSecretKey -}}
{{- else -}}
{{- .Values.github.secretKey -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding the SSH deploy key. Falls back to
"<fullname>-ssh-key" when sshKey.secretName is unset.
*/}}
{{- define "cc-rc.sshKeySecretName" -}}
{{- .Values.sshKey.secretName | default (printf "%s-ssh-key" (include "cc-rc.fullname" .)) -}}
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
{{- if and .Values.github.token .Values.github.existingSecret -}}
{{ fail "github.token and github.existingSecret are mutually exclusive; set only one." }}
{{- end -}}
{{- if not (or .Values.github.token .Values.github.existingSecret) -}}
{{ fail "one of github.token or github.existingSecret must be set." }}
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
