# Cluster Bootstrap and Reconfiguration

This document covers the bootstrap boundary that exists before Argo CD can reconcile the platform. It also records the local rendering and authenticated Talos update workflow used after the cluster is running.

## Prerequisites

- `talosctl`
- `kubectl`
- `kustomize` with Helm support
- `helm`
- `yq`
- `jq`
- access to the selected Talos installer image
- an external location for Talos secrets and client configuration

The expected `talosctl` version is pinned in [`.tool-versions`](../.tool-versions).

## Bootstrap sequence

### 1. Define the cluster

[`nodes.yaml`](../nodes.yaml) contains the cluster name, Kubernetes endpoint, control-plane VIP, and node inventory. Review it together with:

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

`generate.sh` defaults to `/dev/nvme0n1` and enables installation-disk wiping. Confirm the target hardware before generating or applying machine configuration.

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
TALOS_INSTALL_DISK=/dev/nvme0n1
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

The helper installs the selected Gateway API CRDs, renders Cilium through Kustomize and Helm, restarts the Cilium components, and creates the shared Gateway. Set `INSTALL_TLSROUTE=true` when the experimental TLSRoute CRD is required.

### 5. Bootstrap Argo CD

Render Argo CD locally:

```bash
kustomize build --enable-helm gitops/argocd
```

Apply the reviewed output:

```bash
kustomize build --enable-helm gitops/argocd | kubectl apply -f -
```

The repository credential can then be supplied through the External Secrets integration. The External Secrets 1Password service-account token is introduced with:

```bash
./gitops/infra-custom/external-secrets/scripts/bootstrap_onepassword_service_account_token.sh
```

### 6. Hand reconciliation to Argo CD

Render the platform Application chart:

```bash
helm template infra-apps gitops/infra-helm
```

Apply the reviewed Applications:

```bash
helm template infra-apps gitops/infra-helm | kubectl apply -f -
```

Argo CD then creates and reconciles the enabled platform and workload Applications.

## Local validation

Run the relevant render before committing a change:

```bash
helm template infra-apps gitops/infra-helm
kustomize build --enable-helm gitops/argocd
```

Custom charts under `gitops/infra-custom` can be rendered individually with their corresponding values. Review both source changes and rendered resources, particularly when Renovate updates a Helm chart or container image.

## Authenticated Talos reconfiguration

`apply.sh` uses:

- `nodes.yaml` to map hostnames to node addresses;
- generated files under `output/<hostname>/machineconfig.yaml`;
- `~/.talos/config` by default;
- the `home-cluster` Talos context by default.

Override `TALOSCONFIG`, `TALOS_CONTEXT`, or `TALOSCTL_BIN` when operating from a different local setup. Generate and inspect the new configuration before applying it to the cluster.
