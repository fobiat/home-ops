# Homepage

The dashboard at `https://home.lab.fobiat.dev`, Tailscale or LAN only. It is the front
door: whatever is worth reaching from here should show up on it automatically.

## At a glance

The header shows Cambridge weather in Celsius and the UK date and time. Weather
uses [Open-Meteo](https://gethomepage.dev/widgets/info/openmeteo/) without an API
key, cached for 15 minutes. The existing resources widget is labelled **Homepage
process** because it reports the dashboard container, not the whole node.

The Overview row uses the cluster's existing Prometheus and Gatus services:

| Card | Shows | Opens |
|---|---|---|
| Node headroom | Node CPU and memory utilisation | Node detail in Grafana |
| Needs attention | Firing alerts, pending pods, restarts in the last hour | Grafana alert list |
| Service availability | Passing and failing checks, uptime | Gatus |

[Prometheus Metric](https://gethomepage.dev/widgets/services/prometheusmetric/)
queries refresh every minute, matching the scrape interval. The alert count excludes
Watchdog and InfoInhibitor. Restarts are an estimate over the last hour, so values
are rounded for display. Query failures remain widget errors; they should not be
interpreted as a healthy cluster. No Grafana token or extra Kubernetes permissions
are needed. Grafana remains the place for history, disk and network detail.

Monitoring bookmarks open the provisioned node, Flux and certificate dashboards.
Daily bookmarks open the VPS dashboard for news and usage, and Cairn's
`/at?q=Cambridge` answer page for local warnings and source freshness. The city is
the shared default. A personal postcode belongs in private runtime configuration,
never in this public manifest or its documentation.

## How services show up

Homepage discovers services from the Kubernetes API rather than a hand-maintained list
(`config.kubernetes: {mode: cluster, gateway: true}` in the HelmRelease, backed by
`enableRbac: true` and its own ServiceAccount). An app appears once its HTTPRoute
carries the right annotations:

```yaml
metadata:
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: Grafana
    gethomepage.dev/description: Dashboards and metrics explorer
    gethomepage.dev/group: Cluster
    gethomepage.dev/icon: grafana.png
```

Add those four keys to an app's own `httproute.yaml` and it shows up on the next
Homepage reconcile, no edit to the Homepage HelmRelease itself. See any of Grafana's,
Gatus's or Headlamp's `httproute.yaml` for a working example.

## The gotcha that cost a follow-up PR

`config.services` must be set explicitly. Use `[]` when there are no static cards,
or a real list such as the Overview cards above. The chart ships a sample
`services.yaml` and falls back to it when the key is absent, rendering three
"My First/Second/Third Service" demo entries alongside the discovered services.
Neither `flux-local diff` nor `task lint` catches this, since the manifest is valid
either way. Check the rendered ConfigMap and the running pod's `/api/services`
response for sample entries. Explicit bookmarks follow the same rule.

## Verifying after a change

Before landing, run `task lint`, attach `flux-local diff`, and rehearse against the
throwaway Talos cluster. Check that the rendered ConfigMap contains the Overview
cards, Cambridge weather and the bookmarks, with no sample services. On the live
private dashboard, confirm the metrics are populated and the links work. A Helm
render alone cannot prove service DNS, Prometheus data or upstream weather access.

A merged PR touching an HTTPRoute's annotations or the Homepage HelmRelease does not
mean the dashboard has actually updated: Flux's per-app Kustomization reconciles on its
own interval, independent of the git source being current. Force it and check the
result, don't assume from the diff:

```sh
flux reconcile kustomization homepage --with-source
kubectl -n default exec deploy/homepage -- wget -qO- http://127.0.0.1:3000/api/services
```
