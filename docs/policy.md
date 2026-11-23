# Workload Policy

Workload security is checked in three layers:

1. **Pod Security Admission** gives every namespace a floor. Talos configures
   the cluster default as `enforce: baseline` with `warn` and `audit` at
   `restricted`; only `kube-system` is exempt. Namespaces that need more
   host access override the level in Git (see below).
2. **Kyverno** checks each workload against the `restricted` Pod Security
   Standard and a few best practices. Unlike namespace labels, it reports per
   workload and supports narrow, documented exceptions.
3. **CI** runs the policy tests and checks the workloads rendered from this
   repository against the policies and exceptions before they reach the
   cluster.

Results are visible in Policy Reporter at
`https://policy-reporter.homelab.niekvlam.nl` (behind oauth2-proxy SSO), in
its Grafana dashboards, and with `kubectl get policyreports -A`.

## Pod Security Admission levels

Only namespaces that differ from the Talos default carry labels. Each
override is set in the Application's `managedNamespaceMetadata` or the
namespace manifest, next to a comment with the reason.

| Namespace | Enforce | Why |
|---|---|---|
| `longhorn-system` | privileged | Longhorn manager, CSI and instance-manager pods need privileged host access |
| `metallb-system` | privileged | The speaker uses the host network and `NET_RAW` to announce service IPs |
| `monitoring` | privileged | node-exporter (host network, PID and filesystem) and Alloy (host log files) |
| `tailscale` | privileged | The kernel-mode subnet router and exit node need `NET_ADMIN` and sysctls |
| `pi5-fan-control` | privileged | The fan controller writes the Pi 5 PWM registers through sysfs |
| `media` | privileged | The gluetun VPN sidecar needs `NET_ADMIN` and `/dev/net/tun` |
| `cert-manager`, `home-assistant` | baseline | Stated explicitly; same as the default |
| everything else | baseline | Talos default (`warn`/`audit`: restricted) |

To preview a change before committing it (read-only, prints warnings for
running pods):

```bash
kubectl label --dry-run=server --overwrite ns <namespace> pod-security.kubernetes.io/enforce=restricted
```

## Kyverno policies

The policies live in [`gitops/infra-custom/kyverno/policies`](../gitops/infra-custom/kyverno/policies)
as CEL `ValidatingPolicy` resources. They match Pods, and autogen applies the
same checks to Deployments, StatefulSets, DaemonSets, Jobs and CronJobs.
`kube-system` is excluded.

| Policy | Checks |
|---|---|
| `pss-baseline` | The baseline Pod Security Standard, per workload |
| `pss-restricted-privilege-escalation` | `allowPrivilegeEscalation: false` on every container |
| `pss-restricted-capabilities` | `drop: [ALL]`, adding back only `NET_BIND_SERVICE` |
| `pss-restricted-run-as-non-root` | `runAsNonRoot: true` and no `runAsUser: 0` |
| `pss-restricted-seccomp` | `RuntimeDefault` or `Localhost` seccomp profile |
| `pss-restricted-volume-types` | Only the volume types the restricted standard allows |
| `disallow-mutable-tags` | A version tag or digest; no untagged, `latest`, `main` or similar tags |
| `require-resources` | CPU and memory requests and a memory limit (no CPU limit required) |
| `require-probes` | Liveness and readiness probes, for Deployments and StatefulSets in the app namespaces |
| `disallow-default-namespace` | No workloads in `default` |
| `require-name-label` | The `app.kubernetes.io/name` label on the pod template |

All policies currently run with `validationActions: [Audit]` and fail open:
the Kyverno chart sets `forceFailurePolicyIgnore`, so a Kyverno outage never
blocks admission.

## Exceptions

Exceptions are `PolicyException` resources in
[`gitops/infra-custom/kyverno/exceptions`](../gitops/infra-custom/kyverno/exceptions).
Kyverno only accepts them from the `kyverno` namespace, which only Argo CD
writes to. Each one names the policies it covers and records its reason in
`spec.properties.reason`. Exceptions for workloads CI does not render (an
upstream chart or an operator creates them) also set
`spec.properties.rendered: "false"`; for those, the cluster's policy reports
are the only check that they still match.

| Exception | Workloads | Policies | Rendered in CI |
|---|---|---|---|
| `longhorn` | Everything in `longhorn-system` | All PSS, resources, name label, probes | no |
| `metallb-speaker` | MetalLB speaker | Baseline, capabilities, non-root | no |
| `node-exporter` | node-exporter | Baseline, volume types | no |
| `alloy` | Alloy | Baseline, volume types, non-root | no |
| `pi5-fan-control` | Fan controller | All PSS | yes |
| `tailscale-subnet-router` | Tailscale connector | All PSS | no |
| `qbittorrent-vpn` | qBittorrent with gluetun | Baseline, volume types, capabilities, non-root | yes |
| `linuxserver-root` | Media Deployments labelled `homelab.niekvlam.nl/base: linuxserver` (Bazarr, Prowlarr, qBittorrent, Radarr, Sonarr) | Non-root, capabilities | yes |
| `home-assistant` | Home Assistant | Non-root, capabilities, resources | no |
| `nfs-provisioner` | NFS subdir provisioner | Restricted PSS, name label; expires 2026-12-31 | no |

Exception conditions see the object being checked: for a Deployment that is
its own metadata, not the pod template. Since Kyverno 1.20 its `spec` is
already the pod spec, so `object.spec.template` is gone too. Match on labels
that are set on both the controller and its pod template, preferably
`app.kubernetes.io/name`, which `require-name-label` already requires on the
template.

Adding an exception:

1. Add a file under `exceptions/` with a `reason`, the narrowest set of
   `policyRefs`, and `matchConditions` on namespace plus labels. Add
   `rendered: "false"` under `properties` if CI does not render the workload.
2. List it in [`kustomization.yaml`](../gitops/infra-custom/kyverno/kustomization.yaml).
3. For a workload CI does not render, add or extend a case in
   `tests/exceptions/`. Then run `scripts/validate.sh`.

## Tests

Each policy has a `kyverno test` suite with passing and failing fixtures in
[`gitops/infra-custom/kyverno/tests`](../gitops/infra-custom/kyverno/tests).
`scripts/validate.sh` and the `Validate` workflow run them.

`validate.sh` also runs `kyverno apply` over every workload rendered from this
repository, as a stand-in for admission, once with the exceptions and once
without. It fails when:

- a rendered workload fails a policy, whether that policy is in Audit or
  Enforce: fix the workload or add an exception;
- an exception skips no rendered workload for a policy it lists: its match is
  stale, or it needs `rendered: "false"`;
- an exception skips a workload that passes the policy without it: narrow or
  remove the exception;
- an exception marked `rendered: "false"` skips a rendered workload: remove
  the marker.

It also fails when a policy file is not deployed, an exception names a policy
that does not exist, or a test expectation and its fixtures disagree. The
check's own failure cases live in
[`scripts/testdata/policy-check`](../scripts/testdata/policy-check). The
workflow shows the report in its job summary.

## Switching a policy to Enforce

Switch one policy at a time, and only after it has had no unexcepted
failures for at least three days.

1. Check the policy in Policy Reporter, or:
   ```bash
   kubectl get policyreports -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .results[]? | select(.policy == "<policy>" and .result == "fail") | $ns'
   ```
2. Set `validationActions: [Deny]` in the policy file and push.
3. Check that a violating test pod is rejected:
   ```bash
   kubectl run enforce-test --image=nginx:latest --dry-run=server -n homelab-platform
   ```
4. Watch Argo CD for Degraded or failed syncs for a day.

Admission stays fail-open while `forceFailurePolicyIgnore` is set in the
Kyverno Application. Turning it off makes enforced policies fail closed, so
do that only after the enforced set has proven stable.

**Rolling back** a policy: set `validationActions` back to `[Audit]` and
push. If Kyverno itself blocks admission and Argo CD cannot sync the fix,
delete the `kyverno-resource-validating-webhook-cfg` and
`kyverno-resource-mutating-webhook-cfg` webhook configurations; Kyverno
recreates them once it is healthy.
