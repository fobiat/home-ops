# Grafana dashboards

Dashboards are ConfigMaps, not clicked together in the UI. Grafana's sidecar (part of
the `kube-prometheus-stack` HelmRelease, `grafana.sidecar.dashboards`) watches every
namespace for ConfigMaps labelled `grafana_dashboard: "1"` and loads whatever JSON it
finds. `kubernetes/apps/monitoring/grafana-dashboards/app/` turns each dashboard's raw
JSON into one ConfigMap with kustomize's `configMapGenerator`.

## Adding a dashboard

1. Fetch the dashboard JSON from its real source, grafana.com's `/api/dashboards/<id>/revisions/<rev>/download`,
   or the raw file from the project that publishes it. Do not hand-write dashboard JSON.
2. Drop the file in `kubernetes/apps/monitoring/grafana-dashboards/app/` next to the others.
3. If it uses a `DS_PROMETHEUS`-style input template variable for its datasource
   (most grafana.com exports do), replace it. Sidecar-provisioned dashboards are not
   imported through the UI, so the `__inputs` substitution never runs and every panel
   renders empty. Point panels, targets and annotations at
   `{"type": "prometheus", "uid": "prometheus"}` directly, that is the datasource
   `kube-prometheus-stack` provisions (`grafana.sidecar.datasources`, name `Prometheus`,
   uid `prometheus`), and drop the now-unused template variable. See
   `kubernetes/apps/monitoring/grafana-dashboards/app/*.json` for worked examples, or
   reuse the conversion in the PR that added this doc.
4. Add a `configMapGenerator` entry for it in `app/kustomization.yaml`. Every entry
   inherits the `grafana_dashboard` label and `disableNameSuffixHash: true` from the
   file's `generatorOptions`, so nothing else needs setting per dashboard.
5. Run `mise exec -- task lint`.

A ConfigMap has a 1MiB size ceiling. Node Exporter Full is the dashboard most likely to
brush against it; if a fetched dashboard is close, say so in the PR rather than trimming
panels silently.

## Tracking upstream versions

grafana.com-sourced dashboards carry a `<name>.grafanadashboard.yaml` file next to the
JSON, recording the exact `id`/`revision` download URL. Renovate's `grafanaDashboards`
preset (`.renovaterc.json5`) watches that URL and opens a PR when a new revision exists;
the PR only bumps the number; re-run the download and overwrite the JSON by hand.

Dashboards sourced from a project's own git repository (Cilium, Hubble, Flux) are pinned
to a tag or commit SHA instead. Renovate does not track those; re-fetching at a newer
ref is a manual, occasional task, not something to automate for a homelab with one
consumer of the dashboard.

## Current set

| Dashboard | Source | Pinned at |
|---|---|---|
| Node Exporter Full | grafana.com dashboard 1860 | revision 45 |
| cert-manager | grafana.com dashboard 20340 | revision 1 |
| Cilium Agent | `cilium/cilium` `install/kubernetes/cilium/files/cilium-agent/dashboards/cilium-dashboard.json` | tag `v1.20.0` |
| Cilium Operator | `cilium/cilium` `install/kubernetes/cilium/files/cilium-operator/dashboards/cilium-operator-dashboard.json` | tag `v1.20.0` |
| Hubble | `cilium/cilium` `install/kubernetes/cilium/files/hubble/dashboards/hubble-dashboard.json` | tag `v1.20.0` |
| Flux Cluster Stats | `fluxcd/flux2-monitoring-example` `monitoring/configs/dashboards/cluster.json` | commit `7ab65dc` |
| Flux Control Plane | `fluxcd/flux2-monitoring-example` `monitoring/configs/dashboards/control-plane.json` | commit `7ab65dc` |

Flux's own repository dropped its bundled dashboards in v2.2 (December 2023) in favour of
`fluxcd/flux2-monitoring-example`, which is not tagged, hence the commit pin rather than a
version. Cilium ships three more Hubble dashboards in the same directory (DNS, L7 HTTP,
per-namespace network overview); only the main one is included here, add the others the
same way if they turn out to be useful.
