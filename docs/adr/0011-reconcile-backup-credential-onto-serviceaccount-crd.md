# 0011. Reconcile the machine-config backup credential onto the ServiceAccount CRD

Status: Accepted, 2026-08-16

## Context

ADR 0009 and ADR 0010 each solved the same underlying problem, a pod needing an
`os:admin` Talos API credential, with two different mechanisms:

- `cluster-backup`'s `machineconfig-backup` CronJob (ADR 0009) used a static certificate
  minted once with `talosctl config new --roles os:admin`, SOPS-encrypted and committed.
  Chosen specifically to avoid a `talos/talconfig.yaml` edit, which was out of scope for
  that change. The certificate was never actually minted, so the CronJob shipped
  `suspend: true` and did nothing.
- `tuppr` (ADR 0010) used the `talos.dev/v1alpha1` `ServiceAccount` CRD instead: a pod
  requests a role via a Kubernetes-native custom resource, and Talos mints the matching
  Secret itself once `machine.features.kubernetesTalosAPIAccess` grants the requesting
  namespace and role. ADR 0009 flagged this as "a reasonable thing to revisit the next
  time `talos/` changes for its own, unrelated reason." ADR 0010 is that reason: the
  machine config edit tuppr needed anyway removes the only reason ADR 0009 gave for not
  using it.

Rule 11 (one way to do each thing) argues against carrying two credential mechanisms for
what is the same privilege level solving the same kind of problem.

## Decision

Move the `machineconfig-backup` CronJob onto the ServiceAccount CRD, matching tuppr:

- `talos/talconfig.yaml`'s `kubernetesTalosAPIAccess` patch gains a second entry in
  `allowedKubernetesNamespaces`, `system-backup`, alongside `system-upgrade`.
  `allowedRoles` stays `[os:admin]`, already the role both consumers need.
- `kubernetes/apps/system-backup/cluster-backup/app/talos-serviceaccount.yaml` declares a
  `talos.dev/v1alpha1 ServiceAccount` named `machineconfig-backup-talosconfig` requesting
  `os:admin`, the same pattern as tuppr's chart-managed one.
- The CronJob mounts the resulting `machineconfig-backup-talosconfig` Secret instead of
  the old `talos-machineconfig-backup` one. Talos mints that Secret with a `config` key,
  not `talosconfig`, so the volume remaps it with `items` to the filename `talosctl`
  expects.
- `talos-machineconfig-backup.PLACEHOLDER.yaml` is deleted. There is no static credential
  left to mint, encrypt, or rotate for this job.
- `spec.suspend` flips to `false`. The only reason it was `true` was the missing
  credential; the credential now provisions itself the moment this PR merges and the
  machine config grant is applied, so there is no remaining reason to keep it off.

**The etcd-snapshot job is untouched, on purpose.** It uses `os:etcd:backup`, the
narrowest role Talos has, exactly one RPC and nothing else. Moving it onto the shared
`kubernetesTalosAPIAccess` grant would work mechanically, but it would also mean the
`system-backup` namespace's standing grant has to list a second role, widening what any
future pod in that namespace could request. The machine-config job already needs
`os:admin`, so consolidating onto it costs nothing that wasn't already true; giving the
etcd job the same blast radius for no reason would be a regression, not a reconciliation.
It keeps its own static cert per ADR 0009, unminted, still suspended.

## Consequences

Good: one mechanism for `os:admin`-level Talos API access from a pod, not two. No SOPS
file to encrypt, no one-time `talosctl config new` step, no yearly rotation to remember,
for this credential specifically, since Talos mints and rotates it itself. The
`machineconfig-backup` job actually runs now instead of shipping as an inert manifest.

Bad: `allowedKubernetesNamespaces` naming a second namespace means the standing
`os:admin` grant is no longer scoped to a single controller in a single namespace, the
property ADR 0010 leaned on to justify the risk (rule 11 in the small: "one namespace,
one controller, one credential"). Any pod that lands in `system-upgrade` or
`system-backup` and can request the `talos.dev/v1alpha1 ServiceAccount` CRD with role
`os:admin` gets full node control. Both namespaces are still single-purpose today (tuppr
only; the two backup CronJobs only), so the practical blast radius is unchanged, but the
grant itself is now a list, not a singleton, and that is worth noticing the next time
something else wants a namespace added to it.
