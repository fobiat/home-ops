# 0004. local-path rather than TopoLVM or Longhorn

Status: Accepted, 2026-08-15

## Context

The cluster needs persistent volumes for Grafana, Prometheus and whatever comes later.
There is one node and a dedicated second SSD.

Most of the storage options in this space assume more than one node, because their value
is replication.

## Decision

Rancher's local-path-provisioner, backed by the second SSD, which Talos hands over as a
`UserVolumeConfig` mounted at `/var/mnt/data`.

> **Correction, 2026-08-16.** The `UserVolumeConfig` described here never provisioned.
> `/var/mnt/data` was a directory on the ephemeral partition from the day the cluster
> was built until the fix in ADR 0012. The decision recorded here stands; the claim
> that it was in effect did not.

## Consequences

Good: almost nothing to run. No extra CRDs, no operator, no system extension, no
hugepages. It is the smallest thing that provides a working StorageClass.

Bad, and this is the real cost: local-path does not implement VolumeSnapshot. VolSync is
therefore limited to its `Direct` copy method, which reads a live volume while the
application is still writing to it. For Grafana that is fine. For a database it is not,
and the first database that arrives forces this decision to be revisited.

Also bad: moving off local-path later means migrating data, not just changing a
StorageClass name.

## Alternatives

**TopoLVM.** Thin provisioning, real CSI snapshots, online resize. The upgrade path when
snapshots start mattering. Rejected for now because it needs an LVM2 system extension and
a workaround for Talos's read-only `/etc/lvm` (`lvm.hostWritePath=/var/lib/lvm`), and
there is an open compatibility issue against Talos 1.11. Complexity ahead of need.

**Longhorn.** Recommends 4 vCPU and 8GB per storage node and its V2 engine reserves a
core plus 2GiB of hugepages. On one node it delivers a snapshot API and a web UI in
exchange for that, and no redundancy at all, because there is nowhere to put a second
replica.

**Rook-Ceph.** Documents a three node minimum. Talos's own storage guide notes Ceph "can
be rather slow for small clusters". Not a real option here.
