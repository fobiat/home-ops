# tuppr

A Kubernetes controller in the `system-upgrade` namespace that performs Talos and
Kubernetes upgrades declaratively: a `TalosUpgrade` or `KubernetesUpgrade` custom
resource names a target version, tuppr health-checks the cluster, then calls the Talos
API to upgrade and reboot. See [ADR 0010](adr/0010-tuppr-upgrades.md) for why it was
chosen over a manual `talosctl upgrade` or `system-upgrade-controller`.

**The controller is running and does nothing.** No `TalosUpgrade` or `KubernetesUpgrade`
resource is committed. This is deliberate: on a single-node cluster, a CR sitting in Git
is an unattended reboot of the only thing running the API server, etcd, and every
workload, waiting for the next `kubectl apply` or Flux reconcile. Creating the first one
is its own runbook, not a side effect of running the controller.

**To actually perform an upgrade**, see [`docs/runbooks/tuppr-upgrade.md`](runbooks/tuppr-upgrade.md).
It has not been exercised on this cluster yet.

## The credential

tuppr authenticates via a `talos.dev/v1alpha1 ServiceAccount` CR
(`tuppr-talosconfig`, `os:admin`), which Talos mints automatically once
`machine.features.kubernetesTalosAPIAccess` grants the `system-upgrade` namespace in
`talos/talconfig.yaml`. That's a standing, always-live admin credential: any pod in
`system-upgrade` that can request a `ServiceAccount` CRD with role `os:admin` gets full
node control. The namespace runs exactly one thing for exactly this reason. See
[ADR 0010](adr/0010-tuppr-upgrades.md) for the full tradeoff, and
[ADR 0011](adr/0011-reconcile-backup-credential-onto-serviceaccount-crd.md) for the
sibling case in `cluster-backup`'s `machineconfig-backup` job, which shares the same
grant mechanism from a second namespace.

## Single-node behaviour

With one node, there's nowhere to drain to. tuppr detects this automatically: it issues
the upgrade with `--wait=false`, skips the drain, and tracks completion by polling node
readiness over the Talos API rather than waiting for a pod eviction that would strand
the node. This isn't a flag to set, it falls out of tuppr seeing one node.

## Checking it's healthy

```sh
kubectl -n system-upgrade get deployment tuppr
kubectl -n system-upgrade get pods
kubectl -n system-upgrade get secret tuppr-talosconfig
```

If the pod is stuck `ContainerCreating` on an unmounted secret, the machine config grant
hasn't been applied yet. If it's suspended and stuck, check `.spec.suspend` before
debugging anything else, a suspended HelmRelease looks identical to a broken one.
