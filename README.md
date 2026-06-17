# Talos Homelab

Kubernetes homelab running on Talos Linux, managed with Argo CD and GitOps.

## Overview

This repository contains:

- Talos cluster bootstrap and node configuration
- Argo CD installation and configuration
- GitOps application definitions under `gitops/`
- Custom Helm charts and manifests for homelab services

## Core Platform

- Kubernetes distribution: Talos Linux
- GitOps controller: Argo CD
- Ingress: ingress-nginx
- Load balancing: MetalLB (L2)
- Storage: Longhorn and NFS subdir external provisioner
- TLS and certificates: cert-manager
- Secrets: External Secrets Operator with 1Password and Vault integrations
- Remote network access: Tailscale operator

## Workloads

- Home Assistant
- Home automation support stack: Mosquitto and Zigbee2MQTT
- Media stack: Sonarr, Radarr, Prowlarr, qBittorrent, Overseerr, Profilarr, and FlareSolverr

## Repository Structure

- `gitops/argocd`: Argo CD install with Kustomize and Helm
- `gitops/infra-helm`: parent app chart that defines Argo CD Applications
- `gitops/infra-custom`: custom charts and manifests for workloads and integrations
- `patches/`: Talos machine configuration patches
- `generate.sh`: Talos config generation workflow
- `apply.sh`: applies generated machine configs with `talosctl`

## Operations

Typical GitOps workflow:

1. Edit manifests or values.
2. Commit and push to `main`.
3. Sync from Argo CD, or rely on automated child app sync where configured.

Helpful checks:

```bash
helm template infra-apps gitops/infra-helm
kustomize build --enable-helm gitops/argocd
```

Enable Cilium Gateway API and apply the shared Gateway:

```bash
./cilium/enable-gateway-api.sh
```

Cluster-specific hostnames and routing are configured for `homelab.niekvlam.nl`.

## Local Access

Talos, Kubernetes, SSH, and bootstrap credentials are managed outside this
repository. Working credentials live in standard user-level locations, and
recoverable copies live in the 1Password `Homelab` vault.

Current local paths:

- Talos config: `~/.talos/config`
- Talos secrets bundle: `~/.talos/homelab/secrets.yaml`
- Kubernetes config: `~/.kube/config`

Day-to-day context switching:

```bash
talosctl config context home-cluster
kubectl config use-context homelab
```

Useful access checks:

```bash
talosctl --context home-cluster get members
kubectl --context homelab get nodes
```

`generate.sh` reads Talos secrets from `~/.talos/homelab/secrets.yaml` by
default and writes generated machine configs to ignored `output/`. `apply.sh`
uses `~/.talos/config` and the `home-cluster` Talos context by default.
