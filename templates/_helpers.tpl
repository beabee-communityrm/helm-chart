{{/*
Fully qualified app name. Releases are always named beabee-<tenant>, so the
release name is the name — just enforce the k8s 63-char limit.
*/}}
{{- define "beabee.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
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
Name of the tenant's env secret. Always env-<release> (the SOPS convention).
*/}}
{{- define "beabee.secretName" -}}
env-{{ include "beabee.fullname" . }}
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
