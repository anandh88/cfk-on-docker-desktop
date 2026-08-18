{{/*
Expand the name of the chart.
*/}}
{{- define "datadog-confluent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "datadog-confluent.labels" -}}
app: datadog-agent
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "datadog-confluent.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
