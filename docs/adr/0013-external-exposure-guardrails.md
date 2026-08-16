# 0013. External exposure guardrails, and the four decisions behind them

Status: Accepted, 2026-08-16

## Context

Stage 3 built the machinery for publishing a service to the internet without
publishing anything: a default-deny NetworkPolicy baseline in `network`,
`monitoring` and `default`, two ValidatingAdmissionPolicies guarding an
`external` Gateway, that Gateway in its own `network-public` namespace with a
single exact-FQDN listener, and a cloudflared tunnel whose ingress list is one
`http_status:404`. Nothing is reachable from outside the LAN at the end of it.

That shape only holds if four decisions are understood by whoever touches it
next, and each of them is invisible in the manifests. Three are guardrails whose
danger lives in an absence rather than a value, and the fourth is a credential
model that looks like an ordinary API token and is not one.

## Decision

### 1. The admission policies match the literal name `external`

`external-route-namespace` and `external-gateway-listeners` in
`kubernetes/apps/network/gateway-guard/app/validatingadmissionpolicy.yaml` both
key off `object.metadata.name != 'external'` and `p.name == 'external'`. This is
a string comparison, not a selector, so renaming the Gateway silently disarms all
four validations at once. Nothing errors, nothing warns, the guard just stops
matching. That is the cost of a policy that can be read at a glance, and it is
accepted on the condition that it is written down here.

`external-route-namespace` matches five route kinds (`httproutes`, `grpcroutes`,
`tlsroutes`, `tcproutes`, `udproutes`) even though `HTTPRoute` is the only one
with any objects in this repository. All five CRDs are installed, because Gateway
API ships them as one bundle rather than per kind, so listing all five is what
stops a `GRPCRoute` or `TLSRoute` added later from bypassing the guard on a kind
nobody remembered to add a rule for. The `network-gateway-guard` Flux
Kustomization sets `targetNamespace: network` to match this app's home directory,
but `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding` are
cluster-scoped, so Kubernetes ignores it here; it is set for consistency with the
rest of this repository's Kustomizations, not because it does anything.

The `XListenerSet` CRD is installed on this cluster. It lets another namespace
attach listeners to a Gateway, which would route around the exact-FQDN check
entirely, because the check evaluates `object.spec.listeners` on the Gateway and
an attached ListenerSet is not in that list. It is inert unless the Gateway sets
`spec.allowedListeners`, so a third validation on `external-gateway-listeners`
denies that field being set on the `external` Gateway at all.
`kubernetes/apps/network-public/gateway/app/gateway.yaml` also carries a comment
saying so, because a reviewer cannot notice a field that is not there, but the
comment is now a signpost rather than the enforcement.

### 2. The CiliumNetworkPolicy exception to rule 11

Rule 11 (one way to do each thing) argues against this, because
`allow-gateway-ingress` is a second policy dialect sitting next to standard
NetworkPolicy in the same two directories, so it needs a reason on the record.

The reason is that Gateway-proxied traffic reaches backends as
`reserved:ingress`. A Hubble flow capture, not an assumption, showed that every
request through the `internal` Gateway arrives at Grafana, Gatus, Homepage and
the docs proxy carrying that identity by the time it hits the backend. It is not
a pod, not a namespace, and its address (`10.244.0.71/32` at the time of the
capture) comes out of the node's pod CIDR and does not survive a node rebuild. No
`podSelector`, `namespaceSelector` or `ipBlock` can name it. Applying the
flux-system `allow-egress` shape verbatim to `default` and `monitoring` breaks
LAN access to the entire visible service inventory, which is how the finding was
made.

Two alternatives were rejected. Writing every policy as a CiliumNetworkPolicy
would be consistent, and would lock three namespaces to Cilium for no gain.
Pinning an `ipBlock` to the current `reserved:ingress` address would keep one
dialect, and would break silently after re-IPAM while reading as a magic number
to the next person.

### 3. The `network-public` empty-routes convention

`ls kubernetes/apps/network-public/routes/app/` is the complete answer to "what
is public?". That property is worth more than the directory being tidy, so the
directory ships in Stage 3 rather than appearing alongside the first route in
Stage 4. A convention introduced at the same time as its first exception is not a
convention.

Task 9 Step 4 offered a fallback if the tooling rejected an empty kustomization.
It was not needed. `routes/ks.yaml` shipped, and
`kubernetes/apps/network-public/routes/app/kustomization.yaml` shipped with
`resources: []`, genuinely empty, with no placeholder file. Flux, kustomize and
kubeconform all accept it as-is. The Flux Kustomization `network-public-routes`
reconciles to zero objects and reports Ready.

### 4. cloudflared's credential model

The tunnel-scoped Cloudflare API token is created by hand, used once from the
workstation to `POST /accounts/{id}/cfd_tunnel` with `config_src: local`, and
never enters the cluster. What the pod holds is the tunnel credentials JSON the
API returned, SOPS-encrypted in `cloudflared-credentials.sops.yaml`.

Those two things are not the same kind of secret, and treating them as one is the
mistake this section exists to prevent. The credentials JSON is an impersonation
credential for the published hostnames, not a route inbound: someone holding it
can stand up a connector claiming to serve `insights.fobiat.dev`, and cannot
reach anything in the cluster with it. It also cannot be rotated. Revoking access
means deleting the tunnel (`DELETE /accounts/{id}/cfd_tunnel/{tunnel_id}`, with
the same tunnel-scoped token), not rotating a value in Git.

Keeping this token separate from the DNS-01 solver token is what makes either
revocable independently. Cloudflare cannot scope a DNS-edit token below zone
level, so the solver token can rewrite the apex; the split is the mitigation for
a limitation of the provider rather than a preference.

## Consequences

The three covered namespaces accept connections only from pods in their own
namespace, plus the Gateway proxy where routes exist. That closes three risks this
design set out to close: Prometheus, Loki and Grafana in `monitoring` are no
longer reachable from a compromised pod elsewhere.

"Monitoring is isolated" is still the wrong summary on its own. A compromised pod
in `default` cannot reach `kube-prometheus-stack-grafana:3000` directly, but it
can reach `https://grafana.lab.fobiat.dev` through the Gateway, arriving back as
`reserved:ingress`, which `allow-gateway-ingress` permits. The Gateway is a
bypass for any service that has a route. That is acceptable here, because those
same services are reachable from any device on the LAN anyway, so the policy
takes nothing away from an attacker who already has a pod. It would not be
acceptable in a design where the Gateway fronted something the LAN could not
reach.

What this stage does not close, stated so it is not mistaken for covered:

Egress is unrestricted everywhere in scope (`egress: [{}]`, matching the existing
flux-system precedent). Nothing here constrains exfiltration. What was bought is
lateral movement into three namespaces, and only that.

The API server stays reachable from every pod, controlled today only by RBAC.
Closing it needs egress rules, and the legitimate users (Prometheus, Alloy,
external-dns, Homepage) are mixed in with everything else.

`system-backup` and `volsync-system` stay unprotected. Both hold restic
credentials, and volsync's controller can read every backed-up PVC, which makes
them the highest-value pair left and the next two to cover. They were left out
for scope discipline, not because the risk was assessed as low.

Two verification cases were added to the spec's plan while building this, and
they are recorded here so they survive as requirements rather than folklore.
`check-vap.sh` case 3 applies the existing `internal` Gateway and expects it to
be accepted; without it the policy could reject every Gateway on the cluster and
the suite would still pass, since a non-matching name is the only path that
proves the policy doesn't error. Case 6, added in the review fix round, is the
stronger positive control: it submits the real shipped
`kubernetes/apps/network-public/gateway/app/gateway.yaml` and is the only case
that evaluates `external-gateway-listeners` against the actual `external`
Gateway in the allow direction. Case 5 applies a wildcard listener on a Gateway
named `external` and expects a denial naming the exact-FQDN rule; it is the
negative control for the same policy. The script runs everything through
`--dry-run=server` and persists nothing.

One operational note from after the merge: cloudflared connects over HTTP/2 rather
than its default QUIC transport, pinned as `protocol: http2` in
`kubernetes/apps/network/cloudflared/app/configmap.yaml`, after the default
transport produced a crash loop against this network. Its liveness probe was
relaxed in the same change (`initialDelaySeconds: 30`, `periodSeconds: 15`,
`failureThreshold: 6`), giving roughly 120 seconds of startup runway; those
numbers were sized generously rather than measured, so a later tidy-back to
defaults would be undoing load-bearing values. The readiness probe added
afterwards is what actually makes `maxUnavailable: 0` mean what the rollout
strategy claims: without it a new pod counts as Ready before it has registered a
tunnel connection, so a ConfigMap-triggered rollout could retire connected pods
for pods that never connect.

## Alternatives

**Bind the admission policies with a label selector instead of the name.** A
`matchConditions` on a label such as `exposure: external` survives a rename.
Rejected because a label can be removed by the same edit that would have renamed
the Gateway, so it moves the failure rather than removing it, and it costs the
property that the policy can be read and understood without cross-referencing a
second object.

**Skip `network-public` and attach the external listener to the existing
`internal` Gateway.** One Gateway, one certificate, less YAML. Rejected because
then "what is public?" has no cheap answer: it becomes a question about which
listener a route attached to and which hostname it claimed, evaluated per route,
forever. The namespace split is what makes `ls` sufficient.

**Use a Cloudflare tunnel token (`TUNNEL_TOKEN`) instead of the credentials
JSON.** It is the shape most guides use, and it is a single environment variable.
Rejected because `config_src: local` is what keeps the ingress list in Git and
under review; the token flow pairs naturally with dashboard-managed configuration,
where the routes are edited in a web UI and this repository stops being the
record of what is exposed.
