# Cascade delete is opt-in and separate from owning PVCs

A child Application only gets the `resources-finalizer` when it sets `cascadeDelete: true`; the default is no finalizer, so forgetting the flag leaves resources in place instead of deleting them. "Owns PVCs" is a separate flag (PVC `volumeName` ignore rule and `PruneLast`) and the helper refuses both on one Application.

## Considered Options

- **One `stateful` flag meaning "no finalizer"**. Rejected: cert-manager, MetalLB, External Secrets, Tailscale, the Gateway, the NFS provisioner and Renovate are stateless yet also must not cascade, because deleting them would remove CRDs with every certificate and secret store, the only ingress path, or the storage provisioner. The real question is whether cascading is safe, not whether there is state.
