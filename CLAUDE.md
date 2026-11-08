# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Talos Linux + Argo CD homelab on four Raspberry Pi 5 nodes (one control plane, three workers). The GitHub repository is **public**: never write secret values, kubeconfig/talosconfig contents, or generated machine configs into tracked files, and never print them. `output/`, `talosconfig` and `secrets.yaml` are gitignored; `.private/` (roadmap and plans) and `.claude/` are local-only via `.git/info/exclude`.

## Commands

```bash
scripts/validate.sh                      # the full check; identical to the CI "Validate" job
RENDER_DIR=/tmp/rendered scripts/validate.sh   # keep rendered manifests (dir must not exist yet)
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

- `gitops/infra-helm/values.yaml` holds the feature toggles (`<component>.enabled`) and pinned upstream chart versions, each with a `# renovate:` annotation. Upstream Helm *values* do not go here: they live in `gitops/infra-custom/<name>/` and are referenced through a Git source with `ref: values` and `$values/gitops/infra-custom/...` value files.
- Templates live under `templates/<area>/`, named `*-helm.yaml` (upstream chart) or `*-custom.yaml` (local source), and wrap everything in `{{- if .Values.<toggle>.enabled }}`. Use `infra.appName`, `infra.platformProject` / `infra.appsProject` and `infra.syncPolicy` from `_helpers.tpl`. The root Application duplicates the retry policy; keep them in sync.
- AppProjects (`templates/projects.yaml`): `platform` for controllers/storage/networking/monitoring/auth (cluster-scoped allowed), `apps` for user workloads (own namespaces only, no cluster-scoped resources beyond Namespace and NFS PVs). A new namespace must be added to its project's `destinations` before its Application can sync.
- Sync waves are only `0` (foundations, CRD providers), `1` (platform add-ons) and `2` (workloads, smoke test). Waves are not a readiness scheduler: cross-Application CRs use `SkipDryRunOnMissingResource=true` and rely on the retry backoff.
- Every child Application sets `FailOnSharedResource=true`; each resource (including namespace metadata) has exactly one owning Application.
- Applications for stateful services deliberately have **no** `resources-finalizer`, so deleting the Application never cascades to PVCs or data. Do not add one to them.
- A toggle that is off in `values.yaml` must be switched on in `gitops/infra-helm/ci/all-enabled-values.yaml` so CI still renders that template.

`validate.sh` discovers the local sources by rendering the chart with all toggles on and reading each Application's `path`/`helm` fields, then renders them the way Argo CD would (kustomization, chart with its value files, or a plain directory of top-level YAML). Upstream charts are not rendered in CI.

**Workload conventions** (see `gitops/infra-custom/dumbpad/` for a compact example): own `namespace.yaml` (Application uses `CreateNamespace=false`), Longhorn PVC for state or NFS for bulk media/books, `HTTPRoute` to the shared Cilium Gateway (`*.homelab.niekvlam.nl`, wildcard cert), a `CiliumNetworkPolicy` limiting ingress, and credentials via `ExternalSecret` from 1Password. UIs without their own login go behind a per-UI oauth2-proxy with Pocket ID (`docs/auth.md`). Container images are pinned to explicit tags so Renovate can track them.

**Policy.** Pod Security Admission enforces baseline cluster-wide; namespaces that need host access override it to privileged in their Namespace manifest with a reason. Kyverno CEL `ValidatingPolicy`s in `gitops/infra-custom/kyverno/` check restricted PSS, pinned tags, requests + memory limit (no CPU limit required), probes, no `default` namespace, and the `app.kubernetes.io/name` label. They currently run in Audit and are being moved to Enforce one at a time (`docs/policy.md`), so new workloads should comply. Every policy/exception file must be listed in that directory's `kustomization.yaml`, exceptions must name existing policies, and every test fixture must have an expectation (all enforced by `validate.sh`). The `kyverno` CLI version in `.github/workflows/validate.yaml` tracks the chart's app version.

**Resource sizing.** Requests come from observed usage (KRR simple: CPU p95, memory peak +15%), memory limit about 2× request; platform controllers have no CPU limit. PriorityClasses `homelab-home-critical` (Home Assistant, Zigbee2MQTT, Mosquitto) and `homelab-best-effort` (media).

**Go code.** `gitops/infra-custom/pi5-fan-control/` is a Go module (RP1 PWM fan controller DaemonSet) with its own Makefile (`test`, `lint`) and Dockerfile; `validate.sh` runs `go vet` and `go test` on it.

## Docs

`docs/bootstrap.md` (full bootstrap and reconfiguration), `docs/control-plane-recovery.md` (single etcd member, snapshots, A/B rollback; protected disks), `docs/auth.md` (SSO and break-glass), `docs/policy.md` (policies, exceptions, enforce procedure), `gitops/infra-helm/README.md` (ownership, waves, deletion policy).
