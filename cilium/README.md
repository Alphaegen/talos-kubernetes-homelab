# Cilium Operations

## Enable Gateway API (Cilium 1.19.4)

This repo now includes a helper script to enable Cilium Gateway API support and create a shared Gateway used by app `HTTPRoute` resources.

Run from `cluster/`:

```bash
./cilium/enable-gateway-api.sh
```

What it does:

1. Installs required Gateway API CRDs (v1.4.1): `GatewayClass`, `Gateway`, `HTTPRoute`, `ReferenceGrant`, `GRPCRoute`.
2. Applies `cluster/cilium/` (Helm via Kustomize), including `gatewayAPI.enabled=true`.
3. Restarts Cilium operator/agents.
4. Applies shared Gateway manifest at `cilium/gateway-api/cilium-gateway.yaml`.

Optional TLSRoute CRD install:

```bash
INSTALL_TLSROUTE=true ./cilium/enable-gateway-api.sh
```

## Shared Gateway

- Name: `cilium-gateway`
- Namespace: `kube-system`
- Listener: `http` (port `80`)
- Hostname: `*.homelab.niekvlam.nl`

`HTTPRoute` resources should reference this with:

```yaml
parentRefs:
  - name: cilium-gateway
    namespace: kube-system
    sectionName: http
```
