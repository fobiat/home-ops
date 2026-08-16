# Cluster backup

Two CronJobs in the `system-backup` namespace, backing up the two things that don't
live in a PVC and so aren't covered by phase two's regular volume backups: etcd's own
data, and the Talos machine config actually running on the node. See
[ADR 0009](adr/0009-cluster-backup-credentials.md) for the full reasoning and
[ADR 0011](adr/0011-reconcile-backup-credential-onto-serviceaccount-crd.md) for why
the two jobs authenticate to the Talos API differently.

Both write to the same 5Gi PVC (`cluster-backup-data`, `local-path`).

Both CronJobs run `Etc/UTC` rather than `Europe/London`. VolSync's own cronspecs (below)
have no timezone field, so the whole 03:15-04:40 backup window is pinned to UTC to keep
the stagger real instead of drifting an hour twice a year with BST.

## etcd-snapshot

Daily at 03:15 UTC, keeps the last 14 snapshots. **Running**, since 2026-08-16. Its
credential is a static Talos client certificate scoped to `os:etcd:backup`, the
narrowest role Talos has (exactly one RPC, nothing else), minted once by hand
(`talosctl config new ... --roles os:etcd:backup`) and delivered via SOPS
(`talos-etcd-backup.sops.yaml`) rather than the ServiceAccount CRD mechanism
`machineconfig-backup` uses.

## machineconfig-backup

Daily at 03:30 UTC, keeps the last 30 exports. **Running.** Authenticates via
a `talos.dev/v1alpha1 ServiceAccount` (`os:admin`, the only role Talos has for reading
machine config), the same mechanism [tuppr](adr/0010-tuppr-upgrades.md) uses. Talos
mints the credential automatically once the `system-backup` namespace is granted, no
manual cert to mint or rotate for this one.

The export is a drift check, not a recovery input: the authoritative source stays
`talos/` in Git (rule 5). It's useful for spotting when the running node has drifted
from what's committed, not as something a restore reads from.

## Offsite copy

A VolSync `ReplicationSource` (`cluster-backup-data`, 04:40 UTC, 70 minutes after
machineconfig-backup's last writer) ships whatever both CronJobs above have written to
an interim restic repository on its own PVC (`volsync-repo`, same namespace), same
mechanism as [Gatus's backup](gatus.md). No custom `moverSecurityContext`: neither
CronJob sets one, so their files land owned by UID 0 with no capabilities dropped, which
an unadorned mover can already read. A suspended sibling app,
`cluster-backup-restore`, ships the restore path disarmed; see
[gatus.md](gatus.md#restoring) for how arming one works (same mechanism, this
namespace's own `ReplicationDestination`).

## Verifying a backup actually ran

```sh
kubectl -n system-backup get cronjob
kubectl -n system-backup exec -it deploy/whatever-has-the-pvc-mounted -- ls -la /backup
```

There's no dedicated debug pod for this; the simplest way is a throwaway one mounting
`cluster-backup-data`:

```sh
kubectl -n system-backup run pvc-check --rm -i --restart=Never \
  --image=docker.io/library/busybox:1.37.0-musl \
  --overrides='{"spec":{"containers":[{"name":"pvc-check","image":"docker.io/library/busybox:1.37.0-musl","command":["ls","-la","/backup/machineconfig"],"volumeMounts":[{"name":"v","mountPath":"/backup"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"cluster-backup-data"}}]}}'
```

Use the `-musl` busybox tag if you're copying this pattern elsewhere: the plain tag is
glibc-dynamic and breaks when exec'd inside a `scratch`-based image, see the gotcha
noted in `docs/homepage.md` and PR #42.

## What this does not cover

Neither job is a restore mechanism by itself. `docs/runbooks/etcd-restore.md` documents
recovering from an etcd snapshot; `docs/runbooks/restore.md` documents the full rebuild
path, which uses Git and PVC backups, not these CronJobs at all. A snapshot on
`/var/mnt/data` shares a physical disk with the cluster it protects, an offsite copy is
phase two, not done here.
