#!/usr/bin/env bash
set -euo pipefail

# Pull the External Secrets 1Password service-account token from 1Password
# and (re)create the bootstrap Kubernetes Secret that the ClusterSecretStore uses.
#
# Usage:
#   ./bootstrap_onepassword_service_account_token.sh
#   ./bootstrap_onepassword_service_account_token.sh op://Homelab/external-secrets-onepassword-service-account-token/token

OP_PATH="${1:-op://Homelab/external-secrets-onepassword-service-account-token/token}"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-external-secrets}"
SECRET_NAME="${SECRET_NAME:-onepassword-service-account-token}"

if ! command -v op >/dev/null 2>&1; then
  echo "error: 1Password CLI (op) is required" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl is required" >&2
  exit 1
fi

token="$(op read "${OP_PATH}")"
if [[ -z "${token}" ]]; then
  echo "error: token at ${OP_PATH} is empty" >&2
  exit 1
fi

kubectl -n "${SECRET_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=token="${token}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "updated ${SECRET_NAMESPACE}/${SECRET_NAME} from ${OP_PATH}"
