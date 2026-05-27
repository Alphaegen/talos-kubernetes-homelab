#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KUSTOMIZE_BIN="${KUSTOMIZE_BIN:-kustomize}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.1}"
INSTALL_TLSROUTE="${INSTALL_TLSROUTE:-false}"
DEFAULT_KUBECONFIG_PATH="${SCRIPT_DIR}/../kubeconfig"

KUBECTL_ARGS=()
if [[ -n "${KUBECONFIG_PATH:-}" ]]; then
  KUBECTL_ARGS+=(--kubeconfig "${KUBECONFIG_PATH}")
elif [[ -f "${DEFAULT_KUBECONFIG_PATH}" ]]; then
  KUBECTL_ARGS+=(--kubeconfig "${DEFAULT_KUBECONFIG_PATH}")
fi

kc() {
  "${KUBECTL_BIN}" "${KUBECTL_ARGS[@]}" "$@"
}

for bin in "${KUBECTL_BIN}" "${KUSTOMIZE_BIN}"; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "missing required binary: ${bin}" >&2
    exit 1
  fi
done

required_crds=(
  gatewayclasses
  gateways
  httproutes
  referencegrants
  grpcroutes
)

echo "==> Installing Gateway API CRDs (${GATEWAY_API_VERSION})"
for crd in "${required_crds[@]}"; do
  kc apply --server-side -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml"
done

if [[ "${INSTALL_TLSROUTE}" == "true" ]]; then
  echo "==> Installing TLSRoute CRD (${GATEWAY_API_VERSION})"
  kc apply --server-side -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml"
fi

echo "==> Applying Cilium with Gateway API enabled"
"${KUSTOMIZE_BIN}" build --enable-helm "${SCRIPT_DIR}" | kc apply -f -

echo "==> Restarting Cilium control plane components"
kc -n kube-system rollout restart deployment/cilium-operator
kc -n kube-system rollout restart ds/cilium
kc -n kube-system rollout status deployment/cilium-operator --timeout=5m
kc -n kube-system rollout status ds/cilium --timeout=10m

echo "==> Applying shared Cilium Gateway"
kc apply -k "${SCRIPT_DIR}/gateway-api"

echo "==> Verifying Gateway API resources"
kc get gatewayclass
kc -n kube-system get gateway cilium-gateway
