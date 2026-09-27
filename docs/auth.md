# Authentication and Break-Glass Access

All platform UIs sign in through one OIDC identity provider,
[Pocket ID](https://pocket-id.org), at `https://id.homelab.niekvlam.nl`. Users
log in with passkeys. Access is granted through the `homelab-admins` group,
which every OIDC client is restricted to in Pocket ID and which the clients
check again on their side.

| UI | How it signs in | Pocket ID client |
|---|---|---|
| Argo CD (web) | Native OIDC, `g, homelab-admins, role:admin` | `Argo CD` (confidential) |
| Argo CD (CLI) | `argocd login argocd.homelab.niekvlam.nl --sso` (PKCE) | `Argo CD CLI` (public) |
| Grafana | Native `auth.generic_oauth`, `homelab-admins` → Grafana server admin | `Grafana` |
| Longhorn | oauth2-proxy `oauth2-proxy-longhorn` in `auth` | `Longhorn` |
| Hubble UI | oauth2-proxy `oauth2-proxy-hubble` in `auth` | `Hubble` |

Longhorn UI and Hubble UI have no login of their own, so oauth2-proxy owns
their HTTPRoutes and a CiliumNetworkPolicy lets only the matching proxy reach
each UI pod. Client IDs and secrets live in 1Password and reach the cluster
through ExternalSecrets; see the table at the end.

## Pocket ID state

- Pocket ID runs as a single replica (`auth/pocket-id-0`) with SQLite on the
  Longhorn volume `pocket-id-data`, which the nightly `backup-all` recurring
  job backs up to the NAS.
- The database is encrypted with `ENCRYPTION_KEY_FILE` from the 1Password item
  `pocket-id` (field `encryption-key`). A backup is useless without that key;
  never rotate or delete it without `pocket-id encryption-key-rotate`.

## Break-glass procedures

`kubectl` access does not depend on Pocket ID, so every procedure below starts
from a working kubeconfig.

### Lost passkey or locked-out user

Generate a one-time login link, valid for one hour, and open it in a browser
to register a new passkey:

```bash
kubectl -n auth exec pocket-id-0 -- /app/pocket-id one-time-access-token <username-or-email>
```

### Pocket ID is down: Longhorn and Hubble UI

Port-forwarding enters the pod from the node, which the UI network policies
allow, and skips oauth2-proxy:

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
kubectl -n kube-system port-forward svc/hubble-ui 8081:80
```

### Pocket ID is down: Argo CD

The local `admin` account is disabled (`admin.enabled: false` in
`gitops/argocd/helm-values.yaml`). In order of preference:

1. **Core mode.** The CLI talks to the Kubernetes API directly with your
   kubeconfig and needs no Argo CD login:

   ```bash
   argocd login --core
   kubectl config set-context --current --namespace=argocd
   argocd app list
   argocd app sync <app>
   ```

2. **Temporarily re-enable `admin`.** The password (bcrypt) stays in sync from
   the 1Password item `argocd-account` through the `argocd-admin-password`
   ExternalSecret. Keep the plain-text password in 1Password as well; the
   hash alone cannot be used to log in.

   ```bash
   kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"admin.enabled":"true"}}'
   ```

   Log in as `admin`, fix the problem, then switch it off again by
   re-applying Argo CD. `--force-conflicts` takes the field back from the
   `kubectl patch` above:

   ```bash
   kustomize build --enable-helm gitops/argocd | kubectl apply --server-side --force-conflicts -f -
   ```

### Pocket ID is down: Grafana

The login form is hidden (`auth.disable_login_form: true`), but the local
`admin` user still works over the HTTP API with basic auth. Its password is in
the chart-managed Secret `monitoring/grafana` (key `admin-password`):

```bash
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

For the web UI, set `disable_login_form: false` in
`gitops/infra-custom/monitoring/grafana-values.yaml` and let Argo CD sync it
(use `argocd --core` if Argo CD SSO is down too), then revert it afterwards.

## Secrets in 1Password

| Item | Fields | Used by |
|---|---|---|
| `pocket-id` | `encryption-key` | Pocket ID database encryption |
| `argocd-oidc` | `client-id`, `client-secret`, `cli-client-id` | Argo CD SSO |
| `argocd-account` | `passwordBcrypt`, `passwordMtime` | Argo CD break-glass `admin` |
| `grafana-oidc` | `client-id`, `client-secret` | Grafana SSO |
| `oauth2-proxy-longhorn` | `client-id`, `client-secret`, `cookie-secret` | Longhorn oauth2-proxy |
| `oauth2-proxy-hubble` | `client-id`, `client-secret`, `cookie-secret` | Hubble oauth2-proxy |

Adding another proxied UI: create a Pocket ID client with callback
`https://<host>/oauth2/callback` and group `homelab-admins`, a matching
`oauth2-proxy-<name>` 1Password item, a
`gitops/infra-custom/oauth2-proxy/<name>-values.yaml`, and add `<name>` to
`security.oauth2Proxy.instances` in `gitops/infra-helm/values.yaml`.
