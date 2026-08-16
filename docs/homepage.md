# Homepage

The dashboard at `https://home.lab.fobiat.dev`, Tailscale or LAN only. It is the front
door: whatever is worth reaching from here should show up on it automatically.

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

`config.services` must be `[]`, not absent. The chart ships its own sample
`services.yaml` and falls back to it whenever the key is missing entirely, so leaving it
out (rather than emptying it) renders three "My First/Second/Third Service" demo entries
alongside the real ones. Neither `flux-local diff` nor `task lint` catches this, since
the manifest is valid either way; it only shows up by checking the running pod
(`kubectl -n default exec deploy/homepage -- wget -qO- http://127.0.0.1:3000/api/services`).
`bookmarks: []` in the same config was already written the empty-list way, which is
exactly why bookmarks never showed samples and services briefly did.

## Verifying after a change

A merged PR touching an HTTPRoute's annotations or the Homepage HelmRelease does not
mean the dashboard has actually updated: Flux's per-app Kustomization reconciles on its
own interval, independent of the git source being current. Force it and check the
result, don't assume from the diff:

```sh
flux reconcile kustomization homepage --with-source
kubectl -n default exec deploy/homepage -- wget -qO- http://127.0.0.1:3000/api/services
```
