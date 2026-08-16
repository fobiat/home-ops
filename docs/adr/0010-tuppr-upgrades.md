# 0010. tuppr for Talos and Kubernetes upgrades

Status: Accepted, 2026-08-16

## Context

Upgrading Talos or Kubernetes has been a manual `talosctl upgrade` /
`talosctl upgrade-k8s` walk, documented in `docs/runbooks/upgrade.md`. That
works, but it is imperative: a person runs commands by hand, decides when the
cluster is healthy enough to proceed, and remembers the exact sequence each
time. Nothing enforces a health check before the reboot, nothing records what
happened, and nothing is declared in Git the way every other change to this
cluster is (AGENTS.md rule 4).

Three options were on the table.

**Manual `talosctl`, status quo.** No new component, no new privileged
credential. Costs a person's full attention for every upgrade, with no
automatic health gate and no record beyond a runbook checklist.

**`system-upgrade-controller` (Rancher).** Generic node upgrade via
node-labelling and privileged host-access pods running arbitrary scripts. It
has no notion of the Talos API: an upgrade means shelling a privileged
container into the host and driving `talosctl` from inside a hand-written
script, which is exactly the kind of bespoke automation ADR reasoning like
this one exists to avoid. Immutable, API-driven OSes are not what it was
built for.

**Renovate-driven.** Renovate can open a PR bumping a pinned version string,
same as it already does for every container tag in this repo. It cannot
apply anything to a live node; it has no execution capability at all. So
"Renovate-driven" is not actually a third option, it is a detail of how the
other two options get their target version bumped. Once a real upgrade
resource exists, its `spec.talos.version` and `spec.kubernetes.version` are
exactly the kind of pinned, `# renovate:`-commented strings this repo already
manages that way.

**tuppr**, the option chosen. A Kubernetes controller: a `TalosUpgrade` or
`KubernetesUpgrade` custom resource declares a target version, the controller
health-checks the cluster, cordons and drains, calls the Talos API to
upgrade and reboot, waits for the node to come back healthy on the new
version, then moves to the next node. On this cluster that is one node, so
"moves to the next node" never happens, but the health-check-then-act shape
is the actual reason to prefer it: the same declarative, Git-recorded pattern
every other change on this cluster already follows.

## Decision

Ship tuppr's controller and CRDs (`kubernetes/apps/system-upgrade/tuppr/`),
inert. No `TalosUpgrade` or `KubernetesUpgrade` resource is committed. The
first real one is a deliberate, separate PR, reviewed with the actual target
version and the actual `flux-local diff` in front of the reviewer, not a
side effect of this one.

The reason is single-node arithmetic, not caution for its own sake. This
cluster has exactly one node, so an upgrade resource that reconciles on the
next Flux pass is not a rollout, it is an immediate, unattended reboot of the
only thing running the API server, etcd, and every workload. ADR 0005
accepted that every upgrade here is a real outage; nothing about tuppr
changes that, it only changes who decides when it happens. A CR sitting in
Git waiting for the next `kubectl apply` or Flux reconcile is not a safe way
for that decision to get made by accident.

### Single-node behaviour, confirmed against the current controller

tuppr's own docs state directly that draining is skipped on single-node
clusters, because there is nowhere to drain to and evicting the upgrade pod
would strand the node. This is automatic, not a flag: from the current
quickstart docs (home-operations/tuppr, chart 0.5.0), "With one node, the
upgrade pod runs on the node being rebooted. tuppr handles this
automatically (issues the upgrade with `--wait=false`, skips the drain, and
tracks completion by polling node readiness over the Talos API), then
uncordons the node once the upgrade is verified." Nothing in
`kubernetes/apps/system-upgrade/tuppr/app/helmrelease.yaml` needs to ask for
this behaviour; it falls out of tuppr seeing one node.

### The credential

tuppr talks to the Talos API using a Talos-native `ServiceAccount`
(`talos.dev/v1alpha1`), not a Kubernetes Secret assembled by hand. With the
chart's default `talosServiceAccount.create: true`, the Helm release creates
that CRD instance itself; Talos's own controller, once granted, mints the
matching `<release>-talosconfig` Secret in the `system-upgrade` namespace and
the Deployment mounts it. Nothing about this credential is generated outside
Git, and no SOPS-encrypted secret file is needed, because there is no secret
material to encrypt: Talos issues the credential directly to the CRD.

The prerequisite is a machine config change, not a manifest:

```yaml
machine:
  features:
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:admin
      allowedKubernetesNamespaces:
        - system-upgrade
```

That field lives in `talos/talconfig.yaml`, which this PR does not touch.
Editing and applying Talos machine config is exactly the kind of live-cluster
change this task was scoped to avoid, and it deserves its own deliberate
commit and `talosctl apply-config` run, not a side effect of adding a
controller. The exact steps are in `docs/runbooks/tuppr-upgrade.md`. Until
that patch is applied, the `system-upgrade` namespace has no standing grant
to the Talos API, the `talos.dev/v1alpha1 ServiceAccount` CRD instance never
gets a matching Secret, and the tuppr pod sits unable to start rather than
running with no credential.

The chart hardcodes `os:admin` as the requested role; it is not a values
knob. That is the same role a person types at the `talosctl` prompt by hand
today, so this is not a new level of access being granted, it is the
existing level of access being handed to a controller instead of a person.
Worth stating plainly: any pod that can reach that Secret has full
administrative control over the only node in the cluster. The
`system-upgrade` namespace exists to run exactly one thing for exactly this
reason, matching rule 11 (one way to do each thing) in the small: one
namespace, one controller, one credential, nothing else sharing the blast
radius.

## Consequences

Good: the next real upgrade is a Git diff with a target version in it,
carries an automatic health check before it touches anything, and tuppr's
own status and events are the record of what happened, in place of a person's
memory of a runbook. Renovate can eventually own bumping the pinned version
the same way it owns every other version pin here.

Bad: the controller does nothing useful until two separate, deliberate steps
happen outside this PR: the machine config patch, and the first real upgrade
resource. Someone has to remember both. A high-privilege, always-live
credential sits in the cluster the moment the machine config patch lands,
whether or not an upgrade is in progress.

This does not remove the single-node outage risk PLAN.md's risk register
already names. It moves who and what triggers that outage from a person
running `talosctl upgrade` to a person merging a PR, and adds a health check
in between that the manual path never had.
