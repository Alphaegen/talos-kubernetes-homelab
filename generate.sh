#!/usr/bin/env bash
set -euo pipefail

SECRETS_FILE="secrets.yaml"
NODES_FILE="nodes.yaml"
OUTPUT_DIR="output"

# 1. Secrets
[[ -f $SECRETS_FILE ]] || {
  echo "🔐 Generating Talos secrets"
  talosctl gen secrets -o "$SECRETS_FILE"
}

# 2. Cluster facts
CLUSTER_NAME=$(yq e '.cluster_name' "$NODES_FILE")
ENDPOINT=$(yq e '.endpoint' "$NODES_FILE")
VIP=$(yq e '.vip' "$NODES_FILE")

# 3. talosconfig (client)
mkdir -p "$OUTPUT_DIR"
talosctl gen config "$CLUSTER_NAME" "$ENDPOINT" \
  --with-secrets "$SECRETS_FILE" \
  --output-types talosconfig \
  --output-dir "$OUTPUT_DIR" \
  --force

export TALOSCONFIG="${OUTPUT_DIR}/talosconfig"

talosctl config endpoint "$VIP"
talosctl config node "$VIP"

# 4. Per-node bootstrap configs
yq -o=json '.nodes[]' "$NODES_FILE" | jq -c '.' | while read -r node; do
  HOST=$(jq -r '.hostname' <<<"$node")
  IP=$(jq -r '.ip' <<<"$node")
  ROLE=$(jq -r '.role' <<<"$node")

  NODE_DIR="$OUTPUT_DIR/$HOST"
  mkdir -p "$NODE_DIR"
  echo "🔧 Generating bootstrap config for $HOST ($ROLE) – $IP"

  if [[ $ROLE == "controlplane" ]]; then
    NETWORK_PATCH=$(yq -n -o=json "
    .machine.network.hostname = \"$HOST\" |
    .machine.network.interfaces[0].interface = \"end0\" |
    .machine.network.interfaces[0].addresses = [\"$IP/24\"] |
    .machine.network.interfaces[0].dhcp = false |
    .machine.network.interfaces[0].routes[0].network = \"0.0.0.0/0\" |
    .machine.network.interfaces[0].routes[0].gateway = \"192.168.3.1\" |
    .machine.network.interfaces[0].vip.ip = \"$VIP\"
  ")
  else
    NETWORK_PATCH=$(yq -n -o=json "
    .machine.network.hostname = \"$HOST\" |
    .machine.network.interfaces[0].interface = \"end0\" |
    .machine.network.interfaces[0].addresses = [\"$IP/24\"] |
    .machine.network.interfaces[0].dhcp = false |
    .machine.network.interfaces[0].routes[0].network = \"0.0.0.0/0\" |
    .machine.network.interfaces[0].routes[0].gateway = \"192.168.3.1\"
  ")
  fi

  talosctl gen config "$CLUSTER_NAME" "$ENDPOINT" \
    --with-secrets "$SECRETS_FILE" \
    --config-patch "$(yq -o=json <patches/$ROLE.yaml)" \
    --config-patch "$NETWORK_PATCH" \
    --output-types "$ROLE" \
    --output-dir "$NODE_DIR" \
    --force

  # Keep only the file Talos expects on the USB/metadata-service
  mv "$NODE_DIR/$ROLE.yaml" "$NODE_DIR/machineconfig.yaml"
done

echo "✅  Bootstrap configs ready in $OUTPUT_DIR/"
