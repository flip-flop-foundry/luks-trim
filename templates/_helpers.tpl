{{/*
Expand the name of the chart.
*/}}
{{- define "luks-trim.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name: release-name + chart name, or nameOverride/fullnameOverride.
*/}}
{{- define "luks-trim.fullname" -}}
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
Chart label value: name-version.
*/}}
{{- define "luks-trim.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "luks-trim.labels" -}}
helm.sh/chart: {{ include "luks-trim.chart" . }}
{{ include "luks-trim.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (used in matchLabels and subject bindings).
*/}}
{{- define "luks-trim.selectorLabels" -}}
app.kubernetes.io/name: {{ include "luks-trim.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "luks-trim.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default (include "luks-trim.fullname" .) }}
{{- end }}

{{/*
Namespace where chart resources are deployed.
*/}}
{{- define "luks-trim.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}

{{/*
Namespace for the global key secret. Falls back to chart namespace.
*/}}
{{- define "luks-trim.globalKeyNamespace" -}}
{{- .Values.longhorn.globalKey.secretNamespace | default (include "luks-trim.namespace" .) }}
{{- end }}

{{/*
Validate that talos.kmsEndpoint is set when talos.enabled is true.
Produces a hard render-time error rather than a silent runtime failure.
*/}}
{{- define "luks-trim.kmsEndpoint" -}}
{{- if .Values.talos.enabled -}}
{{- required "talos.kmsEndpoint is required when talos.enabled is true. Set it to \"https://<host>:<port>\"." .Values.talos.kmsEndpoint }}
{{- end -}}
{{- end }}
