# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Talos Linux + Argo CD homelab on four Raspberry Pi 5 nodes (one control plane, three workers). The GitHub repository is **public**: never write secret values, kubeconfig/talosconfig contents, or generated machine configs into tracked files, and never print them. `output/`, `talosconfig` and `secrets.yaml` are gitignored; `.private/` (roadmap and plans) and `.claude/` are local-only via `.git/info/exclude`.

## Commands

```bash
scripts/validate.sh                      # the full check; the gating steps of the CI "Validate" job
RENDER_DIR=/tmp/rendered scripts/validate.sh   # keep rendered manifests (dir must not exist yet)
scripts/render-diff.sh [base-ref]        # how the rendered Applications differ from a ref (default HEAD)
```

`validate.sh` needs bash 4+ (`declare -A`; Homebrew bash on macOS), `helm`, `kustomize`, `kubeconform`, `yq` (mikefarah), `jq`, `go` and the `kyverno` CLI. It prints PASS/FAIL per step and only shows a step's output when it fails.

Narrower checks:

```bash
helm template infra-apps gitops/infra-helm                       # the Application chart
helm template infra-apps gitops/infra-helm -f gitops/infra-helm/ci/all-enabled-values.yaml
kustomize build --enable-helm gitops/infra-custom/<name>          # one kustomize source
kustomize build --enable-helm gitops/argocd                       # manually applied Argo CD
kyverno test gitops/infra-custom/kyverno/tests/<policy>           # one policy suite
cd gitops/infra-custom/pi5-fan-control && go test ./internal/curve -run TestName
```

Talos: `generate.sh` renders client config and per-node machine configs into `output/<hostname>/` from `nodes.yaml` + `patches/`; `apply.sh [hostname]` applies them (context `home-cluster`, `~/.talos/config`). The Kubernetes version used for kubeconform schemas is parsed from `KUBERNETES_VERSION` in `generate.sh`.

## Architecture

**Bootstrap boundary.** Talos, Cilium (`cilium/`, Kustomize + Helm, applied by hand per `cilium/README.md`) and Argo CD (`gitops/argocd/`, Kustomize + Helm, applied by hand) sit outside GitOps. Changing them in Git does nothing until someone renders and applies them; Renovate keeps their updates out of the routine groups for that reason. Everything else is reconciled by Argo CD from `main`.

**App-of-apps.** `gitops/root-application.yaml` (`app-of-apps`, `default` project, name must not change) renders the Helm chart `gitops/infra-helm`, whose templates are *only* Argo CD `Application`s and the two `AppProject`s. Each Application points at an upstream Helm chart, a local source under `gitops/infra-custom/<name>/`, or both (multi-source).

- `infra-helm` holds only toggles, pinned chart versions and wiring. `gitops/infra-helm/values.yaml` has the feature toggles (`<component>.enabled`) and pinned upstream chart versions, each with a `# renovate:` annotation, and no knobs for things the sources hard-code (namespaces, storage classes, the `release: kube-prometheus-stack` label): write those as literals. Upstream Helm values live in `gitops/infra-custom/<name>/upstream-values.yaml` (monitoring: `monitoring/<chart>-values.yaml`) and are referenced as `$values/gitops/infra-custom/...` value files. Inline `helm.values` may only carry wiring (values computed from other toggles). Dashboards ship as `grafana_dashboard: "1"` ConfigMaps in their service's source.
- Templates live under `templates/<area>/`, named `*-helm.yaml` (upstream chart) or `*-custom.yaml` (local source). Each one describes its Application as a YAML block in `define "app.<name>"` (closed with `{{ end }}`, no dash) and renders it with `infra.application` from `_helpers.tpl` inside `{{- if .Values.<toggle>.enabled }}`; the helper's header lists the keys. Never hand-write an Application: the helper emits the shared skeleton (sync policy, `FailOnSharedResource`, `SkipDryRunOnMissingResource`, the `$values` ref source) and fails the render on a wave outside 0-2, an unknown project or key, or `ownsPVCs` with `cascadeDelete`. Its rules are tested by `ci/contract-tests/` (one bad template per rule, run by `validate.sh`). A refactor of the chart should show no output from `scripts/render-diff.sh`. The root Application duplicates the retry policy; keep them in sync.
- AppProjects (`templates/projects.yaml`): `platform` for controllers/storage/networking/monitoring/auth (cluster-scoped allowed), `apps` for user workloads (own namespaces only, no cluster-scoped resources beyond Namespace and NFS PVs). A new namespace must be added to its project's `destinations` before its Application can sync.
- Sync waves are only `0` (foundations, CRD providers), `1` (platform add-ons) and `2` (workloads, smoke test), enforced by the helper. Waves are not a readiness scheduler: cross-Application dependencies rely on `SkipDryRunOnMissingResource=true` and the retry backoff (`docs/adr/0001`).
- Every child Application sets `FailOnSharedResource=true`; each resource (including namespace metadata) has exactly one owning Application.
- Cascade delete is opt-in (`cascadeDelete: true` adds the `resources-finalizer`); stateful services, CRD providers, the Gateway and storage leave it off so deleting their Application never cascades. Applications whose source holds PVCs set `ownsPVCs: true` instead, which the helper refuses to combine with `cascadeDelete` (`docs/adr/0002`).
- A toggle that is off in `values.yaml` must be switched on in `gitops/infra-helm/ci/all-enabled-values.yaml` so CI still renders that template.

`validate.sh` discovers the local sources by rendering the chart with all toggles on and reading each Application's `path`/`helm` fields, then renders them the way Argo CD would (kustomization, chart with its value files, or a plain directory of top-level YAML). Upstream charts are not rendered in CI.

**Workload conventions** (see `gitops/infra-custom/dumbpad/` for a compact example): own `namespace.yaml` (Application uses `CreateNamespace=false`), Longhorn PVC for state or NFS for bulk media/books, `HTTPRoute` to the shared Cilium Gateway (`*.homelab.niekvlam.nl`, wildcard cert), a `CiliumNetworkPolicy` limiting ingress, and credentials via `ExternalSecret` from 1Password. UIs without their own login go behind a per-UI oauth2-proxy with Pocket ID (`docs/auth.md`). Container images are pinned to explicit tags so Renovate can track them. Every kustomization must list each manifest beside it (`validate.sh`). Media is a kustomization whose shared setup comes from labels: a patch for every media Deployment (replicas, `Recreate`, priority, seccomp), `homelab.niekvlam.nl/base: linuxserver` for the s6-overlay images (PUID/PGID/UMASK/TZ, capabilities, the `linuxserver-root` exception) and `homelab.niekvlam.nl/indexer-backoff-reset: "true"` for the *arr indexer sidecar; see `gitops/infra-custom/media/components/`.

**Policy.** Pod Security Admission enforces baseline cluster-wide; namespaces that need host access override it to privileged in their Namespace manifest with a reason. Kyverno CEL `ValidatingPolicy`s in `gitops/infra-custom/kyverno/` check restricted PSS, pinned tags, requests + memory limit (no CPU limit required), probes, no `default` namespace, and the `app.kubernetes.io/name` label. They currently run in Audit and are being moved to Enforce one at a time (`docs/policy.md`), so new workloads should comply. Every policy/exception file must be listed in that directory's `kustomization.yaml`, exceptions must name existing policies, and every test fixture must have an expectation. `validate.sh` also runs the policies over the rendered workloads and fails on any failure (Audit included) and on any exception that matches nothing or is not needed; exceptions match on `app.kubernetes.io/name` and those for upstream workloads CI does not render set `properties.rendered: "false"`. The `kyverno` CLI version in `.github/workflows/validate.yaml` tracks the chart's app version.

**Resource sizing.** Requests come from observed usage (KRR simple: CPU p95, memory peak +15%), memory limit about 2× request; platform controllers have no CPU limit. PriorityClasses `homelab-home-critical` (Home Assistant, Zigbee2MQTT, Mosquitto) and `homelab-best-effort` (media).

**Go code.** `gitops/infra-custom/pi5-fan-control/` is a Go module (RP1 PWM fan controller DaemonSet) with its own Makefile (`test`, `lint`) and Dockerfile; `validate.sh` runs `go vet` and `go test` on it.

## Docs

`GLOSSARY.md` (domain terms: child Application, sync wave, cascade delete, owns PVCs, ...), `docs/adr/` (architecture decisions), `docs/bootstrap.md` (full bootstrap and reconfiguration), `docs/control-plane-recovery.md` (single etcd member, snapshots, A/B rollback; protected disks), `docs/auth.md` (SSO and break-glass), `docs/policy.md` (policies, exceptions, enforce procedure), `gitops/infra-helm/README.md` (ownership, waves, deletion policy).

## Agent skills

### Issue tracker

GitHub Issues in `Alphaegen/talos-kubernetes-homelab` via `gh` (public). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root (created lazily). See `docs/agents/domain.md`.
