#!/usr/bin/env bash
set -euo pipefail

configmap="${1:-kubernetes/apps/network/cloudflared/app/configmap.yaml}"
expected_service="https://cilium-gateway-external.network-public.svc.cluster.local:443"

[[ -f "$configmap" ]] || {
  echo "cloudflared ConfigMap not found: $configmap" >&2
  exit 1
}

if ! yq -r '.data["config.yaml"]' "$configmap" | yq -e "
  (.ingress as \$ingress | ((\$ingress | length) >= 2))
  and (.ingress as \$ingress | (\$ingress[-1].service == \"http_status:404\"))
  and (.ingress as \$ingress | ([\$ingress[] | select(.hostname != null)] | length) == ((\$ingress | length) - 1))
  and (.ingress as \$ingress | ([\$ingress[] | select(.hostname != null) | (.service == \"$expected_service\")] | all))
  and (.ingress as \$ingress | ([\$ingress[] | select(.hostname != null) | (.originRequest.originServerName == .hostname and .originRequest.httpHostHeader == .hostname)] | all))
" - >/dev/null; then
  echo "cloudflared ingress must use the external Gateway and end with http_status:404" >&2
  exit 1
fi
