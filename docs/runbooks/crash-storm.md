# Diagnosing a cluster-wide crash storm

What to do when many unrelated pods are restarting at once: control plane
components, Cilium, Flux controllers, and workloads together. On a single node
this is almost never several independent bugs. Work top-down: confirm the waves
are synchronized, find what Talos itself did, then find what got killed and why.

See [0007](../adr/0007-resource-requests-on-critical-pods.md) for the incident
this runbook comes from: a BestEffort-QoS Cilium got OOM-killed by Talos, which
took the CNI down, which took the apiserver connection down, which took every
controller's leader election down with it.

## 1. Confirm it is one event, not several bugs

```sh
mise exec -- kubectl get events --all-namespaces --sort-by=.lastTimestamp | tail -100
```

Look for restarts clustering into tight time windows across unrelated
namespaces, not spread evenly. A handful of synchronized waves a few minutes
apart is the signature of a node-level cause (OOM, network, disk), not
independent per-app failures. Waves spread over hours with no clustering point
back at individual apps instead.

```sh
mise exec -- kubectl get pods --all-namespaces \
  --sort-by='.status.containerStatuses[0].restartCount' | tail -20
```

## 2. Read termination reasons and exit codes

```sh
mise exec -- kubectl get pod <pod> -n <namespace> -o jsonpath='{.status.containerStatuses[0].lastState}'
```

The two exit codes that matter here:

- **137** (128 + SIGKILL). The kernel or Talos killed the container, almost
  always OOM. Confirmed by `reason: OOMKilled` in the same status block.
- **1, with `leaderelection lost` or `Failed to renew lease` in the log tail**.
  The process is fine, it lost contact with the apiserver. Not a bug in the
  component itself, look upstream at what broke the network or the apiserver.

```sh
mise exec -- kubectl logs <pod> -n <namespace> --previous --tail=50
```

`context deadline exceeded` plus `watch ended with error ... "http2: client
connection lost"` immediately before `leaderelection lost` means the apiserver
connection itself dropped. Every controller in the cluster loses its lease at
once when that happens, which is why kube-scheduler, kube-controller-manager,
helm-controller and source-controller all crash together: they share nothing
except the apiserver.

## 3. Check Talos for OOM kills

Talos has no shell and no package manager, so `talosctl dashboard` is the htop
equivalent and the fastest way to see live CPU and memory pressure per pod:

```sh
mise exec -- talosctl --talosconfig talos/clusterconfig/talosconfig -n talos-1 dashboard
```

For the historical record, `dmesg` carries the kernel's own OOM killer log:

```sh
mise exec -- talosctl --talosconfig talos/clusterconfig/talosconfig -n talos-1 dmesg | grep -i oom
```

`runtime.OOMController` firing repeatedly, each line logging `Sending SIGKILL to
cgroup` with a path under `/sys/fs/cgroup/kubepods/besteffort/...`, means Talos
killed something itself rather than the container just crashing. The `besteffort`
segment of the path is the finding: it names the QoS class, not just a location.

## 4. Map the killed cgroup back to a pod

The cgroup path in `dmesg` ends in the pod UID, not a name. Resolve it:

```sh
mise exec -- kubectl get pods --all-namespaces -o json \
  | jq -r '.items[] | "\(.metadata.uid) \(.metadata.namespace)/\(.metadata.name)"' \
  | grep <uid-from-dmesg>
```

If every kill resolves to the same one or two pods, that is the actual root
cause, not a symptom. In the 2026-08-16 incident every kill resolved to
`cilium-envoy` or `cilium-operator`, and killing either one broke pod networking
cluster-wide, which is what turned a memory problem into a total outage.

## 5. Check QoS class on the killed pods

```sh
mise exec -- kubectl get pod <pod> -n <namespace> -o jsonpath='{.status.qosClass}{"\n"}'
```

`BestEffort` means no container in the pod set `resources.requests` or
`resources.limits`. Talos's OOM killer scores cgroups by usage within QoS class,
and BestEffort has no reserved memory to protect it, so it is always first in
line. `Burstable` (requests set, no limits, or limits above requests) and
`Guaranteed` (requests equal limits on every container) both get more protection,
in that order.

To find every BestEffort pod in the cluster at once, before it becomes a
casualty rather than a lead:

```sh
mise exec -- kubectl get pods --all-namespaces -o json \
  | jq -r '.items[] | select(.status.qosClass == "BestEffort") | "\(.metadata.namespace)/\(.metadata.name)"'
```

Any cluster-critical component on that list (CNI, CoreDNS, Flux controllers,
cert-manager) is a standing risk, not just a candidate explanation for the
current incident. See [0007](../adr/0007-resource-requests-on-critical-pods.md).

## 6. Check what changed right before the first kill

```sh
mise exec -- flux get all --all-namespaces
mise exec -- kubectl get events --all-namespaces --field-selector reason=ScalingReplicaSet
```

Correlate the first OOM timestamp from `dmesg` against the most recent Helm
release or Flux reconciliation. A new install or upgrade that adds memory
pressure (a new Prometheus, a bumped replica count) is the usual trigger, not a
random failure. In the 2026-08-16 incident the cluster ran clean for 2.5 hours,
then `kube-prometheus-stack` installed at 00:23:51, and the first OOM kill
followed at 00:32:48.

## 7. Break the loop, then fix the cause

If the cluster cannot recover on its own, scaling the newest or heaviest
consumer to zero buys room for everything else to stabilize:

```sh
mise exec -- kubectl scale deployment <deployment> -n <namespace> --replicas=0
```

That is a stopgap, not a fix. The two real fixes are separate and both usually
needed:

- **More memory**, if the node is genuinely undersized for what is scheduled on
  it. Check `kubectl describe node` for allocatable memory against what every
  pod's requests actually sum to.
- **Requests on anything that was running BestEffort**, so the OOM killer has a
  QoS class to work with instead of picking whatever uses the most RAM among
  pods that reserved none.

## Related

- [0007](../adr/0007-resource-requests-on-critical-pods.md), the resource
  requests decision this incident produced.
- [0005](../adr/0005-single-node.md), what one node already gives up, including
  why PodDisruptionBudgets do not help here either.
- [Troubleshooting](troubleshooting.md), for narrower single-symptom issues.
