# External Secrets + 1Password

## Bootstrap Caveat

`external-secrets/onepassword-service-account-token` is a bootstrap secret.
It **cannot** be sourced by `ExternalSecret` itself because ESO needs this
token before it can read from 1Password.

Recommended pattern:

1. Keep the token in 1Password as backup/source of truth.
2. Bootstrap or rotate the in-cluster secret from 1Password with:

```bash
./gitops/infra-custom/external-secrets/scripts/bootstrap_onepassword_service_account_token.sh
```

## 1Password Items Used

- `external-secrets-onepassword-service-account-token`
  - field: `token`
- `argocd-repo`
  - field: `sshPrivateKey`

## Argo Repo Secrets via ESO

The chart now renders `ExternalSecret` resources to manage Argo repository
credentials in `argocd` namespace.

They write into existing secret names:

- `repo-1798823262` (project `default`)
- `repo-1485164468` (project `homelab.niekvlam`)

Only `sshPrivateKey` comes from 1Password; repo metadata stays in GitOps.
