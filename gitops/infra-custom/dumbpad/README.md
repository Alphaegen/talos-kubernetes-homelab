# DumbPad

[DumbPad](https://github.com/DumbWareio/DumbPad) is a shared notepad for
copying text between devices: open `https://pad.homelab.niekvlam.nl` anywhere
and every device sees the same notepads. Edits sync live between open tabs.

## Architecture

- Single Node.js pod; notepads are plain `.txt` files plus `notepads.json` on a
  1 GiB Longhorn volume, so the nightly Longhorn backup covers them.
- HTTPS through the shared Cilium Gateway; only the Gateway may reach port 3000.
- Non-root, read-only root filesystem. DumbPad rewrites its PWA manifests in
  `public/Assets` at startup, so an init container copies the shipped assets
  into a writable `emptyDir`.
- `ALLOWED_ORIGINS` limits CORS and the WebSocket to the pad's own hostname, so
  other websites cannot read notes through a browser on the LAN.

## Access

There is no login. The Gateway address is only reachable from the LAN and the
tailnet, so anyone on either can read and edit the notes. Don't keep secrets
in it.

## Adding Pocket ID later

DumbPad has no OIDC support, so put it behind its own oauth2-proxy instance,
like the Longhorn and Hubble UIs:

1. Create an OIDC client in Pocket ID restricted to `homelab-admins`, with
   callback `https://pad.homelab.niekvlam.nl/oauth2/callback`, and store its
   credentials in 1Password.
2. Add an oauth2-proxy release in `gitops/infra-custom/oauth2-proxy` that owns
   the `pad.homelab.niekvlam.nl` HTTPRoute (with `timeouts.request: 0s` for the
   WebSocket) and upstreams to `http://dumbpad.dumbpad.svc:3000`.
3. Remove `httproute.yaml` here and change the CiliumNetworkPolicy to allow
   only the oauth2-proxy pod in `auth` instead of the `ingress` entity.

oauth2-proxy passes WebSocket upgrades through, so live sync keeps working.
