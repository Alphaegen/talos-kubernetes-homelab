# Homelab

A Talos Linux cluster on four Raspberry Pi 5 nodes, reconciled by Argo CD from this repository. These terms describe how the repository is organised into things Argo CD deploys.

## Deployment

**Bootstrap boundary**:
The line between what is applied by hand (Talos, Cilium, Argo CD itself) and what Argo CD reconciles from Git.
_Avoid_: bootstrap layer, base

**Root Application**:
The single hand-applied Argo CD Application (`app-of-apps`) that renders every child Application.
_Avoid_: parent app, umbrella app

**Child Application**:
An Argo CD Application rendered by the root Application; it is the sole owner of one service's resources.
_Avoid_: app, sub-app, component

**Toggle**:
The `enabled` switch that decides whether a child Application is rendered at all.
_Avoid_: feature flag

**AppProject**:
The Argo CD permission set a child Application belongs to: the **platform project** (controllers, storage, networking, monitoring, auth; cluster-scoped resources allowed) or the **apps project** (user workloads confined to their own namespaces).
_Avoid_: project (unqualified)

**Sync wave**:
The bootstrap ordering slot of a child Application: 0 for foundations, 1 for platform add-ons, 2 for workloads. Ordering only, never a readiness guarantee.
_Avoid_: stage, phase

## Sources

**Local source**:
Manifests, a kustomization or a chart under `gitops/infra-custom/<name>/` that a child Application deploys.
_Avoid_: custom app, in-repo chart

**Upstream chart**:
A third-party Helm chart at a pinned version that a child Application deploys.
_Avoid_: remote chart, vendor chart

**Upstream values**:
The configuration for an upstream chart, kept beside the service in `gitops/infra-custom/<name>/` rather than in the root Application's values.
_Avoid_: overrides

## Deletion safety

**Cascade delete**:
Deleting a child Application also deletes every resource it manages. Opt-in, because for CRD providers, ingress and storage it destroys more than the Application itself.
_Avoid_: finalizer (the mechanism, not the behaviour)

**Owns PVCs**:
A child Application whose resources include PersistentVolumeClaims holding data that must survive the Application being deleted or recreated.
_Avoid_: stateful (too broad: stateless CRD providers are just as unsafe to cascade)
