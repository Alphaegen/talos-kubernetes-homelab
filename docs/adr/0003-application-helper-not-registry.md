# Child Applications go through a helper, one template file each, not a values registry

Each child Application keeps its own template file that describes it as a small YAML block and passes it to the `infra.application` helper in `_helpers.tpl`, which emits the shared skeleton and enforces the rules (waves, projects, deletion flags). We did not move the Applications into a single `apps:` list in `values.yaml` rendered by one `range` template.

## Considered Options

- **Values registry with one `range` template** (as the oauth2-proxy instances already do). More leverage, but the irregular Applications (Kyverno's pre-delete finalizer and server-side diff, Grafana's dashboards and Secret ignores, Home Assistant's StatefulSet ignores, inline chart values) would need an ever-growing escape hatch until the registry entry is as wide as an Application spec, and Renovate's `# renovate:` annotation must sit directly above each `version:` line, which constrains how the list can be nested. Worth revisiting only for the uniform apps-project workloads, and only once the inline chart values have moved to upstream values files.
