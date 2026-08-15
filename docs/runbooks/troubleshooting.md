# Troubleshooting

## Check this first

**Did the Windows host reboot?**

The Talos node is a Hyper-V guest on a Windows desktop that is in daily use. Windows
Update reboots it without warning, and that takes the whole cluster down. This is the
single most likely cause of an unexplained outage, and it is not a Kubernetes problem.

Confirm the VM is running and set to start automatically before investigating anything
else.

## The node is NotReady

Expected immediately after a bootstrap, before Cilium is installed. Nothing schedules
without a CNI, including Flux's own controllers.

If it happens later, Cilium is the first thing to look at.

## Cilium will not start, or CoreDNS is broken

Three Talos-specific settings cause most of this:

- Cilium must point at KubePrism (`k8sServiceHost: localhost`, port 7445), not the real
  API server address.
- `SYS_MODULE` must not be in Cilium's capability list. Talos blocks workloads from
  loading kernel modules, so requesting it fails.
- `forwardKubeDNSToHost: true` combined with `bpf.masquerade: true` breaks CoreDNS. Pick
  one.

## A pod is Pending forever

Two common causes on a single node.

**Anti-affinity.** Many upstream charts default to spreading replicas across nodes.
With one node the second replica can never schedule. Check the chart's `affinity` block
and its default replica count.

**A volume waiting to be restored.** During a restore, `Pending` means VolSync is
populating the volume. That is the system working. Leave it.

## Prometheus is not scraping the control plane

kube-scheduler and kube-controller-manager bind to `127.0.0.1` by default on Talos and
need `--bind-address=0.0.0.0` in the machine config.

etcd metrics on port 2381 need mTLS certificates pulled from `/system/secrets/etcd` on
the node and mounted into Prometheus as a Secret. This is the fiddliest part of the
observability setup.

## I cannot reach the cluster

Try `talosctl` before `kubectl`. Tailscale runs as a Talos system extension and comes up
before Kubernetes, so the node should be reachable over the tailnet even when the cluster
itself is broken. If `talosctl` works and `kubectl` does not, the problem is in the
cluster. If neither works, the problem is the node or the host.

## Flux says it reconciled but nothing changed

Check that the change is actually committed and pushed. Flux reconciles what is in Git,
not what is in the working tree. This sounds obvious and is still the most common cause.
