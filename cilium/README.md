# Cilium Operations

## Enable Gateway API

This repo includes a helper that installs the Gateway API prerequisite used by
Cilium. Cilium itself is rendered and applied separately through the reviewed
Kustomize-to-`kubectl apply` upgrade procedure.

Run from `cluster/`:

```bash
./cilium/enable-gateway-api.sh
```

What it does:

It installs the pinned Gateway API **v1.6.1 Standard** bundle, including the
existing Gateway/HTTPRoute APIs and the required BackendTLSPolicy, ListenerSet,
TCPRoute, TLSRoute, and UDPRoute CRDs. It intentionally does not install the
Experimental bundle, mutate Cilium, restart Cilium, or repair Gateway routes.

For a Cilium upgrade, first apply this prerequisite and verify Gateway and
HTTPRoute conditions. Then render `cilium/` with `kustomize build --enable-helm`,
review the diff and server-side dry-run, run the target Cilium preflight, and
apply that same reviewed manifest with `kubectl apply -f`.

## Shared Gateway

- Name: `cilium-gateway`
- Namespace: `kube-system`
- Address: `192.168.20.112` (MetalLB pool `servers`)
- Listeners (hostname `*.homelab.niekvlam.nl`):
  - `http` (port `80`): only the HTTP-to-HTTPS redirect route in `kube-system`
  - `https` (port `443`): terminates TLS with the cert-manager wildcard
    certificate `homelab-wildcard-tls`; routes from all namespaces

The Gateway, wildcard `Certificate`, and redirect `HTTPRoute` are managed by the
Argo CD application `homelab-gateway` from `gitops/infra-custom/gateway/`. The
`cilium-ipv4` GatewayClass and its `CiliumGatewayClassConfig` stay in
`cilium/gateway-api/` and are applied manually (`kubectl apply -k cilium/gateway-api`).

`HTTPRoute` resources should reference the HTTPS listener and disable the route
timeout, because Cilium otherwise leaves Envoy's 15s default in place:

```yaml
parentRefs:
  - name: cilium-gateway
    namespace: kube-system
    sectionName: https
rules:
  - timeouts:
      request: 0s
```

Gateway traffic reaches backends with Cilium's reserved `ingress` identity, which
a Kubernetes `NetworkPolicy` namespace selector cannot match. Backends with
ingress NetworkPolicies need a `CiliumNetworkPolicy` allowing
`fromEntities: [ingress]` to the backend port.
