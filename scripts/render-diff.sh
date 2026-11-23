#!/usr/bin/env bash
# Show how the rendered app-of-apps chart differs between a Git ref and the
# working tree, ignoring key order and comments (Argo CD ignores both).
#
# Usage: scripts/render-diff.sh [base-ref]   (default: HEAD)
# Exit:  0 when the renders are the same, 1 when they differ.
#
# Needs: git, helm, yq (mikefarah).

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

base_ref=${1:-HEAD}
chart=gitops/infra-helm

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# render <chart-dir> <out-dir>: one file per object, keys sorted, comments
# dropped, with the real values and with every toggle on.
render() {
  local dir=$1 out=$2 variant
  for variant in default all-enabled; do
    mkdir -p "$out/$variant"
    if [[ $variant == default ]]; then
      helm template infra-apps "$dir" >"$out/$variant.yaml"
    else
      helm template infra-apps "$dir" -f "$dir/ci/all-enabled-values.yaml" >"$out/$variant.yaml"
    fi
    (cd "$out/$variant" && yq -s '.kind + "_" + .metadata.name + ".yaml"' -P \
      'select(. != null) | ... comments="" | sort_keys(..)' "../$variant.yaml")
    rm "$out/$variant.yaml"
  done
}

mkdir -p "$work/base-src"
git archive "$base_ref" "$chart" | tar -x -C "$work/base-src"
render "$work/base-src/$chart" "$work/$base_ref"
render "$chart" "$work/worktree"

cd "$work"
status=0
diff -ru "$base_ref" worktree || status=$?
((status)) || printf 'No rendered difference against %s.\n' "$base_ref"
exit "$status"
