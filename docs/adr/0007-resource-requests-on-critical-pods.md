# 0007. Resource requests on cluster-critical pods, never BestEffort QoS

Status: Accepted, 2026-08-16

## Context

On 2026-08-16 the cluster crashed almost totally. kube-controller-manager restarted
11 times, kube-scheduler 12, cilium-envoy, cilium-operator, helm-controller,
source-controller and external-dns (23 restarts) all sat in CrashLoopBackOff, and
effectively every pod in every namespace was restarting in synchronized waves
(00:44:45-49, 00:48:25-42, 00:52:32-53:37).

The synchronized waves ruled out independent per-app bugs and pointed at a
node-level cause. kube-scheduler and kube-controller-manager logs both ended with
`Failed to renew lease ... context deadline exceeded` and `leaderelection lost`,
preceded by `watch ended with error ... "http2: client connection lost"`. Every
controller lost leader election at once because none of them could reach the
apiserver.

`talosctl dmesg` showed Talos's own `runtime.OOMController` firing 60 times,
logging `Sending SIGKILL to cgroup` under
`/sys/fs/cgroup/kubepods/besteffort/`. The killed pod UIDs resolved to exactly
`cilium-envoy` and `cilium-operator`, the only two BestEffort-QoS pods in the
entire cluster. Cilium's Helm values set no `resources` at all, so those pods had
no requests, put them in BestEffort QoS, and made them Talos's first OOM target
every time.

Killing Cilium repeatedly broke pod networking, which is what severed the
apiserver connections and caused the cluster-wide leader-election failures.
Restarts re-synced informer caches, which used more memory and CPU, which
triggered more OOM kills. The cluster could not self-heal from inside that loop.

The trigger was `kube-prometheus-stack` 88.3.0, installed at 00:23:51 on a 4GB VM
(3878MB total, ~3.2Gi allocatable). The cluster had run clean for about 2.5 hours
before that install. The first OOM kill followed at 00:32:48. `kube-apiserver`
alone held 823MB RSS; Prometheus was at 420MB and still climbing.

A second failure on 2026-08-17 came from limits that were too low rather than an
OOM. Grafana sat at its 384Mi cgroup cap and Alloy at 256Mi. Their file-cache
working sets were reclaimed and reread continuously, producing about 2.2GB/s of
system-disk reads and 80% I/O pressure. Control-plane and application probes then
timed out together. The cgroup counters recorded more than a billion direct
reclaim scans and file-cache refaults in each container without an OOM kill.

Immediate fix: the monitoring stack was scaled to zero to break the loop, then the
VM's memory was raised from 4GB to 8GB (7918MB total). OOM trigger count went to 0
and all 20 pods returned to Running.

## Decision

Every component whose death can take the cluster down with it, Cilium above all,
carries explicit `resources.requests` and therefore gets Burstable or Guaranteed
QoS, never BestEffort. On Talos, BestEffort QoS is not merely a scheduling hint,
it selects which cgroup gets SIGKILLed first under memory pressure.

Cilium's agent, operator and envoy now set requests in `bootstrap/helmfile.yaml`.
kube-prometheus-stack was retuned so no container in it is BestEffort either.
Grafana and Alloy also need limits large enough to retain their active file-cache
working sets. Their limits are 768Mi and 1Gi respectively, with requests based
on observed steady-state use. Alloy filled a 512Mi follow-up limit within minutes
and resumed direct reclaim, so that intermediate value was not retained.

## Consequences

Good: the OOM killer can still fire under pressure, but it now fires by QoS class
and usage rather than picking the CNI first every time. A future memory spike
kills a BestEffort workload pod, not the thing every other pod depends on to
reach the apiserver.

Bad: a request reserves memory whether or not it is used, on a node that was
already tight before the RAM increase. Every component added to the cluster from
here needs its resource footprint checked against what is left, not just against
whether it schedules.

A low memory limit can still take this node down without an OOM. Direct reclaim
can saturate the system disk until leader elections and health probes fail. Limit
changes therefore require checking cgroup `memory.events` and `memory.stat`, not
only RSS and restart reasons.

This does not fix the underlying constraint that one node's memory is shared
across the entire control plane and every workload. It only makes sure that when
memory runs out, the CNI is not what gets killed first.
