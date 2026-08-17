# Hubble

Hubble records recent network flows on each Cilium agent. Hubble Relay joins
those node-local buffers into one read API. This cluster exposes Relay only as
an in-cluster `ClusterIP` Service. It has no UI and no Gateway or Tunnel route.

Use it to collect evidence before tightening egress policies. A short trace is
not an allow-list: leave it running long enough to include scheduled jobs,
normal reconciliation and cloudflared reconnects.

## Access

The CLI is pinned in `.mise.toml`. Start a local port-forward from the main
checkout, then query it from a second terminal:

```sh
mise exec -- kubectl -n kube-system port-forward service/hubble-relay 4245:80
mise exec -- hubble status --server 127.0.0.1:4245
```

The port-forward binds to the workstation only. Do not expose Relay with a
Gateway, LoadBalancer or Tunnel.

## Capturing egress evidence

Start with the namespace that will be restricted, and save observations outside
the repository if they contain destination addresses:

```sh
mise exec -- hubble observe --server 127.0.0.1:4245 \
  --namespace network --verdict FORWARDED --follow
```

Classify each destination by purpose before creating a policy. Expected traffic
includes the Kubernetes API, the AdGuard Home API and cloudflared's Cloudflare
edge connections. Do not add a destination merely because it appeared once.
