# 0009. Etcd snapshots and machine-config backups from in-cluster CronJobs

Status: Accepted, 2026-08-16

## Context

Every PVC in the cluster is covered by phase two's backup work eventually, but two
things are not, and cannot be, because neither lives in a PVC: etcd's own data, and the
Talos machine config actually running on the node. Rule 5 in AGENTS.md says the machine
config committed in `talos/` is meant to be the running node's antecedent, but nothing
today checks that they still agree, and ADR 0005 already flags etcd as the cluster's
single point of failure with "no peer to recover from."

Talos ships exactly the tools for this: `talosctl etcd snapshot` streams a consistent
snapshot of etcd, and `talosctl get mc v1alpha1 -o yaml` reads back the config the node
is actually running, both over the same authenticated API used for everything else.
Running them from a CronJob inside the cluster keeps the credential and the schedule in
Git rather than in a cron entry on the ThinkPad, which is not always on.

## Decision

A new `system-backup` namespace, owned by a `cluster-backup` app, running two daily
CronJobs against a shared PVC on `local-path` (backed by `/var/mnt/data`, per ADR 0004):

- `etcd-snapshot`, 03:15 daily, keeps the last 14 snapshots.
- `machineconfig-backup`, 03:30 daily, keeps the last 30 exports.

**Storage: a PVC, not hostPath.** local-path already provisions out of `/var/mnt/data`.
A PVC needs no `privileged` Pod Security label at all: the hostPath work that requires
it happens inside local-path-provisioner's own already-privileged namespace, via its
helper pod, not in the namespace requesting the PVC (see
`kubernetes/apps/local-path-storage/local-path-provisioner/app/local-path-storage.yaml`).
`components/namespace-privileged` and its hostPath machinery are not needed here.

**Credentials: `talosctl config new --roles`, not the in-cluster ServiceAccount CRD.**
Talos v1.13 actually has two ways to get a client certificate into a pod. The
`talos.dev/v1alpha1` `ServiceAccount` custom resource (`kubernetesTalosAPIAccess`,
landed in Talos v1.2) lets a pod mint its own certificate from a projected Kubernetes
ServiceAccount token, no static secret to manage. It needs a machine config change
(`machine.features.kubernetesTalosAPIAccess.enabled: true`, plus an `allowedRoles` and
`allowedKubernetesNamespaces` list) in `talos/talconfig.yaml`, and this change does not
touch `talos/` at all, by design. The static-certificate mechanism, `talosctl config new
<path> --roles=<role>`, needs no machine config change, because Talos's RBAC is already
on by default for any cluster bootstrapped since v0.11, which this one was. That is what
both CronJobs use. The ServiceAccount CRD path is a reasonable thing to revisit the next
time `talos/` changes for its own, unrelated reason.

**Superseded for the machine-config job by ADR 0011.** tuppr's machine config edit
(ADR 0010) was that unrelated reason. The `machineconfig-backup` job now uses the
ServiceAccount CRD instead of the static certificate described above; the reasoning here
still explains why it originally didn't, and still applies in full to the etcd-snapshot
job, which was not moved.

**Roles: as narrow as Talos allows, which is not equally narrow for both jobs.**
Talos's RBAC has four roles: `os:admin` (everything), `os:operator` (`os:reader` plus
reboot, shutdown, etcd backup and etcd alarm management), `os:reader` (safe read-only
calls, explicitly excluding the `secrets` namespace and the machine config resource,
because both can carry secrets), and `os:etcd:backup` (exactly one RPC,
`/machine.MachineService/EtcdSnapshot`, nothing else). The etcd job uses
`os:etcd:backup`: the narrowest role Talos has for anything, and it cannot do anything
but take a snapshot. The machine-config job has no equivalent: reading the
`MachineConfigs` resource is excluded from `os:reader` and not added back by
`os:operator`, so `os:admin` is the only role that can do it. That credential can reboot
the node, wipe disks and read every secret Talos holds, a materially larger blast radius
than the etcd job's. It gets its own certificate and its own Secret, never shared with
the etcd job's.

**Minting is a one-time manual step, the same shape as the age key.** Neither
certificate can be produced from anything already in Git, the same reason
`docs/runbooks/restore.md` gives for the age key and the Cloudflare token. Both CronJobs
ship with `spec.suspend: true` and reference a Secret that does not exist yet.
`talos-etcd-backup.PLACEHOLDER.yaml` and `talos-machineconfig-backup.PLACEHOLDER.yaml`,
next to the CronJobs, spell out the exact `talosctl config new` command, the SOPS
encryption step, and the follow-up edit to un-suspend the job, the same pattern as
`kubernetes/apps/monitoring/kube-prometheus-stack/app/alertmanager-discord-webhook.PLACEHOLDER.yaml`.
Neither certificate is minted as part of this change, so neither CronJob runs yet.

**No shell in the talosctl image, so two containers, not one.** `ghcr.io/siderolabs/
talosctl` is built `FROM scratch`: the binary and CA certificates, nothing else, no
`/bin/sh`. `talosctl etcd snapshot <path>` writes straight to a path and needs nothing
more, so the etcd job's init container runs it directly against a shared `emptyDir`.
`talosctl get mc v1alpha1 -o yaml` only ever writes to stdout, and capturing that into a
file needs a shell somewhere in that container's filesystem view. The machine-config
job's `fetch` init container gets one: an earlier init container copies a static
`busybox` binary onto a shared volume, and the talosctl container execs that copy to
redirect its own output. A second, ordinary container in both jobs then does the part
that was always going to need a shell anyway: a timestamped filename, retention, and
verification.

**Verification: what can actually be checked without a restore.** A snapshot that was
never restored is a guess, and this change cannot restore one against the live cluster
(see the runbook below). What the job verifies today: the init container's own exit
code (Kubernetes will not run the second container if it failed), that the file is
non-empty, and for the etcd snapshot specifically, that its size is a whole multiple of
4096 bytes, the page size every bbolt database is allocated in, which catches a
truncated transfer. That is not a real integrity check: bbolt has a proper one (a page
checksum), and neither the talosctl nor the busybox image ships the tooling to run it.
Restoring the snapshot against a throwaway Talos-in-Docker cluster, per `task
talos:test`, is the only real verification, and is not part of this change.

## Consequences

Good: both backups are scheduled, retained, and land in Git-declared, version-pinned
manifests instead of a cron entry on a machine that sleeps. The etcd job's credential is
about as narrow as Talos RBAC gets.

Bad, and worth being exact about:

- **Neither CronJob is live.** Both ship `suspend: true`. Someone has to run the
  one-time `talosctl config new` command, twice, before either job does anything. Until
  then this is manifests and a documented gap, not a working backup.
- **The machine-config credential is `os:admin`, not a narrow role**, because Talos does
  not have one for reading machine config. That is a real, larger blast radius than the
  etcd job's credential, accepted because there is no narrower option, not because it
  was overlooked.
- **A snapshot on `/var/mnt/data` shares a physical disk with the cluster it
  protects.** Both VHDXs behind Talos's disks are files on the same Hyper-V host. A
  host-disk failure takes the snapshot down with the node it was meant to help recover.
  Offsite copies are phase two, explicitly out of scope here.
- **On a single node, `bootstrap --recover-from` still needs an install to recover
  onto.** Talos supports this here: wipe or reinstall Talos on the surviving disk, then
  bootstrap fresh with `--recover-from` pointed at the snapshot, which is what
  `docs/runbooks/etcd-restore.md` documents. What does not exist on one node is the
  multi-node pattern of recovering onto a node that is still up while others rebuild
  around it. If the node and its disks are both gone, there is nothing to recover onto
  at all, and `docs/runbooks/restore.md`'s full rebuild is the only path: it does not use
  an etcd snapshot, and does not need one, because Flux and VolSync repopulate the
  cluster from Git and the PVC backups instead.
- **The machine-config export is a drift check, not a new recovery input.** The
  authoritative recovery source stays `talos/` in Git, per AGENTS.md rule 5. What the
  export adds is a record of what the node actually ran at a point in time, useful for
  spotting drift, not a replacement for the committed config.
- **Neither certificate renews itself.** `--crt-ttl` defaults to one year. Rotation is
  re-running the placeholder's steps before it expires, with nothing to page anyone when
  that date approaches.

## Alternatives

**The `talos.dev/v1alpha1` `ServiceAccount` CRD (`kubernetesTalosAPIAccess`).** No
static secret to mint, rotate or SOPS-encrypt: the pod exchanges its own projected
Kubernetes ServiceAccount token for a short-lived Talos certificate. Rejected for this
change only because it needs a `talos/talconfig.yaml` edit, out of scope here, not
because the mechanism is wrong.

**A restic-based tool, `talos-backup` or similar.** Handles S3 upload and encryption
out of the box, but pulls in age/restic machinery this cluster does not need yet for two
small, local files with a bounded retention count. Simply pruning old files in the job
itself is the smaller thing that does what phase one actually needs, the same reasoning
ADR 0004 already used for local-path over a heavier storage layer.
