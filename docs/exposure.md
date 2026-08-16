# Exposure

What is reachable from the internet, and what it takes to put something there.
For why the guardrails are shaped this way, see
[ADR 0013](adr/0013-external-exposure-guardrails.md).

## What is public

Nothing.

The `external` Gateway exists in the `network-public` namespace with one listener
for `insights.fobiat.dev` and zero routes attached to it. The cloudflared tunnel is
Healthy and its ingress list is exactly one entry, `http_status:404`. Every part of
the path is built and connected, and it terminates in a 404 because there is
nothing on the other end.

The complete answer to "what is public?" is:

```sh
ls kubernetes/apps/network-public/routes/app/
```

Keep asking it that way rather than reading a list here. A list in prose drifts the
first time someone forgets to update it; a directory listing cannot.

## How something becomes public

Four objects in three places, and the split is deliberate.

1. **An HTTPRoute in `kubernetes/apps/network-public/routes/app/`.** Routes to the
   `external` Gateway live only here, which is what makes the `ls` above sufficient.
2. **A `ReferenceGrant` in the app's own namespace**, so the route in
   `network-public` can resolve a backend Service across the namespace boundary.
   This is the app's own consent to being published, granted by whoever owns it.
3. **A listener on the `external` Gateway** carrying that exact FQDN, in
   `kubernetes/apps/network-public/gateway/app/gateway.yaml`.
4. **An entry in cloudflared's ingress list**, in
   `kubernetes/apps/network/cloudflared/app/configmap.yaml`, above the closing 404.

Missing any one of them fails safe, and each failure has its own signature:

| Missing | What you see |
| --- | --- |
| Route in the wrong namespace | The write is denied at admission. A hand `kubectl apply` fails outright and Flux's reconcile fails the same way, so no route object ever exists to carry a status |
| Hostname not on a listener | Route status `NoMatchingListenerHostname` |
| ReferenceGrant | A 500 from the Gateway, not a route to somewhere unintended |
| Tunnel ingress entry | The closing 404 |

## What stops it happening by accident

Two ValidatingAdmissionPolicies, in
`kubernetes/apps/network/gateway-guard/app/validatingadmissionpolicy.yaml`:

- **`external-route-namespace`** denies any route with a `parentRef` named
  `external` from any namespace except `network-public`. Admission-time, so it also
  catches a hand `kubectl apply` that Flux would otherwise only revert an hour
  later.
- **`external-gateway-listeners`** denies a listener on the `external` Gateway with
  a wildcard or absent hostname, denies `allowedRoutes.namespaces.from` being
  anything other than `Same`, and denies `spec.allowedListeners` being set at all,
  which would otherwise let a ListenerSet in another namespace attach a listener
  that skips the first two checks.

`scripts/check-vap.sh` proves both, in the deny direction and the allow direction,
through `--dry-run=server`. It persists nothing and is re-runnable, including after
the Proxmox rebuild.

external-dns cannot publish any of this even if all of the above failed. It sources
records from HTTPRoutes only, its provider is AdGuard on the LAN rather than
Cloudflare, and its `domainFilters` suffix is `lab.fobiat.dev`, which does not match
`insights.fobiat.dev`.

The four objects above are not equally guarded, and "missing any one of them fails
safe" should not be read as "all four are policy-enforced". The first three are:
the Gateway lives in its own namespace, both admission policies reject the obvious
mistakes at write time, and a missing `ReferenceGrant` is enforced by the Gateway
API implementation itself. The fourth, cloudflared's ingress list, is not checked
by anything. It sits upstream of all three, so a single entry pointing at
`cilium-gateway-internal.network.svc.cluster.local:443` would publish every LAN
service without touching the `external` Gateway, either policy, `routes/app/` or
any `ReferenceGrant`, and `ls kubernetes/apps/network-public/routes/app/` would
still truthfully say nothing is routed through the external Gateway while missing
that a second publish path exists. The only controls on that file today are review
of the pull request that changes it and the fact that external-dns cannot create a
public DNS record to reach anything routed that way. Worth closing later with a CI
check or an admission policy asserting the ingress list only ever names
`cilium-gateway-external.network-public`. Not urgent while the DNS half is absent.

## What this does not protect

Egress is unrestricted. What the NetworkPolicy baseline bought is lateral movement
into three namespaces, and only that. Nothing here constrains exfiltration.

The Gateway is a bypass for any LAN service that already has a route. A compromised
pod that cannot reach a Service directly can still reach it by its
`lab.fobiat.dev` hostname, arriving back at the backend as `reserved:ingress`.

`system-backup` and `volsync-system` have no NetworkPolicy yet. Both hold restic
credentials, and volsync's controller can read every backed-up PVC.
