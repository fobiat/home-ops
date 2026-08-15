#!/usr/bin/env bash
# Renders every kustomization and validates it against Kubernetes and CRD schemas.
set -euo pipefail

KUBERNETES_DIR="${1:-./kubernetes}"

kustomize_args=("--load-restrictor=LoadRestrictionsNone")
kubeconform_args=(
  "-strict" "-ignore-missing-schemas" "-skip" "Secret"
  "-schema-location" "default"
  "-schema-location" "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
)

echo "Validating $KUBERNETES_DIR"
find "$KUBERNETES_DIR" -type f -name kustomization.yaml -print0 |
  while IFS= read -r -d '' file; do
    dir=$(dirname "$file")
    echo "  $dir"
    kustomize build "$dir" "${kustomize_args[@]}" | kubeconform "${kubeconform_args[@]}"
  done
