# Upgrading with tuppr

!!! warning "UNTESTED"

    Not yet executed on this cluster. See AGENTS.md rule 9.

Performing a Talos or Kubernetes upgrade through the `tuppr` controller
instead of running `talosctl` by hand. See `docs/runbooks/upgrade.md` for the
manual path and `docs/adr/0010-tuppr-upgrades.md` for why tuppr was added and
what it does and does not change about a single-node upgrade.

tuppr's controller and CRDs are already running once
`kubernetes/apps/system-upgrade/tuppr` is merged. No `TalosUpgrade` or
`KubernetesUpgrade` resource is committed by that PR: this runbook is how you
create the first one, deliberately, when there is an actual version to move
to.

## Accept the outage first

Same as the manual runbook: one node, no drain destination, the API server
and etcd go down for the reboot. tuppr detects the single node automatically
and skips the drain rather than stranding the node evicting its own upgrade
pod. It does not remove the outage.

## Step 1: the machine config prerequisite (one time)

tuppr authenticates to the Talos API through a Talos-native credential that
Talos itself issues once granted. It has not been granted yet: this repo's
`talos/talconfig.yaml` does not carry the required patch, on purpose, since
machine config changes are a separate, deliberate class of change from
adding a controller. Do this once, before the first `TalosUpgrade` or
`KubernetesUpgrade` is ever created.

1. Add a patch to `controlPlane.patches` in `talos/talconfig.yaml`:

   ```yaml
   - |-
     machine:
       features:
         kubernetesTalosAPIAccess:
           enabled: true
           allowedRoles:
             - os:admin
           allowedKubernetesNamespaces:
             - system-upgrade
   ```

2. Regenerate the machine config: `task talos:generate`.
3. Check what the change actually does before sending it to the only node:
   `talosctl apply-config --dry-run --nodes 192.168.0.226 --file talos/clusterconfig/home-ops-talos-1.yaml`.
   `task talos:apply` is the wrong command here, it passes `--insecure` and
   only works against a node still in maintenance mode. This node is
   bootstrapped and running, so apply against it directly with the real
   `talosconfig`:
   `talosctl apply-config --nodes 192.168.0.226 --file talos/clusterconfig/home-ops-talos-1.yaml`.
4. Confirm the grant took: once tuppr's Deployment is running, the
   `talos.dev/v1alpha1 ServiceAccount` it created gets a matching Secret:
   `kubectl -n system-upgrade get secret tuppr-talosconfig`. Before this step
   that Secret does not exist and the tuppr pod cannot start.

Commit the `talconfig.yaml` change on its own PR, with its own
`flux-local diff` (machine config is not part of the Flux-managed tree, but
the same discipline of reviewing the actual generated diff before applying
still applies, per AGENTS.md rule 6).

## Step 2: confirm the controller is healthy

```bash
kubectl -n system-upgrade get deployment tuppr
kubectl -n system-upgrade get pods
kubectl -n system-upgrade get secret tuppr-talosconfig
```

The pod should be `Running` and `1/1 Ready`. If it is stuck creating with an
unmounted-secret event, step 1 was not completed or not applied yet.

## Step 3: before any upgrade

Same as the manual runbook:

1. Take an etcd snapshot and copy it off the node.
2. Take a Hyper-V checkpoint of the VM.
3. Check the Talos or Kubernetes release notes for anything that needs a
   config change first (Talos 1.14's machine config restructuring is the
   known one at the time of writing).

## Step 4: commit the upgrade resource

Create the CR as a real file in the app, so it goes through the same review
and `flux-local diff` as everything else in this repo, rather than a
`kubectl apply` that Git never sees (AGENTS.md rule 4).

For a Talos upgrade, `kubernetes/apps/system-upgrade/tuppr/app/talos-upgrade.yaml`:

```yaml
---
apiVersion: tuppr.home-operations.com/v1alpha1
kind: TalosUpgrade
metadata:
  name: cluster
spec:
  talos:
    # renovate: datasource=docker depName=ghcr.io/siderolabs/installer
    version: v1.13.9
  healthChecks:
    - apiVersion: v1
      kind: Node
      expr: status.conditions.exists(c, c.type == "Ready" && c.status == "True")
```

For a Kubernetes upgrade,
`kubernetes/apps/system-upgrade/tuppr/app/kubernetes-upgrade.yaml`:

```yaml
---
apiVersion: tuppr.home-operations.com/v1alpha1
kind: KubernetesUpgrade
metadata:
  name: kubernetes
spec:
  kubernetes:
    # renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
    version: v1.36.4
  healthChecks:
    - apiVersion: v1
      kind: Node
      expr: status.conditions.exists(c, c.type == "Ready" && c.status == "True")
      timeout: 10m
```

Add whichever file to
`kubernetes/apps/system-upgrade/tuppr/app/kustomization.yaml`'s `resources`
list, run `task diff` and read the rendered output before opening the PR, and
put the exact target version in the PR title. Only one `KubernetesUpgrade`
can exist at once (the admission webhook rejects a second); to upgrade again
later, edit `spec.kubernetes.version` on the same file instead of adding
another.

## Step 5: watch it

Once merged and reconciled:

```bash
kubectl get talosupgrade -w
kubectl describe talosupgrade cluster
# or
kubectl get kubernetesupgrade -w
kubectl describe kubernetesupgrade kubernetes
```

`kubectl describe` shows the health check and phase events
(`HealthChecksStarted`, `HealthChecksPassed`, `Upgrading`, ...). Since there
is one node, expect the upgrade Job to run on the node being rebooted and the
pod's own connection to drop mid-run; that is tuppr's documented single-node
path, not a failure.

## If something looks wrong mid-run

Suspend without deleting the resource:

```bash
kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend="true"
```

Remove the suspend annotation to resume, or delete the CR file, take it out
of `kustomization.yaml`, and commit that to abandon the run. Deleting the CR
does not roll back a version already applied to the node.

## After

Same checklist as the manual runbook:

- The node returns `Ready` without help.
- `flux get all` is clean.
- Grafana is reachable and scraping.
- The deadman check at healthchecks.io has cleared.
- `.status.history` on the CR shows the completed run.

## Removing tuppr's access afterward

The machine config grant from step 1 is not upgrade-scoped; it stays live
between upgrades so tuppr never needs it re-applied. Revoking it between
upgrades is a legitimate hardening option (set
`kubernetesTalosAPIAccess.enabled: false`, regenerate, re-apply) but is not
this repo's current default. Weigh that against the extra machine config
change needed before every single future upgrade.
