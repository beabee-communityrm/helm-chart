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

{{/*
The tenant's Hive domain
*/}}
{{- define "beabee.hiveDomain" -}}
{{ .Values.hive.id }}.clients.hive.beabee.io
{{- end }}

{{/*
HIVE_SERVICE_* — in-cluster DNS of the service upstreams, as host-only URLs
(scheme + hostname, no port; each consumer appends the port it needs).
*/}}
{{- define "beabee.hiveServiceEnv" -}}
{{- $fullname := include "beabee.fullname" . -}}
{{- $suffix := printf "%s.svc.cluster.local" .Release.Namespace -}}
- name: HIVE_SERVICE_APP
  value: "http://{{ $fullname }}-legacy-app.{{ $suffix }}"
- name: HIVE_SERVICE_API_APP
  value: "http://{{ $fullname }}-api-app.{{ $suffix }}"
- name: HIVE_SERVICE_WEBHOOK_APP
  value: "http://{{ $fullname }}-webhook-app.{{ $suffix }}"
- name: HIVE_SERVICE_FRONTEND
  value: "http://{{ $fullname }}-frontend.{{ $suffix }}"
{{- end }}

{{/*
URL scheme for the tenant's public URLs — https, or http when hive.insecure
(local/testing over plain http).
*/}}
{{- define "beabee.scheme" -}}
{{- ternary "http" "https" .Values.hive.insecure -}}
{{- end }}

{{/*
Cookie domain: hive.domain with any port stripped — cookies can't carry a port.
*/}}
{{- define "beabee.cookieDomain" -}}
{{ .Values.hive.domain | splitList ":" | first }}
{{- end }}

{{/*
Name of the Secret the ZITADEL bootstrap hook writes the provisioned IDs to
(ISSUER, INSTANCE_ID, ORG_ID, PROJECT_ID, CLIENT_ID, OIDC_SCOPES).
*/}}
{{- define "beabee.zitadelSecretName" -}}
zitadel-{{ include "beabee.fullname" . }}
{{- end }}

{{/*
The tenant's ZITADEL virtual-instance name — zitadel.instanceName, or the
release name.
*/}}
{{- define "beabee.zitadelInstanceName" -}}
{{ .Values.zitadel.instanceName | default (include "beabee.fullname" .) }}
{{- end }}

{{/*
Name of the instance-admin PAT secret the central reconciler delivers into
this namespace (via the reflector; mirrors keep the source name, so it is
per-instance).
*/}}
{{- define "beabee.zitadelPatSecretName" -}}
{{ .Values.zitadel.patSecretName | default (printf "zitadel-instance-pat-%s" (include "beabee.zitadelInstanceName" .)) }}
{{- end }}

{{/*
The tenant's vanity login domain — zitadel.loginDomain, or auth.<hive.domain>.
*/}}
{{- define "beabee.zitadelLoginDomain" -}}
{{ .Values.zitadel.loginDomain | default (printf "auth.%s" .Values.hive.domain) }}
{{- end }}

{{/*
The tenant's OIDC issuer: their login domain over https. ZITADEL serves
discovery on every registered domain and reports the queried host as issuer.
*/}}
{{- define "beabee.zitadelIssuer" -}}
https://{{ include "beabee.zitadelLoginDomain" . }}
{{- end }}

{{/*
Domain-derived env from hive.domain / hive.id — the Helm analog of
hive-deploy-stack's x-backend-env (BEABEE_ vars derived from HIVE_DOMAIN /
HIVE_ID). Rendered as explicit env, so they override the tenant secret.
*/}}
{{- define "beabee.hiveDerivedEnv" -}}
- name: BEABEE_AUDIENCE
  value: {{ printf "%s://%s" (include "beabee.scheme" .) .Values.hive.domain | quote }}
- name: BEABEE_COOKIE_DOMAIN
  value: {{ include "beabee.cookieDomain" . | quote }}
- name: BEABEE_WEBHOOKURL
  value: {{ printf "%s://%s" (include "beabee.scheme" .) (include "beabee.hiveDomain" .) | quote }}
{{- end }}
