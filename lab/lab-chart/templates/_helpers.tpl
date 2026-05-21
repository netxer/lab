{{/*
Common labels for all resources in this lab release.
Include with: {{- include "lab.labels" . | nindent 4 }}
*/}}
{{- define "lab.labels" -}}
app.kubernetes.io/name: lab
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
lab.trainee: {{ .Values.trainee.name }}
{{- end }}

{{/*
Selector labels - subset used for Service selectors etc.
*/}}
{{- define "lab.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
lab.trainee: {{ .Values.trainee.name }}
{{- end }}
