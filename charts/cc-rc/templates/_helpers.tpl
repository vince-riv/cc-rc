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
*/}}
{{- define "cc-rc.githubSecretName" -}}
{{- .Values.github.existingSecret | default .Values.github.secretName -}}
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
Fully qualified squid Service name.
*/}}
{{- define "cc-rc.squidServiceName" -}}
{{- printf "%s-squid" (include "cc-rc.fullname" .) -}}
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
