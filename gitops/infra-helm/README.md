# Infra Helm Operations

## Application Naming

This chart now separates application naming from project/domain naming:

- `cluster.projectName`: ArgoCD project name (defaults to `cluster.name`)
- `cluster.appNamePrefix`: prefix used for ArgoCD `Application.metadata.name`
- `cluster.name`: kept for hostnames/legacy references

Example with current values:

- project: `homelab.niekvlam`
- app names: `homelab-*`

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

The root chart uses only three child-Application waves:

- `0`: API providers and cluster foundations (storage, networking, ingress,
  monitoring CRDs, secret management, certificate management, and rollout
  CRDs)
- `1`: platform add-ons and services that consume those foundations
- `2`: workloads and smoke validation

These waves make a fresh bootstrap easier to understand, but independently
auto-syncing child Applications are not a readiness scheduler. CRD-backed
configuration that belongs to an operator is therefore kept in the same
multi-source Application as that operator where practical. Cross-Application
custom resources use `SkipDryRunOnMissingResource=true` where the provider may
still be converging; automated sync then retries them. Within a combined
operator Application, its own CRD-backed resources use only waves `1`/`2` after
the chart's default wave `0` (for example, SecretStores before ExternalSecrets).

Resource ownership is intentionally singular:

- `homelab-cert-manager-helm` owns the `cert-manager` namespace metadata, the
  cert-manager chart, and its `ClusterIssuer`.
- `homelab-kube-prometheus-stack` owns the `monitoring` namespace metadata and
  monitoring CRDs. Grafana, Loki, and Promtail do not create or manage that
  namespace.
- `homelab-external-secrets` owns the External Secrets operator, SecretStores,
  and bootstrap credential `ExternalSecret` resources for cert-manager and
  Tailscale.
- The Longhorn, MetalLB, Tailscale, and optional Kyverno applications each own
  both their operator and their operator-specific custom resources.

With those overlaps removed, the root and every child Application enable
`FailOnSharedResource=true` so a future ownership collision fails visibly.

## Application Deletion Policy

Applications that directly manage persistent or stateful services deliberately
do **not** have the Argo CD resources finalizer. Deleting one of those
Application objects must not cascade-delete its workloads, PVCs, storage
controller, or data. This includes Longhorn, Prometheus, Grafana, Loki, Home
Assistant, Home Automation, media, BookOrbit, Obsidian LiveSync, Vault, and the
optional Keycloak service.

Stateless agents, controllers, and validation workloads keep the resources
finalizer where it already existed, so deleting their Application continues to
clean up their managed resources. Absence of a finalizer is a deletion safety
choice, not a replacement for reviewing prune behavior before a sync.

## One-Time Migration For Renamed Argo Applications

Because app names changed from `<cluster.name>-*` to `<cluster.appNamePrefix>-*`, do a controlled migration:

1. Sync the parent app once with prune disabled.
2. Verify new apps (`homelab-*`) are healthy/synced.
3. Remove finalizers from old apps and delete old app CRs:
   - `kubectl -n argocd patch application <old-app-name> --type merge -p '{"metadata":{"finalizers":[]}}'`
   - `kubectl -n argocd delete application <old-app-name>`
4. Re-enable prune on the parent app.
