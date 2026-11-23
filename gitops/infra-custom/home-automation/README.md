# Home Automation Support Stack (Mosquitto + Zigbee2MQTT)

Plain manifests (a kustomization) for an in-cluster MQTT broker (Mosquitto) and Zigbee2MQTT for a remote SMLIGHT SLZB coordinator over Ethernet.

## What This Deploys

- `namespace.yaml`: the `home-automation` namespace
- `externalsecret.yaml`: the MQTT credentials from 1Password (`mqtt-zigbee/username` and `mqtt-zigbee/password`)
- `mosquitto.yaml`: the MQTT broker (`ClusterIP` only) with its config and data volume
- `zigbee2mqtt.yaml`: the Zigbee bridge with persistent `/app/data`, and its UI through the shared Cilium Gateway (HTTPRoute)

Both run at `homelab-home-critical` priority, non-root with read-only root filesystems.

## Zigbee2MQTT Configuration

The `render-configuration` init container in `zigbee2mqtt.yaml` writes `configuration.yaml` into the data volume from its environment (the MQTT server and credentials, and the coordinator `tcp://192.168.30.232:6638` with adapter `zstack`) only when the file does not exist yet, so Zigbee2MQTT-managed updates (for example the generated network key) persist across restarts. For an existing file it only adds missing `serial` settings, to prevent startup failures after Zigbee2MQTT updates. A `wait-for-slzb` init container holds the pod until the coordinator's TCP port answers.

## Prerequisites

1. External Secrets Operator and the `onepassword` ClusterSecretStore are available.
1. The 1Password item `mqtt-zigbee` contains valid MQTT credentials.
1. The SLZB adapter has a stable DHCP reservation (`192.168.30.232`) and TCP port `6638` is reachable from the cluster nodes.

## Validation

1. Confirm network reachability from the cluster to the SLZB adapter:
   - `kubectl -n home-automation run slzb-check --image=busybox:1.36 --restart=Never --rm -it -- nc -vz -w 3 192.168.30.232 6638`
1. Confirm Zigbee2MQTT starts with coordinator and MQTT connected:
   - `kubectl -n home-automation logs deploy/zigbee2mqtt --tail=200`
   - Look for successful coordinator initialization and MQTT connection messages.
   - If it still fails on adapter detection, verify SLZB is in Zigbee coordinator mode (not Thread) in the SLZB web UI.
1. Confirm Home Assistant MQTT discovery:
   - In Home Assistant, configure MQTT integration to use:
     - Host: `mosquitto.home-automation.svc.cluster.local`
     - Port: `1883`
     - Username/Password: same credentials used by Zigbee2MQTT
   - Verify Zigbee2MQTT devices appear automatically via discovery.
1. Confirm pairing through frontend:
   - Open `https://zigbee2mqtt.homelab.niekvlam.nl`
   - Enable permit join and pair a test Zigbee device.

## Notes

- Mosquitto is intentionally exposed only as `ClusterIP`.
- Zigbee2MQTT is configured for remote network adapter mode (`tcp://...:6638`), with no USB passthrough/privileged host device mapping.
- The Zigbee2MQTT UI is exposed only through the shared Cilium Gateway, which offers no IP allowlisting or oauth2-proxy auth-request support; any authentication must be added in front of or inside Zigbee2MQTT itself.
