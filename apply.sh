#!/usr/bin/env bash
set -euo pipefail

NODES_FILE="nodes.yaml"
OUTPUT_DIR="output"
TALOSCONFIG="${TALOSCONFIG:-$HOME/.talos/config}"
TALOS_CONTEXT="${TALOS_CONTEXT:-home-cluster}"
TALOSCTL_BIN="${TALOSCTL_BIN:-talosctl}"

# Ensure talosconfig exists
if [[ ! -f "$TALOSCONFIG" ]]; then
  echo "❌ talosconfig not found at $TALOSCONFIG"
  exit 1
fi

export TALOSCONFIG

# Loop over each machineconfig.yaml
for config in "$OUTPUT_DIR"/*/machineconfig.yaml; do
  NODE_DIR=$(dirname "$config")
  HOSTNAME=$(basename "$NODE_DIR")

  # Extract IP from nodes.yaml using yq
  NODE_IP=$(yq e ".nodes[] | select(.hostname == \"$HOSTNAME\") | .ip" "$NODES_FILE")

  if [[ -z "$NODE_IP" || "$NODE_IP" == "null" ]]; then
    echo "⚠️  Could not find IP for $HOSTNAME in $NODES_FILE, skipping."
    continue
  fi

  echo "🚀 Applying config to $HOSTNAME ($NODE_IP)"
  "$TALOSCTL_BIN" --context "$TALOS_CONTEXT" apply-config --nodes "$NODE_IP" --file "$config"
done

echo "✅ All machine configs applied."
