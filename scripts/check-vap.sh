#!/usr/bin/env bash
# Proves the external-exposure admission policies deny and allow the right things.
# Runs everything through --dry-run=server, so it persists nothing. See ADR 0013.
set -uo pipefail

fail=0

expect_denied() {
  local name=$1 want=$2 manifest=$3 out rc
  out=$(kubectl apply --dry-run=server -f - <<<"$manifest" 2>&1) && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf 'FAIL %s: expected a denial, the API server accepted it\n' "$name" >&2
    fail=1
  elif ! grep -qF "$want" <<<"$out"; then
    printf 'FAIL %s: denied, but not by the expected rule\n  wanted: %s\n  got: %s\n' \
      "$name" "$want" "$out" >&2
    fail=1
  else
    printf 'PASS %s: denied as expected\n' "$name"
  fi
}

expect_allowed() {
  local name=$1 file=$2 out rc
  out=$(kubectl apply --dry-run=server -f "$file" 2>&1) && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf 'FAIL %s: expected acceptance, got: %s\n' "$name" "$out" >&2
    fail=1
  else
    printf 'PASS %s: allowed as expected\n' "$name"
  fi
}

expect_allowed_inline() {
  local name=$1 manifest=$2 out rc
  out=$(kubectl apply --dry-run=server -f - <<<"$manifest" 2>&1) && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf 'FAIL %s: expected acceptance, got: %s\n' "$name" "$out" >&2
    fail=1
  else
    printf 'PASS %s: allowed as expected\n' "$name"
  fi
}

expect_denied "route-outside-network-public" \
  "a parentRef named 'external' is only allowed in the network-public namespace" \
  "$(cat <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vap-probe
  namespace: default
spec:
  parentRefs:
    - name: external
      namespace: network-public
  hostnames: ["probe.fobiat.dev"]
  rules:
    - backendRefs:
        - name: gatus
          port: 80
EOF
)"

expect_allowed "existing-gatus-route" kubernetes/apps/default/gatus/app/httproute.yaml
expect_allowed "existing-internal-gateway" kubernetes/apps/network/gateway/app/gateway.yaml

expect_allowed_inline "route-inside-network-public" "$(cat <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vap-probe
  namespace: network-public
spec:
  parentRefs:
    - name: external
      namespace: network-public
  hostnames: ["probe.fobiat.dev"]
  rules:
    - backendRefs:
        - name: gatus
          port: 80
EOF
)"

expect_denied "wildcard-listener-on-external" \
  "the external Gateway requires an exact FQDN on every listener" \
  "$(cat <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: network-public
spec:
  gatewayClassName: cilium
  listeners:
    - name: wildcard
      protocol: HTTPS
      port: 443
      hostname: "*.fobiat.dev"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: insights-fobiat-dev-tls
      allowedRoutes:
        namespaces:
          from: Same
EOF
)"

exit "$fail"
