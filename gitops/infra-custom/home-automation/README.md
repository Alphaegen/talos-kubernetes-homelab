# Home Automation Support Stack (Mosquitto + Zigbee2MQTT)

This chart deploys an in-cluster MQTT broker (Mosquitto) and Zigbee2MQTT for a remote SMLIGHT SLZB coordinator over Ethernet.

## What This Deploys

- Namespace: `home-automation` (dedicated support namespace)
- MQTT broker: Mosquitto (`ClusterIP` only)
- Zigbee bridge: Zigbee2MQTT with persistent `/app/data`
- Secrets: `ExternalSecret` (1Password/ESO) by default, with optional fallback `Secret`
- Frontend: Zigbee2MQTT UI via TLS ingress

## Zigbee2MQTT Configuration

The rendered `configuration.yaml` is written into the writable PVC at startup and includes:

- `mqtt.server`
- `mqtt.user`
- `mqtt.password`
- `serial.port: tcp://<SLZB-IP>:6638`
- `homeassistant.enabled: true`
- `frontend.enabled: true`

The init container only seeds `configuration.yaml` when the file does not already exist, so Zigbee2MQTT-managed updates (for example generated network key) persist across restarts.

Sample config file:

- `./zigbee2mqtt-configuration.sample.yaml`

## Prerequisites

1. External Secrets Operator is available (already present in this repo when `security.eso.enabled=true`).
1. The configured secret backend path (default: `mqtt-zigbee/username` and `mqtt-zigbee/password`) contains valid MQTT credentials.
1. SLZB adapter has a stable DHCP reservation/IP (default in values: `192.168.3.232`) and TCP adapter port `6638` is reachable from cluster nodes.

## Rollout

1. Update values if needed in:
   - `gitops/infra-helm/values.yaml` (`homeAutomation.*`)
1. Commit and push the GitOps changes.
1. Sync ArgoCD application:
   - `homelab.niekvlam-home-automation`
1. Confirm resources:
   - `kubectl -n home-automation get deploy,po,svc,pvc,ingress,secret,externalsecret`

## Validation

1. Confirm network reachability from the cluster to the SLZB adapter:
   - `kubectl -n home-automation run slzb-check --image=busybox:1.36 --restart=Never --rm -it -- nc -vz -w 3 192.168.3.232 6638`
1. Confirm Zigbee2MQTT starts with coordinator and MQTT connected:
   - `kubectl -n home-automation logs deploy/zigbee2mqtt --tail=200`
   - Look for successful coordinator initialization and MQTT connection messages.
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
- If you already use ingress auth (oauth2-proxy), set `homeAutomation.zigbee2mqtt.ingress.auth.*` values to reuse that flow.
