# Keycloak integration ownership

Keycloak remains disabled in `gitops/infra-helm/values.yaml`.

When it is enabled later, this chart owns Keycloak-specific integration
resources such as `ExternalSecret` objects and the Home Assistant OAuth proxy.
It deliberately does not own Argo CD's `argocd-cm`/`argocd-secret` resources or
Grafana's `Deployment`:

- Argo CD's dormant OIDC configuration is kept in
  `gitops/argocd/helm-values-keycloak.yaml` and must be enabled through the Argo
  CD installation values.
- Grafana's OIDC settings and secret mount are conditionally rendered by the
  Grafana Application when Keycloak is enabled.
- The `oidc-argocd` ExternalSecret uses `creationPolicy: Merge`, so it adds only
  the client credential keys to the Argo CD-owned Secret.

Enabling Keycloak should therefore be a reviewed change that also activates the
Argo CD values file; this repository does not enable it automatically.
