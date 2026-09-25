# Cluster Bootstrap and Reconfiguration

This document covers the bootstrap boundary that exists before Argo CD can reconcile the platform. It also records the local rendering and authenticated Talos update workflow used after the cluster is running.

## Prerequisites

- `talosctl`
- `kubectl`
- `kustomize` with Helm support
- `helm`
- `yq`
- `jq`
- 1Password CLI (`op`) for the External Secrets bootstrap token
- access to the selected Talos installer image
- an external location for Talos secrets and client configuration

The expected `talosctl` version is pinned in [`.tool-versions`](../.tool-versions).
Single-control-plane backup, disk identity, A/B rollback, and etcd restoration
are documented in [`control-plane-recovery.md`](control-plane-recovery.md).

## Bootstrap sequence

### 1. Define the cluster

[`nodes.yaml`](../nodes.yaml) contains the current cluster name, Kubernetes
endpoint, control-plane VIP, network parameters, registry mirror, and node
inventory. Review the selected inventory
together with:

- [`patches/controlplane.yaml`](../patches/controlplane.yaml)
- [`patches/worker.yaml`](../patches/worker.yaml)
- [`patches/disk.yaml`](../patches/disk.yaml)
- the configuration defaults at the top of [`generate.sh`](../generate.sh)

The main settings to confirm are:

- Talos installer image;
- Kubernetes version;
- installation disk;
- registry mirror;
- network interface;
- control-plane VIP;
- gateway and DNS servers;
- worker Longhorn disk selection.

`generate.sh` defaults to `/dev/mmcblk0` and enables installation-disk wiping. Confirm the target hardware before generating or applying machine configuration.

### 2. Generate Talos configuration

The Talos secrets bundle is stored outside the repository. Its default path is:

```text
~/.talos/homelab/secrets.yaml
```

Generate the client and per-node machine configuration:

```bash
./generate.sh
```

If the secrets bundle does not exist, the script creates it at the configured external path. Generated files are written to the ignored `output/` directory.

Common overrides:

```bash
TALOS_SECRETS_FILE=/secure/path/secrets.yaml
TALOS_INSTALL_DISK=/dev/mmcblk0
TALOS_INSTALL_WIPE=true
TALOS_ENABLE_VIP=true
TALOS_MERGE_KUBECONFIG=false
./generate.sh
```

Other supported settings are documented by the variable defaults at the top of `generate.sh`.

### 3. Apply the initial machine configuration

Review every generated `machineconfig.yaml` before applying it. The first apply to a new Talos machine and the subsequent etcd bootstrap are version- and state-sensitive operations; use the procedure for the Talos version pinned by this repository.

[`apply.sh`](../apply.sh) expects an existing Talos client configuration and the `home-cluster` context. It is intended for authenticated reconfiguration of reachable nodes:

```bash
./apply.sh
```

The script maps generated configuration back to the node inventory and applies the matching file with `talosctl`.

### 4. Install Cilium

The Talos patches set the CNI to `none` and disable kube-proxy. Install Cilium before deploying normal workloads:

```bash
./cilium/enable-gateway-api.sh
```

The helper installs the pinned Gateway API v1.6.1 Standard CRD bundle only. It
does not render, apply, or restart Cilium. Cilium changes use the reviewed
Kustomize renderer and an explicitly reviewed `kubectl apply` manifest; the
Experimental Gateway API bundle is not part of this bootstrap path.

Render and review the pinned Cilium manifest, then install it before continuing
with Argo CD:

```bash
kustomize build --enable-helm cilium
kubectl apply --server-side -f <reviewed-cilium-manifest.yaml>
```

Wait until Cilium is healthy and cluster networking works before proceeding.

### 5. Bootstrap Argo CD manually

Render Argo CD locally:

```bash
kustomize build --enable-helm gitops/argocd
```

`gitops/argocd/charts` is an ignored Helm download cache, not committed bootstrap
input. A clean checkout can render this kustomization because Helm retrieves the
pinned chart dependency during rendering; no vendored chart directory is required.

Apply the reviewed output:

```bash
kustomize build --enable-helm gitops/argocd | kubectl apply --server-side -f -
```

Argo CD remains a manual installation and upgrade boundary. It is intentionally
not managed by the root Application in this phase.

### 6. Supply the initial bootstrap credential

The platform retrieves its repository and application credentials through
External Secrets. Before creating the root Application, supply the initial
1Password service-account token that lets External Secrets retrieve those
credentials:

```bash
kubectl create namespace external-secrets
./gitops/infra-custom/external-secrets/scripts/bootstrap_onepassword_service_account_token.sh
```

This command is the only bootstrap secret material introduced outside Git; do
not store the token in this repository. Confirm the secret exists before the
root Application is created. The namespace creation is needed because the
External Secrets controller itself is reconciled only after the root handoff.

### 7. Hand reconciliation to Argo CD

The committed [`root Application`](../gitops/root-application.yaml) reconciles
the existing `gitops/infra-helm` Application-generator chart. It uses Argo CD's
built-in `default` project only long enough to create the chart-managed
`homelab.niekvlam` AppProject. That AppProject is rendered at sync wave `-1`,
before its child Applications, and limits those Applications to this cluster
and the repositories used by the chart.

Review and apply the root Application:

```bash
kubectl apply --server-side -f gitops/root-application.yaml
```

Argo CD then creates the AppProject and reconciles the enabled platform and
workload Applications. Subsequent changes flow from Git through this existing
App-of-Apps hierarchy; do not separately apply the rendered child Applications.

The root Application is named `app-of-apps` and is not reconciled by itself:
re-apply `gitops/root-application.yaml` after changing it. Do not create a
second root Application under another name; both would claim the same child
Applications and fail with `SharedResourceWarning`.

## Local validation

Run the relevant render before committing a change:

```bash
helm template infra-apps gitops/infra-helm
kustomize build --enable-helm gitops/argocd
```

The root Application is a plain Kubernetes manifest and can be checked with:

```bash
kubectl apply --dry-run=client -f gitops/root-application.yaml
```

Custom charts under `gitops/infra-custom` can be rendered individually with their corresponding values. Review both source changes and rendered resources, particularly when Renovate updates a Helm chart or container image.

## Authenticated Talos reconfiguration

`apply.sh` uses:

- `nodes.yaml` to map hostnames to node addresses;
- generated files under `output/<hostname>/machineconfig.yaml`;
- `~/.talos/config` by default;
- the `home-cluster` Talos context by default.

Override `TALOSCONFIG`, `TALOS_CONTEXT`, or `TALOSCTL_BIN` when operating from a different local setup. Generate and inspect the new configuration before applying it to the cluster.

`TALOS_NODES_FILE` and `TALOS_OUTPUT_DIR` select a non-default inventory and
its matching generated directory.
