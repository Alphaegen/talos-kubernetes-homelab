# Namespace roles stay explicit lists, checked or derived, not namespace labels

Several places need to know which namespaces hold user workloads or persistent data: the `apps` AppProject's destinations, the `require-probes` Kyverno policy, and the persistent-workload alerts. We did not give namespaces a role label (for example `homelab.niekvlam.nl/tier: app`) for these places to select on. The `apps` project keeps its destination list, `require-probes` keeps its namespace list and the app-of-apps contract in `validate.sh` fails unless it covers every `apps` namespace, and the alerts select pods that mount a PVC instead of naming namespaces.

## Considered Options

- **A namespace label as the one source of truth.** Argo CD AppProject destinations cannot select by label, so the project list stays regardless and a new app namespace still takes two edits: the destination and the label. kube-state-metrics does not export namespace labels without an allowlist, so the alerts would need extra configuration to join on them. Namespace metadata also has four owners here (a `namespace.yaml` in the source, `namespaceLabels` on an Application Argo CD creates the namespace for, a chart template, and kube-prometheus-stack), so the label would be set in four different ways.
- **Derive the alerts from the workloads.** Chosen: `kube_pod_spec_volumes_persistentvolumeclaims_info` already says which pods mount a PVC, so there is no list to keep. Longhorn's own pods are added explicitly, since they serve volumes without mounting one.
