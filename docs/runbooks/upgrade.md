# Upgrade

!!! warning "UNTESTED"

    Not yet executed on this cluster. See AGENTS.md rule 9.

Upgrading Talos or Kubernetes on a cluster with one node in it.

## Accept the outage first

There is one node. It runs the API server, etcd, and every workload. Upgrading it means
rebooting it, and there is nowhere to move anything to. The cluster is down for the
reboot. Plan for it rather than trying to engineer around it.

Cordon and drain do nothing useful here, and worse, a naive upgrade can strand the node:
the pod running the upgrade gets evicted mid-drain and there is nothing left to finish
the job. This is exactly why `tuppr` skips draining on single-node clusters, and why
rolling your own upgrade automation needs the same behaviour.

Do not rely on PodDisruptionBudgets. Talos ignores eviction failures during its own
drains, so a PDB will not stop anything.

## Before

1. Take an etcd snapshot and copy it off the node.
2. Take a Hyper-V checkpoint of the VM. On one node this is the only real rollback, and
   it is faster than any restore.
3. Check the Talos release notes for machine config schema changes. Talos 1.14 moves
   Kubernetes settings out of the monolithic v1alpha1 document into separate kinds, which
   will need config changes before that upgrade.

## Talos

Talos OS upgrades do not upgrade Kubernetes. They are separate, deliberate actions.

Since Talos 1.8 the previous ephemeral state is preserved by default, so `--preserve` is
no longer needed and the flag is deprecated for removal in 1.18.

If the new image fails to boot, Talos rolls back automatically to the previous A/B
partition. `talosctl rollback` does it manually, and only goes back one version.

## Kubernetes

Separate step, after the OS upgrade has settled, using `talosctl upgrade-k8s`.

## After

- The node returns `Ready` without help
- `flux get all` is clean
- Grafana is reachable and scraping
- The deadman check at healthchecks.io has cleared
