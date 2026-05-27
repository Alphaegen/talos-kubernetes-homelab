# Talos Homelab

Kubernetes homelab running on Talos Linux, managed with Argo CD and GitOps.

## Overview

This repository contains:

- Talos cluster bootstrap and node configuration
- Argo CD installation and configuration
- GitOps application definitions (`gitops/`)
- Custom Helm charts/manifests for homelab services

## Core Platform

- Kubernetes distribution: Talos Linux
- GitOps controller: Argo CD
- Ingress: ingress-nginx
- Load balancing: MetalLB (L2)
- Storage:
  - Longhorn (primary persistent volumes)
  - NFS subdir external provisioner (media storage class)
- TLS and certificates: cert-manager (Let's Encrypt)
- Secrets: External Secrets Operator (with 1Password and Vault integrations)
- Remote network access: Tailscale operator

## Workloads

- Home Assistant
- Home automation support stack:
  - Mosquitto
  - Zigbee2MQTT
- Media stack:
  - Sonarr
  - Radarr
  - Prowlarr
  - qBittorrent
  - Overseerr
  - Profilarr
  - FlareSolverr

## Repository Structure

- `gitops/argocd`: Argo CD install (kustomize + Helm)
- `gitops/infra-helm`: parent app chart that defines Argo CD Applications
- `gitops/infra-custom`: custom charts/manifests for workloads and integrations
- `patches/`: Talos machine configuration patches
- `generate.sh`: Talos config generation workflow

## Operations

Typical workflow:

1. Edit GitOps manifests/values.
2. Commit and push to `main`.
3. Sync from Argo CD (or rely on automated child app sync where configured).

Helpful checks:

- Render infra chart:
  - `helm template infra-apps gitops/infra-helm`
- Render Argo CD install:
  - `kustomize build --enable-helm gitops/argocd`
- Enable Cilium Gateway API and apply shared Gateway:
  - `./cilium/enable-gateway-api.sh`

## Notes

- Cluster-specific hostnames and routing are configured for `homelab.niekvlam.nl`.
- Sensitive credentials are expected to come from external secret backends, not plaintext in Git.
