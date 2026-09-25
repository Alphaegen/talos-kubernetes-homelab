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

{{/*
Shared automated sync and retry policy for every child Application.
Per-app syncOptions and managedNamespaceMetadata stay explicit in each template.
Retry extends Argo CD's implicit automated-sync default (5 retries, 5s base,
3m cap) so a failed sync of the same revision keeps being re-attempted for
about an hour (30s, 1m, 2m, 4m, 8m, then 10m each), e.g. while another
Application is still installing CRDs.
Usage (directly under spec.syncPolicy):
  syncPolicy:
    {{- include "infra.syncPolicy" . | nindent 4 }}
*/}}
{{- define "infra.syncPolicy" -}}
{{- if .Values.sync -}}
automated:
  prune: true
  selfHeal: true
{{ end -}}
retry:
  limit: 10
  backoff:
    duration: 30s
    factor: 2
    maxDuration: 10m
{{- end -}}
