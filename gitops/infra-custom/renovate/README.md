# Self-hosted Renovate

Renovate runs once per day at 06:00 Europe/Amsterdam and processes only
`Alphaegen/talos-kubernetes-homelab`.

The GitHub fine-grained personal access token is synchronized by External
Secrets from the `Homelab` 1Password vault:

- item: `Renovate-Homelab Github Token`
- field: `token`
- Kubernetes Secret: `renovate/renovate-github`

The token is exposed to the job as `RENOVATE_TOKEN`; it is never stored in Git.
Repository-specific behavior remains in the root `renovate.json`.

After Argo CD has synchronized the application, verify the ExternalSecret and
start the first run manually:

```bash
kubectl -n renovate get externalsecret renovate-github
kubectl -n renovate create job --from=cronjob/renovate renovate-manual
kubectl -n renovate logs -f job/renovate-manual
```

Disable or uninstall the Mend-hosted Renovate app only after this run finishes
successfully. Running both installations at the same time can make them compete
over the same Renovate branches and pull requests.
