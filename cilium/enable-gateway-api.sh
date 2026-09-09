#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
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

for bin in "${KUBECTL_BIN}"; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "missing required binary: ${bin}" >&2
    exit 1
  fi
done

echo "==> Installing Gateway API Standard CRDs (${GATEWAY_API_VERSION})"
kc apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "==> Verifying Gateway API resources"
kc get gatewayclass
kc -n kube-system get gateway cilium-gateway
