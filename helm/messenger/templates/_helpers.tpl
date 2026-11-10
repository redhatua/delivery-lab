{{- define "messenger.labels" -}}
app.kubernetes.io/name: messenger
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "messenger.image" -}}
{{ .Values.image.repository }}@{{ required "image.digest is required" .Values.image.digest }}
{{- end -}}
