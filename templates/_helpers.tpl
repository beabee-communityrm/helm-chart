{{/*
Create a default fully qualified app name.
If release name contains chart name it will be used as a full name.
*/}}
{{- define "beabee.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "beabee.labels" -}}
app: beabee
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels for a component. Call with dict "component" "xxx"
*/}}
{{- define "beabee.selectorLabels" -}}
app: beabee
component: {{ .component }}
{{- end }}

{{/*
Default secret name — falls back to the release name.
*/}}
{{- define "beabee.secretName" -}}
{{- default (printf "env-%s" (include "beabee.fullname" .)) .Values.secretName }}
{{- end }}

{{/*
Render secretRef overrides as env entries. Call from a container spec.
Explicit env entries override envFrom, so these win over the default secret.
*/}}
{{- define "beabee.secretRefEnv" -}}
{{- range $envVar, $ref := .Values.secretRefs }}
- name: {{ $envVar }}
  valueFrom:
    secretKeyRef:
      name: {{ $ref.name }}
      key: {{ default $envVar $ref.key }}
{{- end }}
{{- end }}
