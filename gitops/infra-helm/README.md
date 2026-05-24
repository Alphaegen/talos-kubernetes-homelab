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

Recommended flow:

1. Let Renovate open update PRs.
2. Review chart/image changelogs.
3. Merge PR.
4. Let ArgoCD sync automatically.

## One-Time Migration For Renamed Argo Applications

Because app names changed from `<cluster.name>-*` to `<cluster.appNamePrefix>-*`, do a controlled migration:

1. Sync the parent app once with prune disabled.
2. Verify new apps (`homelab-*`) are healthy/synced.
3. Remove finalizers from old apps and delete old app CRs:
   - `kubectl -n argocd patch application <old-app-name> --type merge -p '{"metadata":{"finalizers":[]}}'`
   - `kubectl -n argocd delete application <old-app-name>`
4. Re-enable prune on the parent app.
