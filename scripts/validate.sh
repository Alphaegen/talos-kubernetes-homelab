#!/usr/bin/env bash
# Render every manifest source in the repository and validate it.
# Used locally and by .github/workflows/validate.yaml.
#
# Needs: helm, kustomize, kubeconform, yq (mikefarah), jq, go, kyverno.
# Env:   RENDER_DIR=<dir> writes the rendered manifests there and keeps them
#        (the directory must not exist yet), e.g. for kube-linter.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# Schemas follow the cluster version that generate.sh installs.
kubernetes_version=${KUBERNETES_VERSION:-$(sed -n 's/^KUBERNETES_VERSION="\${TALOS_KUBERNETES_VERSION:-\([0-9.]*\)}"$/\1/p' generate.sh)}

# renovate: datasource=git-refs depName=https://github.com/datreeio/CRDs-catalog branch=main
crds_catalog_ref=ad3b08c5045129d7bb1eeffd8e61719b2c8dd1e2

# Kinds with no usable published schema, neither upstream nor in the CRDs catalog.
skip_kinds=(
  CustomResourceDefinition # kubeconform's default schema source has none
  CiliumGatewayClassConfig # not in the CRDs catalog
  PolicyException          # catalog schema does not compile (spec has a field named "properties")
)

infra_helm=gitops/infra-helm
all_enabled_values=$infra_helm/ci/all-enabled-values.yaml
# Standalone manifests applied by hand, outside any chart or kustomization.
plain_manifests=(gitops/root-application.yaml)
go_modules=(gitops/infra-custom/pi5-fan-control)
kyverno_dir=gitops/infra-custom/kyverno

failures=()

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures+=("$1")
}

pass() {
  printf 'PASS: %s\n' "$1"
}

# run <label> <command...>: run a step, show its output only when it fails
# (apart from any "Summary:" line).
run() {
  local label=$1 log
  shift
  log=$(mktemp)
  if "$@" >"$log" 2>&1; then
    grep '^Summary:' "$log" | sed 's/^/  /' || true
    pass "$label"
  else
    sed 's/^/  /' "$log" >&2
    fail "$label"
  fi
  rm -f "$log"
}

for tool in helm kustomize kubeconform yq jq go kyverno; do
  command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 2; }
done
[[ -n $kubernetes_version ]] || { printf 'Could not read KUBERNETES_VERSION from generate.sh\n' >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
manifests=${RENDER_DIR:-$work/manifests}
mkdir -p "$(dirname "$manifests")"
mkdir "$manifests"

declare -A rendered=()

out_file() {
  printf '%s/%s.yaml' "$manifests" "$(printf '%s' "$1" | tr '/' '_')"
}

kustomize_build() {
  local dir=$1
  run "kustomize build $dir" sh -c 'kustomize build --enable-helm "$1" > "$2"' _ "$dir" "$(out_file "$dir")"
  rendered[$dir]=1
}

# 1. The app-of-apps chart, with the real values and with every toggle on.
run "helm template $infra_helm" sh -c 'helm template infra-apps "$1" > "$2"' _ "$infra_helm" "$(out_file "$infra_helm")"
run "helm template $infra_helm (all toggles on)" sh -c 'helm template infra-apps "$1" -f "$2" > "$3"' \
  _ "$infra_helm" "$all_enabled_values" "$manifests/infra-helm-all-enabled.yaml"

for manifest in "${plain_manifests[@]}"; do
  cp "$manifest" "$(out_file "$manifest")"
done

# 2. Every local source the Applications point at, rendered the way Argo CD
#    renders it. Remote charts are left to Argo CD.
if [[ -s $manifests/infra-helm-all-enabled.yaml ]]; then
  while IFS= read -r source; do
    path=$(jq -r .path <<<"$source")
    [[ -n ${rendered[$path]:-} ]] && continue

    if [[ -f $path/kustomization.yaml ]]; then
      kustomize_build "$path"
    elif [[ -f $path/Chart.yaml ]]; then
      args=(template "$(jq -r '.helm.releaseName // "release"' <<<"$source")" "$path"
        --namespace "$(jq -r .namespace <<<"$source")")
      while IFS= read -r values_file; do
        [[ -n $values_file ]] || continue
        case $values_file in
          '$values/'*) args+=(-f "${values_file#\$values/}") ;;
          *) args+=(-f "$path/$values_file") ;;
        esac
      done < <(jq -r '.helm.valueFiles // [] | .[]' <<<"$source")
      if jq -e '.helm.values // empty' <<<"$source" >/dev/null; then
        inline=$(mktemp "$work/inline-values.XXXXXX")
        jq -r .helm.values <<<"$source" >"$inline"
        args+=(-f "$inline")
      fi
      run "helm template $path" sh -c 'out=$1; shift; helm "$@" > "$out"' _ "$(out_file "$path")" "${args[@]}"
      rendered[$path]=1
    else
      # Plain directory source: Argo CD applies the top-level YAML files as-is.
      dest=$(out_file "$path")
      dest=${dest%.yaml}
      mkdir -p "$dest"
      find "$path" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -exec cp {} "$dest/" \;
      pass "collect $path"
      rendered[$path]=1
    fi
  done < <(yq -o=json -I=0 'select(.kind == "Application")' "$manifests/infra-helm-all-enabled.yaml" \
    | jq -c '.spec.destination.namespace as $ns
        | ((.spec.source // empty), (.spec.sources // [] | .[]))
        | select(.path != null and (.path | startswith("gitops/")))
        | {path, namespace: $ns, helm}')
fi

# 3. Anything the Applications did not reach: manually applied kustomizations
#    (Argo CD, Cilium) and sources behind alternative toggles.
while IFS= read -r kustomization; do
  dir=$(dirname "$kustomization")
  [[ -n ${rendered[$dir]:-} ]] || kustomize_build "$dir"
done < <(find gitops cilium -name kustomization.yaml -not -path '*/charts/*' | sort)

while IFS= read -r chart; do
  dir=$(dirname "$chart")
  [[ $dir == "$infra_helm" || -n ${rendered[$dir]:-} ]] && continue
  run "helm template $dir (default values)" sh -c 'helm template release "$1" > "$2"' _ "$dir" "$(out_file "$dir")"
  rendered[$dir]=1
done < <(find gitops/infra-custom -name Chart.yaml -not -path '*/charts/*' | sort)

# 4. Schema validation of everything rendered above.
skip=$(IFS=,; printf '%s' "${skip_kinds[*]}")
run "kubeconform (Kubernetes $kubernetes_version, CRDs catalog ${crds_catalog_ref:0:7})" \
  kubeconform -strict -summary -output text \
  -kubernetes-version "$kubernetes_version" \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$crds_catalog_ref/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -skip "$skip" \
  "$manifests"

# 5. Kyverno policies: every file is deployed, every exception names a policy
# that exists, and the policy test suites pass.
check_kyverno_wiring() {
  local listed policies file ref status=0
  listed=$(yq '.resources[]' "$kyverno_dir/kustomization.yaml")
  for file in "$kyverno_dir"/policies/*.yaml "$kyverno_dir"/exceptions/*.yaml; do
    grep -qxF "${file#"$kyverno_dir/"}" <<<"$listed" \
      || { printf '%s is not listed in kustomization.yaml\n' "$file"; status=1; }
  done
  policies=$(yq -N '.kind + "/" + .metadata.name' "$kyverno_dir"/policies/*.yaml)
  while IFS= read -r ref; do
    grep -qxF "$ref" <<<"$policies" \
      || { printf 'A PolicyException refers to %s, which does not exist\n' "$ref"; status=1; }
  done < <(yq -N '.spec.policyRefs[] | .kind + "/" + .name' "$kyverno_dir"/exceptions/*.yaml | sort -u)
  return "$status"
}
run "Kyverno policy and exception wiring" check_kyverno_wiring

# kyverno test silently reports an expectation for a missing fixture against
# another resource, so check the names both ways.
check_kyverno_fixtures() {
  local suite expected fixtures name status=0
  for suite in "$kyverno_dir"/tests/*/; do
    expected=$(yq -N '.results[] | .kind + "/" + .resources[]' "$suite/kyverno-test.yaml" | sort -u)
    fixtures=$(yq -N '.kind + "/" + .metadata.name' "$suite/resources.yaml" | sort -u)
    while IFS= read -r name; do
      printf '%s: expectation for %s, which is not a fixture\n' "$suite" "$name"
      status=1
    done < <(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$fixtures"))
    while IFS= read -r name; do
      printf '%s: fixture %s has no expected result\n' "$suite" "$name"
      status=1
    done < <(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$fixtures"))
  done
  return "$status"
}
run "Kyverno test fixtures match their expectations" check_kyverno_fixtures
run "kyverno test $kyverno_dir/tests" kyverno test --remove-color "$kyverno_dir/tests"

# 6. Go code that ships in the repository.
for module in "${go_modules[@]}"; do
  run "go vet $module" sh -c 'cd "$1" && go vet ./...' _ "$module"
  run "go test $module" sh -c 'cd "$1" && go test ./...' _ "$module"
done

if ((${#failures[@]})); then
  printf '\n%d check(s) failed:\n' "${#failures[@]}" >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
printf '\nAll checks passed.\n'
