#!/usr/bin/env bash
set -euo pipefail

NODES_FILE="nodes.yaml"
OUTPUT_DIR="output"
TALOSCTL_BIN="${TALOSCTL_BIN:-talosctl}"
CLUSTER_CONTEXT="${TALOS_CLUSTER_CONTEXT:-homelab}"
SECRETS_FILE="${TALOS_SECRETS_FILE:-$HOME/.talos/$CLUSTER_CONTEXT/secrets.yaml}"
INSTALLER_IMAGE="${TALOS_INSTALLER_IMAGE:-factory.talos.dev/metal-installer/5199ca37666edc3419ae8e1cfe49bdd89f1b5b2995e0078abaa9d710871b6751:v1.12.8}"
INSTALLER_IMAGE_CP="${TALOS_INSTALLER_IMAGE_CONTROLPLANE:-$INSTALLER_IMAGE}"
INSTALLER_IMAGE_WORKER="${TALOS_INSTALLER_IMAGE_WORKER:-$INSTALLER_IMAGE}"
INSTALL_DISK="${TALOS_INSTALL_DISK:-/dev/nvme0n1}"
INSTALL_WIPE="${TALOS_INSTALL_WIPE:-true}"
REGISTRY_MIRROR_HOST="${TALOS_REGISTRY_MIRROR_HOST:-192.168.3.247:5000}"
REGISTRY_MIRROR_ENDPOINT="${TALOS_REGISTRY_MIRROR_ENDPOINT:-http://192.168.3.247:5000}"
KUBERNETES_VERSION="${TALOS_KUBERNETES_VERSION:-1.34.4}"
APPLY_DISK_PATCH_TO_CP="${TALOS_APPLY_DISK_PATCH_TO_CONTROLPLANE:-false}"
ENABLE_VIP="${TALOS_ENABLE_VIP:-true}"
CLUSTER_ENDPOINT_OVERRIDE="${TALOS_CLUSTER_ENDPOINT_OVERRIDE:-}"
MERGE_KUBECONFIG="${TALOS_MERGE_KUBECONFIG:-false}"
KUBECONFIG_CONTEXT="${KUBECONFIG_CONTEXT:-$CLUSTER_CONTEXT}"

# 1. Secrets
[[ -f "$SECRETS_FILE" ]] || {
  echo "🔐 Generating Talos secrets"
  mkdir -p "$(dirname "$SECRETS_FILE")"
  "$TALOSCTL_BIN" gen secrets -o "$SECRETS_FILE"
}
chmod 600 "$SECRETS_FILE"

# 2. Cluster facts
CLUSTER_NAME=$(yq e '.cluster_name' "$NODES_FILE")
VIP=$(yq e '.vip' "$NODES_FILE")
CONTROLPLANE_IP=$(yq e '.nodes[] | select(.role == "controlplane") | .ip' "$NODES_FILE" | head -n 1)
NODE_IPS=($(yq e '.nodes[].ip' "$NODES_FILE"))

if [[ -n "$CLUSTER_ENDPOINT_OVERRIDE" ]]; then
  ENDPOINT="$CLUSTER_ENDPOINT_OVERRIDE"
else
  ENDPOINT=$(yq e '.endpoint' "$NODES_FILE")
fi

# 3. talosconfig (client)
mkdir -p "$OUTPUT_DIR"
"$TALOSCTL_BIN" gen config "$CLUSTER_NAME" "$ENDPOINT" \
  --with-secrets "$SECRETS_FILE" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --output-types talosconfig \
  --output-dir "$OUTPUT_DIR" \
  --force

export TALOSCONFIG="${OUTPUT_DIR}/talosconfig"

if [[ "$ENABLE_VIP" == "true" ]]; then
  "$TALOSCTL_BIN" config endpoint "$VIP"
  "$TALOSCTL_BIN" config node "${NODE_IPS[@]}"
else
  "$TALOSCTL_BIN" config endpoint "$CONTROLPLANE_IP"
  "$TALOSCTL_BIN" config node "${NODE_IPS[@]}"
fi

if [[ "$MERGE_KUBECONFIG" == "true" ]]; then
  "$TALOSCTL_BIN" kubeconfig \
    --talosconfig "$TALOSCONFIG" \
    --merge \
    --force-context-name "$KUBECONFIG_CONTEXT"
fi

MIRROR_PATCH=""
if [[ -n "$REGISTRY_MIRROR_HOST" && -n "$REGISTRY_MIRROR_ENDPOINT" ]]; then
  MIRROR_PATCH=$(yq -n -o=json "
    .machine.registries.mirrors.\"$REGISTRY_MIRROR_HOST\".endpoints = [\"$REGISTRY_MIRROR_ENDPOINT\"]
  ")
fi

# 4. Per-node bootstrap configs
yq -o=json '.nodes[]' "$NODES_FILE" | jq -c '.' | while read -r node; do
  HOST=$(jq -r '.hostname' <<<"$node")
  IP=$(jq -r '.ip' <<<"$node")
  ROLE=$(jq -r '.role' <<<"$node")

  NODE_DIR="$OUTPUT_DIR/$HOST"
  mkdir -p "$NODE_DIR"
  echo "🔧 Generating bootstrap config for $HOST ($ROLE) – $IP"

  if [[ "$ROLE" == "controlplane" ]]; then
    NODE_INSTALLER_IMAGE="$INSTALLER_IMAGE_CP"
  else
    NODE_INSTALLER_IMAGE="$INSTALLER_IMAGE_WORKER"
  fi

  INSTALL_PATCH=$(yq -n -o=json "
    .machine.install.disk = \"$INSTALL_DISK\" |
    .machine.install.image = \"$NODE_INSTALLER_IMAGE\" |
    .machine.install.wipe = ${INSTALL_WIPE}
  ")

  if [[ $ROLE == "controlplane" ]]; then
    if [[ "$ENABLE_VIP" == "true" ]]; then
      NETWORK_PATCH=$(yq -n -o=json "
      .machine.network.hostname = \"$HOST\" |
      .machine.network.interfaces[0].interface = \"end0\" |
      .machine.network.interfaces[0].addresses = [\"$IP/24\"] |
      .machine.network.interfaces[0].dhcp = false |
      .machine.network.interfaces[0].routes[0].network = \"0.0.0.0/0\" |
      .machine.network.interfaces[0].routes[0].gateway = \"192.168.3.1\" |
      .machine.network.nameservers = [\"192.168.3.1\", \"1.1.1.1\"] |
      .machine.network.interfaces[0].vip.ip = \"$VIP\"
    ")
    else
      NETWORK_PATCH=$(yq -n -o=json "
      .machine.network.hostname = \"$HOST\" |
      .machine.network.interfaces[0].interface = \"end0\" |
      .machine.network.interfaces[0].addresses = [\"$IP/24\"] |
      .machine.network.interfaces[0].dhcp = false |
      .machine.network.interfaces[0].routes[0].network = \"0.0.0.0/0\" |
      .machine.network.interfaces[0].routes[0].gateway = \"192.168.3.1\" |
      .machine.network.nameservers = [\"192.168.3.1\", \"1.1.1.1\"]
    ")
    fi
  else
    NETWORK_PATCH=$(yq -n -o=json "
    .machine.network.hostname = \"$HOST\" |
    .machine.network.interfaces[0].interface = \"end0\" |
    .machine.network.interfaces[0].addresses = [\"$IP/24\"] |
    .machine.network.interfaces[0].dhcp = false |
    .machine.network.interfaces[0].routes[0].network = \"0.0.0.0/0\" |
    .machine.network.interfaces[0].routes[0].gateway = \"192.168.3.1\" |
    .machine.network.nameservers = [\"192.168.3.1\", \"1.1.1.1\"]
  ")
  fi

  PATCH_ARGS=(
    --config-patch "$(yq -o=json <patches/$ROLE.yaml)"
    --config-patch "$NETWORK_PATCH"
    --config-patch "$INSTALL_PATCH"
  )

  # Keep Longhorn user volume on workers by default; opt-in on controlplane for debugging.
  if [[ "$ROLE" == "worker" || "$APPLY_DISK_PATCH_TO_CP" == "true" ]]; then
    PATCH_ARGS+=(--config-patch @patches/disk.yaml)
  fi

  "$TALOSCTL_BIN" gen config "$CLUSTER_NAME" "$ENDPOINT" \
    --with-secrets "$SECRETS_FILE" \
    --kubernetes-version "$KUBERNETES_VERSION" \
    "${PATCH_ARGS[@]}" \
    --output-types "$ROLE" \
    --output-dir "$NODE_DIR" \
    --force

  if [[ -n "$MIRROR_PATCH" ]]; then
    "$TALOSCTL_BIN" machineconfig patch "$NODE_DIR/$ROLE.yaml" \
      -p "$MIRROR_PATCH" \
      -o "$NODE_DIR/$ROLE.yaml"
  fi

  # Keep only the file Talos expects on the USB/metadata-service
  mv "$NODE_DIR/$ROLE.yaml" "$NODE_DIR/machineconfig.yaml"

  # Talos 1.12 rejects static machine.network.hostname combined with HostnameConfig auto mode.
  # Drop HostnameConfig docs so generated configs are apply-safe during recovery.
  yq e 'select(.kind != "HostnameConfig")' "$NODE_DIR/machineconfig.yaml" > "$NODE_DIR/machineconfig.yaml.tmp"
  mv "$NODE_DIR/machineconfig.yaml.tmp" "$NODE_DIR/machineconfig.yaml"
done

echo "✅  Bootstrap configs ready in $OUTPUT_DIR/"
