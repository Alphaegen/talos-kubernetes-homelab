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
- Listener: `http` (port `80`)
- Hostname: `*.homelab.niekvlam.nl`

`HTTPRoute` resources should reference this with:

```yaml
parentRefs:
  - name: cilium-gateway
    namespace: kube-system
    sectionName: http
```
