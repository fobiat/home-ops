#!/usr/bin/env bash
# Suspend everything this cluster does not need in order to run the applejackrp
# dev server, then scale its workloads to zero.
#
# Why this exists: the node has ~7.3Gi allocatable and the game server alone can
# burst to 4Gi. Loading a real map has repeatedly squeezed the control plane
# hard enough to restart kube-apiserver, kube-controller-manager and
# kube-scheduler (98 and 101 restarts by 2026-08-24). Running with 89% of memory
# requested left no room; this takes it to roughly 65%.
#
# Nothing is deleted. PVCs, databases and manifests all survive, and
# scripts/cluster-restore-nonvital.sh reverses every step.
#
# Kept deliberately: the control plane, Cilium, CoreDNS, local-path storage,
# Flux itself, cert-manager, the CNPG operator, and the etcd/machineconfig
# backup CronJobs.
set -uo pipefail
KUBE="${KUBECTL:-kubectl}"

KS="actions-runner-applejackrp-sandbox actions-runner-cairn actions-runner-controller
actions-runner-fobiat-dev actions-runner-rivet actions-runner-rivet-workstation
alloy cairn cairn-automation cairn-db cairn-namespace cairn-registry-auth cairn-source
docs-proxy gatus grafana-dashboards headlamp homepage kube-prometheus-stack loki
network-cloudflared network-external-dns reloader tuppr umami umami-backup umami-db
volsync"

echo "== suspending Flux Kustomizations =="
for k in $KS; do
  "$KUBE" patch kustomization "$k" -n flux-system --type=merge \
    -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 \
    && echo "  suspended $k" || echo "  SKIP $k (not found)"
done

echo
echo "== scaling workloads to zero =="
for ns in cairn umami default actions-runner-system network kube-tools system-upgrade reloader volsync-system; do
  for kind in deployment statefulset; do
    for n in $("$KUBE" get "$kind" -n "$ns" -o name 2>/dev/null); do
      "$KUBE" scale "$n" -n "$ns" --replicas=0 >/dev/null 2>&1 && echo "  0 <- $ns/$n"
    done
  done
  for c in $("$KUBE" get cronjob -n "$ns" -o name 2>/dev/null); do
    "$KUBE" patch "$c" -n "$ns" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 \
      && echo "  paused $ns/$c"
  done
done

# CNPG pods are created by the operator, not by a StatefulSet, so scaling does
# nothing to them. Hibernation is the supported way to stop a cluster, and it
# leaves the PVCs and their data untouched.
echo
echo "== hibernating CNPG clusters =="
for nsc in "cairn cairn-postgres" "umami umami-db"; do
  set -- $nsc
  "$KUBE" annotate cluster "$2" -n "$1" cnpg.io/hibernation=on --overwrite >/dev/null 2>&1 \
    && echo "  hibernated $1/$2" || echo "  SKIP $1/$2 (not found)"
done

echo
echo "done. Reverse with scripts/cluster-restore-nonvital.sh"
