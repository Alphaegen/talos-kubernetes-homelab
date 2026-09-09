#!/usr/bin/env bash
set -euo pipefail

NODES_FILE="${TALOS_NODES_FILE:-nodes.yaml}"
OUTPUT_DIR="${TALOS_OUTPUT_DIR:-output}"
TALOSCONFIG="${TALOSCONFIG:-$HOME/.talos/config}"
TALOS_CONTEXT="${TALOS_CONTEXT:-home-cluster}"
TALOSCTL_BIN="${TALOSCTL_BIN:-talosctl}"
TARGET_HOST="${1:-}"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [hostname]"
  exit 1
fi

# Ensure talosconfig exists
if [[ ! -f "$TALOSCONFIG" ]]; then
  echo "❌ talosconfig not found at $TALOSCONFIG"
  exit 1
fi

export TALOSCONFIG

if [[ -n "$TARGET_HOST" ]]; then
  if ! yq e -e ".nodes[] | select(.hostname == \"$TARGET_HOST\")" "$NODES_FILE" >/dev/null; then
    echo "❌ Hostname $TARGET_HOST not found in $NODES_FILE"
    exit 1
  fi

  CONFIGS=("$OUTPUT_DIR/$TARGET_HOST/machineconfig.yaml")
else
  shopt -s nullglob
  CONFIGS=("$OUTPUT_DIR"/*/machineconfig.yaml)
fi

if [[ ${#CONFIGS[@]} -eq 0 ]]; then
  echo "❌ No generated machine configs found under $OUTPUT_DIR"
  exit 1
fi

# Apply either the selected node or every generated machine config.
for config in "${CONFIGS[@]}"; do
  if [[ ! -f "$config" ]]; then
    echo "❌ Generated machine config not found: $config"
    exit 1
  fi

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

echo "✅ Requested machine config(s) applied."
