#!/usr/bin/env bash
# Generates kubeconform schemas from the CRDs of the charts this repo pins.
# Add a line per chart whose CRDs the public catalog gets wrong. See the
# lint:schemas task for why this exists at all.
set -euo pipefail

OUT_DIR="${1:-./.schemas}"

chart() {
  local name="$1" version="$2" repo="$3"
  helm template "$name" "$name" --repo "$repo" --version "$version" \
    --set manageCRDs=true |
    yq -o=json -I0 'select(.kind == "CustomResourceDefinition")' |
    python3 "$(dirname "$0")/crd-schemas.py" "$OUT_DIR"
}

chart volsync 0.16.0 https://backube.github.io/helm-charts/
