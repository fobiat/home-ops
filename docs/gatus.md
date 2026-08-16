# Gatus

Gatus is the uptime and status page, at `https://status.lab.fobiat.dev`. It runs
[TwiN/gatus](https://github.com/TwiN/gatus) with a `kiwigrid/k8s-sidecar` container
watching for labelled ConfigMaps, so an app declares its own health check next to its
own manifest rather than in one central list (AGENTS.md rule 14).

## How it works

The Gatus pod runs two containers sharing a volume:

- `gatus` itself, with `GATUS_CONFIG_PATH` set to `/gatus-config`, a directory. Gatus
  merges every `*.yaml`/`*.yml` file under a config directory and its subdirectories,
  rather than reading a single file, and periodically checks file modification times to
  pick up changes without a restart.
- `k8s-sidecar`, watching every namespace for ConfigMaps labelled `gatus.io/enabled:
  "true"`. Each matching ConfigMap's data keys are written as files into
  `/gatus-config/endpoints`, which sits inside the directory Gatus is watching.

`/gatus-config/base` carries the base config (SQLite storage path, UI title) as its own
ConfigMap, `gatus-base-config`, so it merges in alongside whatever the sidecar has
collected. Endpoint lists merge by concatenation across files: each app's ConfigMap
only needs its own `endpoints:` entry, not a merge-safe fragment.

## Adding a check

Add a ConfigMap next to the manifest of the app being checked, labelled
`gatus.io/enabled: "true"`, with one `data` key holding a `config.yaml`-style fragment:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gatus-check-my-app
  labels:
    gatus.io/enabled: "true"
data:
  my-app.yaml: |
    endpoints:
      - name: my-app
        group: apps
        url: "https://my-app.lab.fobiat.dev"
        interval: 1m
        conditions:
          - "[STATUS] == 200"
```

Add the file to that app's `kustomization.yaml` and commit. No change to the Gatus
HelmRelease itself is needed. `kubernetes/apps/default/homepage/app/gatus-check.yaml`
and `kubernetes/apps/monitoring/kube-prometheus-stack/app/gatus-check.yaml` are worked
examples.

The Kubernetes API check is the one exception, and it sits in the base config in
`kubernetes/apps/default/gatus/app/config.yaml` rather than in a collected ConfigMap.
Two reasons: no app directory owns the API server, and Gatus panics rather than waits
if it ever loads a config with no endpoints at all, which is exactly what the sidecar's
directory looks like for the first few seconds of every start. Keeping one endpoint in
the base config makes it valid on its own. It also shows the TCP check form
(`tcp://host:port`, condition `[CONNECTED] == true`) for targets that are not HTTP.

## DNS

`*.lab.fobiat.dev` is written by `external-dns` into AdGuard Home on the LAN, not into
in-cluster CoreDNS. CoreDNS forwards anything it doesn't own to the host's own resolver
(Talos's `forwardKubeDNSToHost`, on by default), and the node gets its resolvers over
DHCP. Whether the Grafana and Homepage checks above actually resolve from inside a pod
therefore depends on what the router hands out as DNS, which is expected to be AdGuard
but has not been confirmed by an in-cluster lookup in this change. If a check sits
permanently red with a DNS error rather than a timeout or a real failure, this is the
first thing to check: `kubectl -n default exec deploy/gatus -c gatus -- nslookup
grafana.lab.fobiat.dev`.

## Backups

The `gatus` PVC (1Gi, holds the SQLite uptime history) is backed up daily at 04:00 UTC
by a VolSync `ReplicationSource` to an interim restic repository on its own PVC
(`volsync-repo`, `default` namespace). `copyMethod: Direct`, since `local-path` isn't a
CSI driver and has no snapshot or clone. `moverSecurityContext` is `65534/65534/65534`,
read off the running pod's own `securityContext`, not chart defaults: Talos assigns no
UID ranges, so an unadorned mover runs as UID 0 without `DAC_OVERRIDE` and can't read
Gatus's 65534-owned files.

VolSync fires a first sync immediately on `ReplicationSource` creation regardless of its
cron schedule, then follows the schedule after. Confirmed live 2026-08-16:
`status.latestMoverStatus.result: Successful`, restic log `created restic repository
... at /mnt/repo/gatus`, `processed 3 files, 4.085 MiB`, `snapshot a36e76f6 saved`.

### Restoring

`gatus-restore` is a sibling app carrying a `ReplicationDestination` pointed at the same
PVC, shipped with its Flux Kustomization `suspend: true` so the object never exists in
the cluster at rest. A `ReplicationDestination` with `copyMethod: Direct` and a
`destinationPVC` pointing at a live PVC fires the moment it's created, because
`status.lastManualSync` starts empty. To restore: set `suspend: false` on the
`gatus-restore` Kustomization and bump `spec.trigger.manual` to a new value, wait for
`status.lastManualSync` to match, then reverse both. See `docs/runbooks/restore.md`
(currently `UNTESTED`; the drill that proves this path is still open).

## Not yet configured

Alerting from Gatus to Discord is not set up. There is no `home-ops` Discord webhook
yet (see `kube-prometheus-stack`'s Alertmanager for the same gap). Gatus's `alerting:`
block is left out of the base config entirely rather than shipped half-configured.
