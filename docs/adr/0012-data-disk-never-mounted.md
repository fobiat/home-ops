# 0012. The data disk was never mounted, and minSize is why

Status: Accepted, 2026-08-16

## Context

ADR 0004 chose local-path backed by a dedicated second SSD, "which Talos hands over
as a `UserVolumeConfig` mounted at `/var/mnt/data`". That mount never happened. From
the day the cluster was built until 2026-08-16, `talosctl get volumestatus u-data`
reported:

    spec.phase: failed
    errorMessage: 'no disks matched for volume (1 matched selector):
                   1 have not enough space, 0 have wrong format, 0 have other issues'

`sdb` reports `size: 214748364800` bytes, which is exactly 200.0 GiB. `talconfig.yaml`
asked for `minSize: 200GiB`. A 200GiB partition does not fit on a 200GiB disk: GPT
metadata sits at both ends and Talos aligns partitions, so a few MiB come off the top
before any partition is cut. Talos's `minSize` gates *disk selection* rather than
truncating the request, so the only candidate disk was rejected and provisioning
stopped.

Nothing surfaced the failure. `/var/mnt/data` still existed as an ordinary directory
on the EPHEMERAL partition, so local-path-provisioner wrote there happily, PVCs bound,
pods ran, and every dashboard was green. node_exporter cannot help either: an
unmounted disk is not a filesystem with a bad value, it is a series that does not
exist, and no threshold alert fires on an absent series.

The consequence was that all five PVCs, including `cluster-backup-data` holding the
etcd and machine-config snapshots, sat on the partition `talosctl reset` wipes. A
single reset would have taken the data and its only backup together.

## Decision

`minSize: 190GiB`, with no `maxSize`, so the volume still claims the whole disk while
leaving roughly 10 GiB of margin against a future disk that is fractionally smaller.

Existing PVC data was deliberately discarded rather than migrated. The volumes had to
be deleted before the config was applied, because a filesystem mounted at
`/var/mnt/data` shadows whatever is already there, and Talos has no shell with which
to reach stranded data afterwards.

## Consequences

Good: PVCs now live on a disk that survives a reset, and the backup volume no longer
shares a partition with what it backs up.

Bad: seven days of Prometheus metrics, Loki's log history, Grafana's sqlite, Gatus's
uptime history and one machine-config snapshot were lost. Provisioned dashboards came
back from the ConfigMaps in `grafana-dashboards`, and the snapshot was rewritten that
night.

The lasting lesson is about verification rather than arithmetic: a green cluster
proved nothing about where its bytes were landing. `talosctl get volumestatus` is now
a required check after any storage change, and a `DataVolumeNotMounted` alert exists
so a recurrence is loud. That matters most on the Proxmox rebuild, where the disk
selectors and this same GiB arithmetic all have to be redone.

## Alternatives

**Migrate the data across.** Scale everything down, copy the directories onto the newly
mounted volume, scale back up. Rejected: it is several careful steps across a
mount-shadowing boundary, and what it protects is about ten hours of homelab telemetry
plus regenerable snapshots.

**Leave it and fix it on the Proxmox box.** Rejected because phase two builds a backup
system, and building one whose repository sits on the wipe-on-reset partition is worse
than not building it, since the green status would imply protection that was not there.
