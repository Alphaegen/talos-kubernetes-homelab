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
