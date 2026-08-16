# Etcd snapshot restore

!!! danger "UNTESTED"

    This procedure has never been executed. Until someone has run it end to end against
    a throwaway cluster and removed this banner, treat it as a plan rather than a
    runbook. See AGENTS.md rule 9.

What to do when etcd itself is corrupted, an interrupted defrag, a bad write, a botched
upgrade, but the node, its disks and Talos itself are otherwise healthy. If the node or
a disk is gone instead, use [Restore](restore.md): that path does not need an etcd
snapshot at all, because Flux and VolSync rebuild the cluster from Git and the PVC
backups.

See [ADR 0009](../adr/0009-cluster-backup-credentials.md) for how these snapshots are
taken and what they do and do not cover.

## Before you start

Confirm this is actually etcd, not something upstream of it: `talosctl service etcd` and
`talosctl logs etcd` on the node, and [Troubleshooting](troubleshooting.md) if the
symptoms look wider than one service.

## 1. Get the newest good snapshot off the cluster

The CronJob's completed pods do not stay running, so `kubectl cp` has nothing to attach
to. Start a throwaway pod that mounts the same PVC read-only instead:

```sh
mise exec -- kubectl run backup-browser --rm -it --restart=Never \
  --image=docker.io/library/busybox:1.37.0 \
  --overrides='{"spec":{"containers":[{"name":"backup-browser","image":"docker.io/library/busybox:1.37.0","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/backup","readOnly":true}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"cluster-backup-data","readOnly":true}}]}}' \
  -n system-backup -- sh
```

List `/backup/etcd`, pick the newest file, and in a second terminal:

```sh
mise exec -- kubectl cp system-backup/backup-browser:/backup/etcd/<file> ./etcd.snapshot
```

## 2. Recover

`talosctl bootstrap --recover-from` takes a path local to the machine running
`talosctl`, so run it from wherever `./etcd.snapshot` landed in step 1:

```sh
mise exec -- talosctl bootstrap --recover-from=./etcd.snapshot --nodes 192.168.0.226
```

Talos stops etcd on the node itself as part of this; nothing needs to be stopped by
hand first. Only add `--recover-skip-hash-check` if the file came from copying
`/var/lib/etcd/member/snap/db` directly off the node rather than from a proper
`talosctl etcd snapshot`, which is not how these CronJobs work.

This is a fresh bootstrap, in the same sense `talosctl bootstrap` is elsewhere in this
repo: run it once. If it fails partway, treat the etcd data directory as gone and fall
back to [Restore](restore.md)'s full rebuild rather than retrying blind.

## 3. Confirm

- `talosctl etcd status` reports a healthy single-member cluster.
- `kubectl get nodes` and `flux get all` both come back.
- Whatever was different between the snapshot's timestamp and the corruption (a Flux
  reconcile, a cert-manager renewal) either reconciles back on its own or is small
  enough to have been worth losing. The gap between "when the snapshot was taken" and
  "when etcd broke" is real data loss; the daily schedule bounds it to at most a day.

## Testing this

Same shape as [Restore](restore.md)'s own test: bring up `talosctl cluster create
--provisioner docker`, take a snapshot, corrupt or delete the etcd data directory on
purpose, and walk the steps above against the throwaway cluster. Fix whatever is wrong,
then delete the banner.
