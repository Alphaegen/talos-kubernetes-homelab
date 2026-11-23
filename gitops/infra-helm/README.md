# Infra Helm Operations

## Application Naming

- `cluster.appNamePrefix`: prefix used for ArgoCD `Application.metadata.name`
  (defaults to `cluster.name`); currently `homelab-*`
- `cluster.name`: kept for hostnames/legacy references
- `cluster.projects.platform` / `cluster.projects.apps`: the two AppProjects
  rendered by `templates/projects.yaml`

`platform` holds cluster services (controllers, storage, networking,
monitoring, auth) and may create cluster-scoped resources, but only in its
listed namespaces. `apps` holds the user-facing apps: only their own
namespaces, their sources, and no cluster-scoped resources beyond Namespace
and PersistentVolume. Add a new namespace to the matching project's
`destinations` before enabling an Application that deploys there. A new `apps`
namespace also goes into the namespace list of the `require-probes` Kyverno
policy; `scripts/validate.sh` fails until it does
(`docs/adr/0004-namespace-lists-not-namespace-labels.md`).

## Adding A Child Application

Every child Application is rendered by the `infra.application` helper in
`templates/_helpers.tpl`; its header lists the keys. A template file describes
the Application as a YAML block and passes it to the helper:

```yaml
{{- define "app.dumbpad" }}
name: dumbpad
namespace: dumbpad
wave: 2
project: apps
ownsPVCs: true
sources:
  - path: gitops/infra-custom/dumbpad
{{ end }}
{{- if .Values.dumbpad.enabled }}
{{ include "infra.application" (dict "root" . "app" (include "app.dumbpad" . | fromYaml)) }}
{{- end }}
```

The helper adds everything every Application shares (labels, the sync-wave
annotation, destination, `infra.syncPolicy`, `FailOnSharedResource`,
`SkipDryRunOnMissingResource`, the Git `ref: values` source when a value file
starts with `$values/`) and fails the render when the description breaks a
rule. `ci/contract-tests/` holds one template per rule that must fail, and
`scripts/validate.sh` checks each one. Rules that need more than one
Application or the rendered sources (project destinations and repositories,
`ownsPVCs`, namespace and object owners, CI toggles, the root retry) are the
app-of-apps contract in `scripts/app-contract.jq`, also run by `validate.sh`
with one case per rule in `scripts/testdata/app-contract/`. To confirm that a change to the chart
only changes what you meant, run `scripts/render-diff.sh [base-ref]`.

## Update Workflow

Version selectors are pinned (no `>=0.0.0` or `HEAD` fallbacks for Helm sources) and `renovate.json` is configured to:

- update annotated Helm chart versions in YAML (`# renovate: ...`)
- update pinned container image tags in `gitops/infra-custom/*`
- group routine Helm and container updates, while keeping major upgrades isolated
- create eligible update branches without dependency-dashboard approval
- skip external lookup for the private, repository-managed smoke image

Recommended flow:

1. Let Renovate open update PRs.
2. Review chart/image changelogs.
3. Merge PR.
4. Let ArgoCD sync automatically.

## Bootstrap Stages And Boundaries

## Application Wiring And Service Values

`infra-helm` is the Application wiring layer: it keeps toggles, exact chart
versions, bootstrap stage, and shared repository/cluster metadata, and nothing
else. Upstream Helm values belong beside the owning service, in
`gitops/infra-custom/<name>/upstream-values.yaml` (or `<chart>-values.yaml`
for the monitoring charts). Applications consume those files through a
`$values/gitops/infra-custom/...` value file, and the helper adds the Git
`ref: values` source. An existing custom-resource source stays in the same
Application when it is part of that controller's ownership boundary.

Inline `helm.values` may only carry wiring: values computed from other
toggles, such as the External Secrets integrations that follow the cert-manager
and Tailscale toggles. Do not add a value to `values.yaml` for something the
owning source hard-codes anyway (a namespace, a storage class, the
`release: kube-prometheus-stack` label Prometheus selects on); write it as a
literal. Dashboards that ship with a service are ConfigMaps labelled
`grafana_dashboard: "1"` in that service's source.

Use a multi-source Application for a controller and its CRs, or for an
upstream chart with repository-hosted values. Keep separate Applications for
unrelated services, even when they share a bootstrap stage. `FailOnSharedResource=true`
is deliberately present on every child Application: ownership conflicts must
fail visibly rather than silently transferring resources between Applications.

The root chart uses only three child-Application waves:

- `0`: API providers and cluster foundations (storage, networking, ingress,
  monitoring CRDs, secret management, certificate management, and rollout
  CRDs)
- `1`: platform add-ons and services that consume those foundations
- `2`: workloads and smoke validation

The helper rejects any other wave (`docs/adr/0001-three-sync-waves.md`). These waves make a fresh bootstrap easier to understand, but independently
auto-syncing child Applications are not a readiness scheduler. CRD-backed
configuration that belongs to an operator is therefore kept in the same
multi-source Application as that operator where practical. Cross-Application
custom resources use `SkipDryRunOnMissingResource=true` where the provider may
still be converging; the shared `retry` policy (`infra.syncPolicy` in
`templates/_helpers.tpl`, also set on the root Application) then re-attempts
the failed sync with backoff for about an hour. Once retries are exhausted, that
revision stays failed until a new commit or a manual sync. Within a combined
operator Application, its own CRD-backed resources use only waves `1`/`2` after
the chart's default wave `0` (for example, SecretStores before ExternalSecrets).

Resource ownership is intentionally singular:

- `homelab-cert-manager-helm` owns the `cert-manager` namespace metadata, the
  cert-manager chart, and its `ClusterIssuer`.
- `homelab-kube-prometheus-stack` owns the `monitoring` namespace metadata and
  monitoring CRDs. Grafana, Loki, and Alloy do not create or manage that
  namespace.
- `homelab-external-secrets` owns the External Secrets operator, SecretStores,
  and bootstrap credential `ExternalSecret` resources for cert-manager and
  Tailscale.
- The Longhorn, MetalLB, Tailscale, and optional Kyverno applications each own
  both their operator and their operator-specific custom resources.

With those overlaps removed, the root and every child Application enable
`FailOnSharedResource=true` so a future ownership collision fails visibly. The
app-of-apps contract catches collisions between local sources before merge.

## Application Deletion Policy

Cascade delete is opt-in (`docs/adr/0002-cascade-delete-is-opt-in.md`). Only
an Application with `cascadeDelete: true` gets the Argo CD resources
finalizer, so deleting it also deletes what it manages. That is right for
stateless agents, controllers and validation workloads (Alloy, metrics-server,
Kyverno, Trivy, Policy Reporter, oauth2-proxy, Argo Rollouts, the priority
classes, the fan controller, the kubelet serving cert approver, the smoke
test). Everything else leaves it off: storage and stateful services (Longhorn,
Prometheus, Grafana, Loki, Home Assistant, Home Automation, etcd backup), CRD
providers whose deletion would take every custom resource with them
(cert-manager, External Secrets, MetalLB, Tailscale), the NFS provisioner,
Renovate and the Gateway. `homelab-gateway`'s shared Gateway also carries
`Prune=false`, so neither deleting the Application nor removing the manifest
from Git removes the only HTTPRoute ingress path.

Applications whose source holds PersistentVolumeClaims set `ownsPVCs: true`
(media, BookOrbit, DumbPad, Obsidian LiveSync, Pocket ID, Home Automation, etcd
backup, Grafana, the NFS provisioner): Argo CD ignores the `volumeName` the
provisioner fills in and prunes those PVCs last. The app-of-apps contract
checks this for local sources; set it by hand for an upstream chart that
creates PVCs itself (Grafana, the NFS provisioner). The helper
refuses `ownsPVCs` together with `cascadeDelete`. Absence of a finalizer is a
deletion safety choice, not a replacement for reviewing prune behavior before
a sync.

## One-Time Migration For Renamed Argo Applications

Because app names changed from `<cluster.name>-*` to `<cluster.appNamePrefix>-*`, do a controlled migration:

1. Sync the parent app once with prune disabled.
2. Verify new apps (`homelab-*`) are healthy/synced.
3. Remove finalizers from old apps and delete old app CRs:
   - `kubectl -n argocd patch application <old-app-name> --type merge -p '{"metadata":{"finalizers":[]}}'`
   - `kubectl -n argocd delete application <old-app-name>`
4. Re-enable prune on the parent app.
