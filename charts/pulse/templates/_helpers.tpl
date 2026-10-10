{{- define "pulse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "pulse.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if contains (include "pulse.name" .) .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "pulse.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "pulse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pulse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "pulse.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "pulse.selectorLabels" . }}
app.kubernetes.io/version: {{ include "pulse.version" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "pulse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pulse.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Deploy by digest when given (immutable), otherwise by tag; refuse to render without either. */}}
{{- define "pulse.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (required "set image.tag or image.digest" .Values.image.tag) }}
{{- end }}
{{- end }}

{{- define "pulse.version" -}}
{{- if .Values.image.digest }}{{ .Chart.AppVersion }}{{ else }}{{ default .Chart.AppVersion .Values.image.tag }}{{ end }}
{{- end }}
