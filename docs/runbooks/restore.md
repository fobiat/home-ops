# Restore

!!! danger "UNTESTED"

    This procedure has never been executed. Until someone has run it end to end against
    a throwaway cluster and removed this banner, treat it as a plan rather than a
    runbook. See AGENTS.md rule 9.

What to do when the node is gone: dead disk, dead machine, or an upgrade that could not
be rolled back.

## What you need before you start

Three things cannot be regenerated from this repository. If you do not have all three,
stop and find them first.

1. **The age private key.** In NordPass. Without it every encrypted file here is noise.
2. **The Cloudflare API token.** Also NordPass. Needed for DNS-01 certificates.
3. **The Talos machine config**, which is in `talos/` in this repository, plus
   `talsecret.sops.yaml` which is encrypted with the age key above.

An etcd snapshot is **not** in that list, deliberately. On a single node
`talosctl bootstrap --recover-from` assumes a surviving node to recover onto, which by
definition does not exist in this scenario. Snapshots cover etcd corruption on a machine
that is otherwise fine. They do not cover a dead disk. If etcd is corrupted but the node
and its disks are not, see [Etcd snapshot restore](etcd-restore.md) instead: that
scenario has a real recovery path and this one does not need it.

## Order

1. **Rebuild the node.** Recreate the Hyper-V VM, boot the Talos image built from the
   schematic in `talos/schematic.yaml`, and apply the machine config. See
   [Bootstrap](../bootstrap.md), which is the same procedure.
2. **Install Cilium.** Nothing schedules until a CNI is running, including Flux. The node
   sitting at `NotReady` at this point is expected, not a fault.
3. **Bootstrap Flux** against this repository with the age key available for decryption.
4. **Wait.** Flux reconciles the platform back: cert-manager, gateways, external-dns,
   observability. This takes a while and needs no help.
5. **Persistent volumes come back on their own.** Pods sit `Pending` while VolSync's
   volume populator restores each one from its restic repository. Do not intervene.
   `Pending` here means working, not stuck.
6. **Confirm the deadman cleared.** healthchecks.io should stop alerting once Prometheus
   and Alertmanager are back. That is the signal the whole chain is healthy, not just the
   apps.

## What this does not restore

Anything that was never in a persistent volume or in this repository. If it only existed
because someone ran `kubectl apply` once, it is gone, which is the entire argument for
rule 4.

## Testing this

Rehearse against a throwaway cluster rather than the real one:

```sh
talosctl cluster create --provisioner docker --name restore-test
# bootstrap Flux against this repo, point VolSync at a copy of the restic repository
talosctl cluster destroy --name restore-test
```

Do that, fix whatever is wrong with the steps above, then delete the banner.
