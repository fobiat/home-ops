#!/usr/bin/env bash
# Reverse scripts/cluster-suspend-nonvital.sh.
#
# Unsuspending the Kustomizations is the part that matters: Flux then reconciles
# each app back to the replica count in Git. The explicit cronjob unpause and the
# CNPG wake are here so recovery is immediate rather than waiting on the next
# reconcile interval.
set -uo pipefail
KUBE="${KUBECTL:-kubectl}"

KS="actions-runner-applejackrp-sandbox actions-runner-cairn actions-runner-controller
actions-runner-fobiat-dev actions-runner-rivet actions-runner-rivet-workstation
alloy cairn cairn-automation cairn-db cairn-namespace cairn-registry-auth cairn-source
docs-proxy gatus grafana-dashboards headlamp homepage kube-prometheus-stack loki
network-cloudflared network-external-dns reloader tuppr umami umami-backup umami-db
volsync"

echo "== waking CNPG clusters =="
for nsc in "cairn cairn-postgres" "umami umami-db"; do
  set -- $nsc
  "$KUBE" annotate cluster "$2" -n "$1" cnpg.io/hibernation=off --overwrite >/dev/null 2>&1 \
    && echo "  woke $1/$2"
done

echo
echo "== unsuspending Flux Kustomizations =="
for k in $KS; do
  "$KUBE" patch kustomization "$k" -n flux-system --type=merge \
    -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 && echo "  resumed $k"
done

echo
echo "== unpausing cronjobs =="
for ns in cairn umami default actions-runner-system network kube-tools system-upgrade reloader; do
  for c in $("$KUBE" get cronjob -n "$ns" -o name 2>/dev/null); do
    "$KUBE" patch "$c" -n "$ns" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 \
      && echo "  resumed $ns/$c"
  done
done

echo
echo "== volsync =="
"$KUBE" scale deployment volsync -n volsync-system --replicas=1 >/dev/null 2>&1 \
  && echo "  volsync back to 1"

echo
echo "Flux restores replica counts from Git on the next reconcile. To force it now:"
echo "  kubectl annotate kustomization -n flux-system --all \\"
echo "    reconcile.fluxcd.io/requestedAt=\"\$(date +%s)\" --overwrite"
