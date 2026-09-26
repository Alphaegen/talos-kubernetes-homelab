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
apply that same reviewed manifest as described below.

## Apply a configuration change

Render once and split the output, so the reviewed files are exactly what gets
applied:

```bash
kustomize build --enable-helm cilium > /tmp/cilium.yaml
yq 'select(.kind != "Secret" and .metadata.labels.grafana_dashboard != "1")' /tmp/cilium.yaml > /tmp/cilium-main.yaml
yq 'select(.kind == "ConfigMap" and .metadata.labels.grafana_dashboard == "1")' /tmp/cilium.yaml > /tmp/cilium-dashboards.yaml
kubectl diff -f /tmp/cilium-main.yaml
kubectl apply --dry-run=server -f /tmp/cilium-main.yaml
kubectl apply --server-side --dry-run=server -f /tmp/cilium-dashboards.yaml
```

- The chart generates a new Hubble CA and certificates (`cilium-ca`,
  `hubble-server-certs`, `hubble-relay-client-certs`) on every render. Leave
  these Secrets out unless you mean to rotate them.
- The Grafana dashboard ConfigMaps are too large for client-side apply, so they
  are applied server-side.

After review, apply both files:

```bash
kubectl apply -f /tmp/cilium-main.yaml
kubectl apply --server-side -f /tmp/cilium-dashboards.yaml
kubectl -n kube-system rollout status ds/cilium
```

## Metrics and dashboards

The agent, operator, Envoy and Hubble expose Prometheus metrics. Their
ServiceMonitors carry `release: kube-prometheus-stack`, and the chart's Grafana
dashboards are loaded by the Grafana dashboard sidecar. Hubble metrics use
namespace-level labels (workload labels for `httpV2` only) and no IP labels, to
keep series counts small.

The ServiceMonitor kind comes from kube-prometheus-stack, which Argo CD installs
after Cilium. On a new cluster, `kubectl apply` reports the ServiceMonitors as
unknown kinds and applies everything else; apply the manifest again once
kube-prometheus-stack is running.

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
