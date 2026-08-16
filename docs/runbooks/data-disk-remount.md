# Remounting the data volume

When `talosctl get volumestatus u-data` is not `ready`, or a `df -h /var/mnt/data`
run from inside a pod shows a device other than `sdb`, the data disk is not
mounted where it should be and every PVC is quietly living on the ephemeral
partition a Talos reset wipes. Most likely on new hardware, since the exact
disk size, the raw source of this bug, changes with the hardware.

Walked once, on 2026-08-16, against `talos-1`. This is that run, not a
description of what should happen. See ADR 0012 for the full reasoning.

## The arithmetic

`minSize` gates *disk selection*, it does not truncate the request. A disk
that is smaller than `minSize` is rejected outright and provisioning stops
silently, with `/var/mnt/data` left as an ordinary directory on the ephemeral
partition. GPT metadata sits at both ends of a disk and Talos aligns
partitions to 1 MiB, so a few MiB are lost before any partition is cut. A
`minSize` equal to the disk's raw size therefore never fits.

On `talos-1`, `sdb` reported `size: 214748364800` bytes, exactly 200.0 GiB.
`minSize: 200GiB` could never be satisfied. The fix leaves margin:
`minSize: 190GiB`, no `maxSize`, so the volume still claims the whole disk.
Redo this arithmetic against the real disk size on any new hardware; do not
assume 190GiB is the right number elsewhere.

## The ordered procedure

**This is a scheduled outage, not a routine PR.** Expect the cluster
unavailable for roughly 10 to 15 minutes while PVCs are deleted and the node
reboots.

1. Merge the `minSize` change to `main` first (AGENTS.md rule 5: committed
   before applied). Pull it and regenerate:

   ```bash
   git checkout main && git pull
   task talos:generate
   ```

2. Suspend the Kustomizations that own the affected PVCs:

   ```bash
   flux suspend kustomization kube-prometheus-stack
   flux suspend kustomization loki
   flux suspend kustomization gatus
   flux suspend kustomization cluster-backup
   ```

3. Scale the Prometheus operator to zero **before** the StatefulSets it
   reconciles, or it puts the replica count straight back:

   ```bash
   kubectl scale deploy/kube-prometheus-stack-operator -n monitoring --replicas=0
   kubectl rollout status deploy/kube-prometheus-stack-operator -n monitoring --timeout=60s
   ```

4. Scale every PVC-holding workload to zero:

   ```bash
   kubectl scale statefulset/prometheus-kube-prometheus-stack-prometheus -n monitoring --replicas=0
   kubectl scale statefulset/kube-prometheus-stack-grafana -n monitoring --replicas=0
   kubectl scale statefulset/loki -n monitoring --replicas=0
   kubectl scale deploy/gatus -n default --replicas=0
   ```

   Confirm nothing still holds a PVC before continuing
   (`kubectl get pods -n monitoring`, `-n default`, `-n system-backup`). A PVC
   with a pod still attached hangs on deletion behind its
   `kubernetes.io/pvc-protection` finalizer.

5. **Delete the PVCs before applying the new config.** local-path's reclaim
   policy is `Delete`, so its helper pod removes each directory under
   `/var/mnt/data/local-path-provisioner/` while that path is still the old
   directory. Doing this after the mount exists strands the old data on the
   ephemeral partition permanently, because Talos ships no shell to go and
   recover it.

   ```bash
   kubectl delete pvc -n default gatus
   kubectl delete pvc -n monitoring storage-loki-0
   kubectl delete pvc -n monitoring storage-kube-prometheus-stack-grafana-0
   kubectl delete pvc -n monitoring prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
   kubectl delete pvc -n system-backup cluster-backup-data
   ```

   One trap found live: if a StatefulSet's `persistentVolumeClaimRetentionPolicy`
   has `whenScaled: Delete` (Loki's chart does; Prometheus's and Grafana's do
   not), scaling it to zero in step 4 already deleted its PVC. The explicit
   `kubectl delete` in that case returns `NotFound`, which is fine, the
   outcome is identical: check `kubectl get pvc -A` and only delete what is
   still there.

6. Apply the config to the live node. Use `talosctl apply-config` directly,
   not `task talos:apply`, which passes `--insecure` and only works against a
   node still in maintenance mode:

   ```bash
   talosctl apply-config --nodes 192.168.0.226 --file talos/clusterconfig/home-ops-talos-1.yaml
   ```

7. **Checkpoint before rebooting.** This is the go/no-go gate: if the
   arithmetic were still wrong, this is where it shows, and rebooting would
   not help.

   ```bash
   talosctl -n 192.168.0.226 get volumestatus u-data
   ```

   If `phase` is still `failed`, stop and roll back: revert the `minSize`
   change on `main`, regenerate, re-apply, unsuspend the Kustomizations, and
   let Flux recreate empty PVCs. The data loss has already happened either
   way; rolling back returns the cluster to its previous working state.

8. **Reboot, and do not skip this.** `machine.kubelet.extraMounts`
   bind-mounts `/var/mnt/data` into the kubelet's own mount namespace, and
   that bind was established while the path was an ordinary directory.
   `rshared` propagates mounts made *under* a source path, not one made *at*
   it, so without a restart the kubelet keeps resolving the old directory on
   the ephemeral partition while `talosctl` correctly reports the new disk.
   That is the worst available outcome: it looks fixed and is not.

   ```bash
   talosctl -n 192.168.0.226 reboot
   ```

   Two to five minutes to `Ready`.

9. Resume the Kustomizations:

   ```bash
   flux resume kustomization kube-prometheus-stack
   flux resume kustomization loki
   flux resume kustomization gatus
   flux resume kustomization cluster-backup
   ```

10. **Scale back up by hand.** This repo's HelmReleases do not have Helm
    drift detection enabled, so resuming the Kustomization and even forcing a
    Helm reconcile (`flux reconcile hr <name> -n <ns>`) does not, on its own,
    correct a manual `kubectl scale` to zero: the chart version and values
    have not changed, so the controller sees nothing to reapply. Scale each
    workload back to its normal replica count directly:

    ```bash
    kubectl scale deploy/kube-prometheus-stack-operator -n monitoring --replicas=1
    kubectl scale statefulset/prometheus-kube-prometheus-stack-prometheus -n monitoring --replicas=1
    kubectl scale statefulset/kube-prometheus-stack-grafana -n monitoring --replicas=1
    kubectl scale statefulset/loki -n monitoring --replicas=1
    kubectl scale deploy/gatus -n default --replicas=1
    ```

    If a Deployment's PVC was deleted (rather than auto-deleted by a
    `whenScaled: Delete` StatefulSet), Helm's own reconcile may not recreate
    it either, for the same drift-detection reason. `gatus` hit this live:
    the pod stayed `Pending` with `persistentvolumeclaim "gatus" not found`
    until a forced install/upgrade was run:

    ```bash
    flux reconcile hr gatus -n default --force
    ```

    `--force` triggers a real one-off Helm install/upgrade rather than a
    no-op status check, which is what actually recreates a chart-managed
    resource that was deleted out of band. Check `kubectl get pvc -n
    <namespace>` after each scale-up; if a PVC a Deployment depends on is
    still missing, this is the fix.

11. `system-backup` has no long-running pod, only CronJobs, so its PVC stays
    `Pending` (`WaitForFirstConsumer`) until a Job actually schedules. Trigger
    one manually to bind it and clear the Kustomization's health check rather
    than waiting for the next scheduled run:

    ```bash
    kubectl create job --from=cronjob/machineconfig-backup machineconfig-backup-verify -n system-backup
    kubectl wait --for=condition=Complete job/machineconfig-backup-verify -n system-backup --timeout=90s
    kubectl delete job machineconfig-backup-verify -n system-backup
    flux reconcile kustomization cluster-backup
    ```

## The acceptance test

Checking `talosctl get volumestatus` or `talosctl get mountstatus` alone is
not sufficient: the failure mode in step 8 above produces correct `talosctl`
output and a wrong kubelet view at the same time. The only proof that counts
runs from inside a pod, because that is the kubelet's view, not Talos's:

```bash
kubectl run diskcheck --rm -i --restart=Never \
  --image=docker.io/library/busybox:1.37.0-musl \
  --overrides='{"spec":{"tolerations":[{"operator":"Exists"}],"containers":[{"name":"c","image":"docker.io/library/busybox:1.37.0-musl","command":["df","-h","/data"],"volumeMounts":[{"name":"d","mountPath":"/data"}],"securityContext":{"runAsUser":0}}],"volumes":[{"name":"d","hostPath":{"path":"/var/mnt/data"}}]}}'
```

`default`'s pod security policy is `baseline`, which blocks a raw `hostPath`
pod. Run it in a namespace already labelled `pod-security.kubernetes.io/enforce:
privileged` instead, `local-path-storage` and `monitoring` both qualify on
this cluster: swap `kubectl run` for `kubectl apply -f` on a Pod manifest
naming that namespace, since `kubectl run --overrides` has no `--namespace`
equivalent for a one-shot pod on a restricted default namespace.

**Before**, on `talos-1`, the disk unmounted since the cluster was built:

```
Filesystem                Size      Used Available Use% Mounted on
/dev/sda4                97.8G      9.4G     88.4G  10% /data
```

**After**, once the reboot took effect:

```
Filesystem                Size      Used Available Use% Mounted on
/dev/sdb1               199.9G      3.9G    196.0G   2% /data
```

A freshly formatted XFS filesystem is not `0` used; the internal log and
reserved blocks account for a few GiB on a volume this size. Confirm the
directory itself is empty (`ls -la /data`) rather than expecting `df` to read
zero.

If `df` still reports the ephemeral device after the reboot, the reboot did
not take effect. Reboot again and re-run the check; do not proceed until the
device changes.

## Rollback

Only relevant between step 7 (checkpoint) and step 8 (reboot) above. If
`u-data` is still `failed` after applying the config: revert the `minSize`
change on `main`, regenerate, re-apply the reverted config, resume the
suspended Kustomizations, and let Flux recreate empty PVCs on the ephemeral
partition. The PVC data from before this run is already gone regardless of
which path is taken; rollback returns the cluster to a working state, it does
not undo the data loss.

## What this is not

This is not a live migration. Existing PVC data is deliberately discarded, not
carried across. If the data is worth keeping, that is a different, more
careful procedure and this runbook is the wrong starting point.
