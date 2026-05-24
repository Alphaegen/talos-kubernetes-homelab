{{/*
Project name used by ArgoCD Application.spec.project and AppProject.metadata.name.
Defaults to cluster.name to preserve current behavior.
*/}}
{{- define "infra.projectName" -}}
{{- default .Values.cluster.name .Values.cluster.projectName -}}
{{- end -}}

{{/*
Prefix for generated ArgoCD Application metadata.name values.
Set cluster.appNamePrefix to shorten app names independently from project/domain naming.
*/}}
{{- define "infra.appNamePrefix" -}}
{{- default (include "infra.projectName" .) .Values.cluster.appNamePrefix -}}
{{- end -}}

{{/*
Generate an ArgoCD application name from a shared prefix plus a component.
Usage: include "infra.appName" (dict "root" . "name" "component")
*/}}
{{- define "infra.appName" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $prefix := include "infra.appNamePrefix" $root -}}
{{- if $prefix -}}
{{- printf "%s-%s" $prefix $name -}}
{{- else -}}
{{- $name -}}
{{- end -}}
{{- end -}}
