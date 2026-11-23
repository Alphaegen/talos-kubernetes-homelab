# Child Applications use exactly three sync waves

Child Applications use sync waves 0 (foundations and CRD providers), 1 (platform add-ons) and 2 (workloads), and nothing else. Independently auto-syncing child Applications make waves an ordering hint for a fresh bootstrap, not a readiness scheduler, so a dependency between Applications (a CR whose CRD another Application installs, oauth2-proxy waiting for Pocket ID's OIDC discovery) is handled by `SkipDryRunOnMissingResource=true` and the shared retry backoff, not by adding a wave. The `infra.application` helper fails the render for any other wave.

## Considered Options

- **A fourth wave for oauth2-proxy** (it briefly had wave 3, because it needs Pocket ID at startup). Rejected: it only helps a fresh bootstrap, where oauth2-proxy restarts until Pocket ID answers anyway, and every extra wave invites the next one.
