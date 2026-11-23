{{/*
AppProjects for platform services and for user-facing apps.
Usage: project: {{ include "infra.platformProject" . }}
*/}}
{{- define "infra.platformProject" -}}
{{- .Values.cluster.projects.platform -}}
{{- end -}}

{{- define "infra.appsProject" -}}
{{- .Values.cluster.projects.apps -}}
{{- end -}}

{{/*
Prefix for generated ArgoCD Application metadata.name values.
Set cluster.appNamePrefix to shorten app names independently from project/domain naming.
*/}}
{{- define "infra.appNamePrefix" -}}
{{- default .Values.cluster.name .Values.cluster.appNamePrefix -}}
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
Retry extends Argo CD's implicit automated-sync default (5 retries, 5s base,
3m cap) so a failed sync of the same revision keeps being re-attempted for
about an hour (30s, 1m, 2m, 4m, 8m, then 10m each), e.g. while another
Application is still installing CRDs.
Used by infra.application; the root Application repeats it by hand.
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

{{/*
infra.application renders one child Application from a small description, so
the shared skeleton and the rules in docs/adr/0001-0003 live in one place.

Usage, from a template file per Application:

  {{- define "app.dumbpad" }}
  name: dumbpad                 # Application homelab-dumbpad
  namespace: dumbpad
  wave: 2                       # 0, 1 or 2 (docs/adr/0001-three-sync-waves.md)
  project: apps                 # platform or apps
  ownsPVCs: true
  sources:
    - path: gitops/infra-custom/dumbpad
  {{ end }}
  {{- if .Values.dumbpad.enabled }}
  {{ include "infra.application" (dict "root" . "app" (include "app.dumbpad" . | fromYaml)) }}
  {{- end }}

Close the define with "{{ end }}", not "{{- end }}": the dash would also trim
the final newline of a trailing "values: |" block.

Keys (anything else fails the render):
  name, namespace, wave, project   required
  createNamespace     Argo CD creates the namespace (default false: the source owns it)
  namespaceLabels     labels for a namespace Argo CD creates (needs createNamespace)
  cascadeDelete       add the resources finalizer (default false; docs/adr/0002)
  ownsPVCs            ignore PVC volumeName drift and prune last; not with cascadeDelete
  appLabel            the "app" label (default: name)
  partOf              the app.kubernetes.io/part-of label
  sources             list of {path, helm?} (this repository) or
                      {repoURL, chart, version, helm?} (upstream chart). A Git
                      "ref: values" source is added when a valueFiles entry
                      starts with $values/.
  syncOptions, ignoreDifferences, annotations, finalizers
                      added to what the helper emits

Always emitted: the cluster label, the sync-wave annotation, the in-cluster
destination, infra.syncPolicy, FailOnSharedResource, SkipDryRunOnMissingResource,
and RespectIgnoreDifferences whenever there are ignoreDifferences.
*/}}
{{- define "infra.application" -}}
{{- $root := .root -}}
{{- $app := .app -}}
{{- if hasKey $app "Error" -}}
{{- fail (printf "infra.application: the Application description does not parse: %s" $app.Error) -}}
{{- end -}}
{{- if not $app.name -}}
{{- fail "infra.application: name is required" -}}
{{- end -}}
{{- $ctx := printf "infra.application %s" $app.name -}}
{{- $keys := list "name" "namespace" "wave" "project" "createNamespace" "namespaceLabels" "cascadeDelete" "ownsPVCs" "appLabel" "partOf" "sources" "syncOptions" "ignoreDifferences" "annotations" "finalizers" -}}
{{- range $key, $_ := $app -}}
{{- if not (has $key $keys) -}}
{{- fail (printf "%s: unknown key %q" $ctx $key) -}}
{{- end -}}
{{- end -}}
{{- if not $app.namespace -}}
{{- fail (printf "%s: namespace is required" $ctx) -}}
{{- end -}}
{{- $wave := "" -}}
{{- if hasKey $app "wave" -}}
{{- $wave = toString $app.wave -}}
{{- end -}}
{{- if not (has $wave (list "0" "1" "2")) -}}
{{- fail (printf "%s: wave must be 0, 1 or 2, not %q (docs/adr/0001-three-sync-waves.md)" $ctx $wave) -}}
{{- end -}}
{{- if not (has $app.project (list "platform" "apps")) -}}
{{- fail (printf "%s: project must be platform or apps, not %q" $ctx (toString $app.project)) -}}
{{- end -}}
{{- if and $app.cascadeDelete $app.ownsPVCs -}}
{{- fail (printf "%s: an Application that owns PVCs must not cascade-delete them (docs/adr/0002-cascade-delete-is-opt-in.md)" $ctx) -}}
{{- end -}}
{{- if and $app.namespaceLabels (not $app.createNamespace) -}}
{{- fail (printf "%s: namespaceLabels need createNamespace: true; otherwise label the source's Namespace" $ctx) -}}
{{- end -}}
{{- if not $app.sources -}}
{{- fail (printf "%s: sources must list at least one source" $ctx) -}}
{{- end -}}

{{- $sources := list -}}
{{- $valuesRef := false -}}
{{- range $app.sources -}}
{{- $src := . -}}
{{- $source := dict -}}
{{- if .path -}}
{{- range $key, $_ := . -}}
{{- if not (has $key (list "path" "helm")) -}}
{{- fail (printf "%s: unknown key %q in the source for %s" $ctx $key $src.path) -}}
{{- end -}}
{{- end -}}
{{- $source = dict "repoURL" $root.Values.cluster.repoURL "targetRevision" $root.Values.cluster.revision "path" .path -}}
{{- else if .chart -}}
{{- range $key, $_ := . -}}
{{- if not (has $key (list "repoURL" "chart" "version" "helm")) -}}
{{- fail (printf "%s: unknown key %q in the source for chart %s" $ctx $key $src.chart) -}}
{{- end -}}
{{- end -}}
{{- if not (and .repoURL .version) -}}
{{- fail (printf "%s: chart %s needs repoURL and version" $ctx .chart) -}}
{{- end -}}
{{- $source = dict "repoURL" .repoURL "chart" .chart "targetRevision" (toString .version) -}}
{{- else -}}
{{- fail (printf "%s: every source needs a path or a chart" $ctx) -}}
{{- end -}}
{{- with .helm -}}
{{- $_ := set $source "helm" . -}}
{{- range .valueFiles -}}
{{- if hasPrefix "$values/" . -}}
{{- $valuesRef = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $sources = append $sources $source -}}
{{- end -}}
{{- if $valuesRef -}}
{{- $sources = append $sources (dict "repoURL" $root.Values.cluster.repoURL "targetRevision" $root.Values.cluster.revision "ref" "values") -}}
{{- end -}}

{{- $finalizers := list -}}
{{- if $app.cascadeDelete -}}
{{- $finalizers = append $finalizers "resources-finalizer.argocd.argoproj.io" -}}
{{- end -}}
{{- $finalizers = concat $finalizers ($app.finalizers | default list) -}}

{{- $ignore := list -}}
{{- if $app.ownsPVCs -}}
{{- $ignore = append $ignore (dict "kind" "PersistentVolumeClaim" "jqPathExpressions" (list ".spec.volumeName")) -}}
{{- end -}}
{{- $ignore = concat $ignore ($app.ignoreDifferences | default list) -}}

{{- $syncOptions := list "FailOnSharedResource=true" (printf "CreateNamespace=%t" (default false $app.createNamespace)) -}}
{{- if $app.ownsPVCs -}}
{{- $syncOptions = append $syncOptions "PruneLast=true" -}}
{{- end -}}
{{- if $ignore -}}
{{- $syncOptions = append $syncOptions "RespectIgnoreDifferences=true" -}}
{{- end -}}
{{- $syncOptions = append $syncOptions "SkipDryRunOnMissingResource=true" -}}
{{- $syncOptions = concat $syncOptions ($app.syncOptions | default list) -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ include "infra.appName" (dict "root" $root "name" $app.name) }}
  namespace: {{ $root.Values.cluster.namespace | quote }}
  labels:
    cluster: {{ $root.Values.cluster.name | quote }}
    app: {{ $app.appLabel | default $app.name | quote }}
    {{- with $app.partOf }}
    app.kubernetes.io/part-of: {{ . | quote }}
    {{- end }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
    {{- with $app.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $finalizers }}
  finalizers:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  project: {{ index $root.Values.cluster.projects $app.project | quote }}
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ $app.namespace | quote }}
  {{- with $ignore }}
  ignoreDifferences:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  syncPolicy:
    {{- include "infra.syncPolicy" $root | nindent 4 }}
    syncOptions:
      {{- toYaml $syncOptions | nindent 6 }}
    {{- with $app.namespaceLabels }}
    managedNamespaceMetadata:
      labels:
        {{- toYaml . | nindent 8 }}
    {{- end }}
  {{- if eq (len $sources) 1 }}
  source:
    {{- toYaml (first $sources) | nindent 4 }}
  {{- else }}
  sources:
    {{- toYaml $sources | nindent 4 }}
  {{- end }}
{{- end -}}
