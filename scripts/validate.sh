#!/usr/bin/env bash
# Render every manifest source in the repository and validate it.
# Used locally and by .github/workflows/validate.yaml.
#
# Needs: helm, kustomize, kubeconform, yq (mikefarah), jq, go, kyverno.
# Env:   RENDER_DIR=<dir> writes the rendered manifests there and keeps them
#        (the directory must not exist yet), e.g. for kube-linter.
#        KYVERNO_REPORT=<file> keeps the Kyverno policy report for the rendered
#        workloads, e.g. for the job summary.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# Schemas follow the cluster version that generate.sh installs.
kubernetes_version=${KUBERNETES_VERSION:-$(sed -n 's/^KUBERNETES_VERSION="\${TALOS_KUBERNETES_VERSION:-\([0-9.]*\)}"$/\1/p' generate.sh)}

# renovate: datasource=git-refs depName=https://github.com/datreeio/CRDs-catalog branch=main
crds_catalog_ref=3e8a8916ca1b7af6464606c2c2f5869dbafa9653

# Kinds with no usable published schema, neither upstream nor in the CRDs catalog.
skip_kinds=(
  CustomResourceDefinition # kubeconform's default schema source has none
  CiliumGatewayClassConfig # not in the CRDs catalog
  PolicyException          # catalog schema does not compile (spec has a field named "properties")
)

infra_helm=gitops/infra-helm
all_enabled_values=$infra_helm/ci/all-enabled-values.yaml
contract_tests=$infra_helm/ci/contract-tests
# Standalone manifests applied by hand, outside any chart or kustomization.
plain_manifests=(gitops/root-application.yaml)
go_modules=(gitops/infra-custom/pi5-fan-control)
kyverno_dir=gitops/infra-custom/kyverno
policy_check_cases=scripts/testdata/policy-check
ha_dashboard_dir=gitops/infra-custom/home-assistant

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

# The infra.application helper's rules: each contract test breaks one rule and
# must fail the render with the message on its "# expect:" line.
check_application_contract() {
  local test expect chart out status=0
  for test in "$contract_tests"/*.yaml; do
    expect=$(sed -n 's/^# expect: //p' "$test")
    [[ -n $expect ]] || { printf '%s has no "# expect:" line\n' "$test"; status=1; continue; }
    chart=$(mktemp -d "$work/contract.XXXXXX")
    cp -R "$infra_helm/." "$chart"
    cp "$test" "$chart/templates/zz-contract-test.yaml"
    if out=$(helm template infra-apps "$chart" 2>&1); then
      printf '%s rendered, but should fail with: %s\n' "$test" "$expect"
      status=1
    elif ! grep -qF -- "$expect" <<<"$out"; then
      printf '%s failed without "%s":\n%s\n' "$test" "$expect" "$out"
      status=1
    fi
  done
  return "$status"
}
run "infra.application contract tests ($contract_tests)" check_application_contract

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

# A plain directory deploys every file, a kustomization only what it names, so
# a Kubernetes object file it does not mention is silently left out.
check_kustomizations_list_their_files() {
  local kustomization dir file named status=0
  while IFS= read -r kustomization; do
    dir=$(dirname "$kustomization")
    named=$(yq '.. | select(tag == "!!str")' "$kustomization" | sed 's|^\./||')
    while IFS= read -r file; do
      [[ $(yq ea '[select(has("apiVersion") and has("kind"))] | length' "$file") == 0 ]] && continue
      grep -qxF "$(basename "$file")" <<<"$named" \
        || { printf '%s is not listed in %s\n' "$file" "$kustomization"; status=1; }
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name kustomization.yaml | sort)
  done < <(find gitops cilium -name kustomization.yaml -not -path '*/charts/*' | sort)
  return "$status"
}
run "Kustomizations list every Kubernetes object file beside them" check_kustomizations_list_their_files

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

# check_rendered_policies <policies dir> <exceptions dir> <workloads file>:
# kyverno apply stands in for admission. Fails on any failed result, and on
# any exception that does not earn its place: one that skips no workload for
# a policy it lists, skips a workload that passes that policy without it, or
# is marked rendered: "false" (its workloads come from an upstream chart or an
# operator, which CI does not render) yet skips a rendered workload. Writes
# the policy report to $KYVERNO_REPORT when that is set.
check_rendered_policies() {
  local policies=$1 exceptions=$2 workloads=$3 file with without excepted
  local args=()
  for file in "$exceptions"/*.yaml; do
    [[ -f $file ]] && args+=(--exception "$file")
  done
  with=$(mktemp "$work/kyverno-with.XXXXXX")
  without=$(mktemp "$work/kyverno-without.XXXXXX")
  excepted=$(mktemp "$work/kyverno-exceptions.XXXXXX")
  # kyverno apply exits non-zero on failed results; the report says why.
  kyverno apply "$policies" "${args[@]}" --resource "$workloads" --policy-report --remove-color 2>&1 \
    | sed -n '/^apiVersion/,$p' >"$with" || true
  kyverno apply "$policies" --resource "$workloads" --policy-report --remove-color 2>&1 \
    | sed -n '/^apiVersion/,$p' >"$without" || true
  [[ -s $with && -s $without ]] || { printf 'kyverno apply produced no policy report\n'; return 1; }
  [[ -z ${KYVERNO_REPORT:-} ]] || cp "$with" "$KYVERNO_REPORT"
  if ((${#args[@]})); then
    yq -o=json -I=0 '{"name": .metadata.name, "rendered": (.spec.properties.rendered // "true"),
      "policies": [.spec.policyRefs[].name]}' "$exceptions"/*.yaml | jq -s . >"$excepted"
  else
    printf '[]\n' >"$excepted"
  fi
  jq -nr --slurpfile with <(yq -o=json . "$with") --slurpfile without <(yq -o=json . "$without") \
    --slurpfile exceptions "$excepted" '
    def id: .resources[0] | "\(.kind) \(.namespace)/\(.name)";
    ($with[0].results // []) as $results
    | ([$without[0].results // [] | .[] | select(.result == "pass") | "\(.policy) \(id)"]) as $passes
    | [$results[] | select(.result == "skip")
        | {policy, id: id, exception: (.properties.exceptions // "" | split(",")[])}] as $skips
    | ($results[] | select(.result == "fail" or .result == "error")
        | "\(.policy) \(.result)s for \(id): \(.message)"),
      ($results[] | select(.result == "skip" and (.properties.exceptions // "") == "")
        | "\(.policy) skips \(id) without an exception: \(.message)"),
      ($exceptions[0][] | .name as $name | .policies[] as $policy
        | [$skips[] | select(.exception == $name and .policy == $policy)] as $mine
        | if $mine == [] then
            (if .rendered == "false" then empty
             else "exception \($name) skips no rendered workload for \($policy); fix its match or mark it rendered: \"false\"" end)
          elif .rendered == "false" then
            "exception \($name) is marked rendered: \"false\" but skips \($mine[0].id) for \($policy)"
          else
            ($mine[] | select(("\($policy) \(.id)") as $key | $passes | index($key))
              | "exception \($name) is not needed for \($policy): \(.id) passes without it")
          end)' \
    | { ! grep . ; }
}

# Workloads only: the CLI's fake client rejects duplicate objects, such as a
# Namespace that two sources both render. kube-system is excluded by every
# policy.
workloads=$work/workloads.yaml
find "$manifests" -name '*.yaml' -print0 | xargs -0 yq ea '
  select((.kind == "Pod" or .kind == "Deployment" or .kind == "StatefulSet" or
          .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob") and
         .metadata.namespace != "kube-system")' >"$workloads"
run "Rendered workloads against the Kyverno policies and exceptions" \
  check_rendered_policies "$kyverno_dir/policies" "$kyverno_dir/exceptions" "$workloads"

# The check above must reject each case in $policy_check_cases with the
# message on the "# expect:" line of the case's workloads.yaml.
check_policy_check_cases() {
  local case expect out status=0
  for case in "$policy_check_cases"/*/; do
    case=${case%/}
    expect=$(sed -n 's/^# expect: //p' "$case/workloads.yaml")
    [[ -n $expect ]] || { printf '%s has no "# expect:" line\n' "$case"; status=1; continue; }
    if out=$(KYVERNO_REPORT='' check_rendered_policies "$kyverno_dir/policies" "$case/exceptions" "$case/workloads.yaml"); then
      printf '%s passed, but should fail with: %s\n' "$case" "$expect"
      status=1
    elif ! grep -qF -- "$expect" <<<"$out"; then
      printf '%s failed without "%s":\n%s\n' "$case" "$expect" "$out"
      status=1
    fi
  done
  return "$status"
}
run "Rendered policy check cases ($policy_check_cases)" check_policy_check_cases

# 6. Home Assistant YAML dashboard: Home Assistant only reports a broken file or
# a missing !include when the dashboard is opened, so check that every file
# parses, ships in the ConfigMap, and only includes files that ship too.
check_ha_dashboard() {
  local listed file target status=0
  listed=$(yq '.configMapGenerator[] | select(.name == "home-assistant-dashboards") | .files[]' \
    "$ha_dashboard_dir/kustomization.yaml")
  for file in "$ha_dashboard_dir"/dashboards/*.yaml; do
    yq '.' "$file" >/dev/null || { printf '%s does not parse\n' "$file"; status=1; }
    grep -qxF "${file#"$ha_dashboard_dir/"}" <<<"$listed" \
      || { printf '%s is not in the home-assistant-dashboards ConfigMap\n' "$file"; status=1; }
    while IFS= read -r target; do
      grep -qxF "dashboards/$target" <<<"$listed" \
        || { printf '%s includes %s, which is not in the ConfigMap\n' "$file" "$target"; status=1; }
    done < <(grep -vE '^[[:space:]]*#' "$file" | grep -oE '!include [^ #]+\.ya?ml' | awk '{print $2}')
  done
  return "$status"
}
run "Home Assistant dashboard files and includes" check_ha_dashboard

# 7. Go code that ships in the repository.
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
