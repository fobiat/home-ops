# Stage 3: public exposure infrastructure

Design spec, 2026-08-16. Phase two, stage 3 of six.

## What this stage is, and what it is not

Stage 3 builds the machinery that will one day let a service be published, and
publishes nothing. Four pieces of infrastructure land: default-deny
NetworkPolicy over three namespaces, a `ValidatingAdmissionPolicy` pair that
constrains how the public Gateway may ever be used, the `external` Gateway
itself in its own namespace, and a cloudflared tunnel with an empty ingress
list. No app gains a public route. The first real publish is Stage 4 (Umami on
`insights.fobiat.dev`), and it is deliberately a separate stage so that every
guardrail is already in place, and already proven, before anything sits behind
it.

The stage is done when the tunnel is Healthy in the Cloudflare dashboard with
zero hostnames configured, no public DNS record resolves to anything in the
cluster, `ls kubernetes/apps/network-public/routes/app/` lists no routes, and
every LAN service still loads exactly as before. Three of those four are
statements about absence, which is the point: the observable result of this
stage is that nothing observable changed from outside the LAN.

Five stacked PRs, each branched from the previous one, merged bottom-up:

| # | Branch | Contents |
|---|--------|----------|
| 1 | `netpol/stage3-baseline` | Default-deny in `network`, `monitoring`, `default` |
| 2 | `gateway/external-vap` | Two `ValidatingAdmissionPolicy` objects, their bindings, `scripts/check-vap.sh` |
| 3 | `gateway/external` | `network-public` namespace, `external` Gateway, Certificate, third case in `check-vap.sh` |
| 4 | `cloudflared/deploy` | cloudflared Deployment, ConfigMap, tunnel credentials, port 2000 added to PR1's scrape rule |
| 5 | `docs` | ADR 0013 and `docs/exposure.md` |

The ordering is not arbitrary. NetworkPolicy comes first because the first
internet-facing pod is also the first pod that could pivot to the API server,
Grafana, Prometheus and Loki, and a prerequisite that lands after the thing it
protects is not a prerequisite. The admission policy (PR2) lands before the
Gateway it guards (PR3) so that the guard is never briefly absent, and so it can
be proven against zero real objects. cloudflared comes last because it is the
only piece with an out-of-cluster side effect, and by then it inherits PR1's
default-deny in `network`.

## Four verified findings that shape the design

Each of these was checked against the running cluster rather than assumed, and
each one changed the design.

**A. Gateway-proxied traffic reaches backends as `reserved:ingress`, and a
standard NetworkPolicy cannot express that.** A Hubble flow capture showed
Cilium's `reserved:ingress` identity (currently `10.244.0.71/32`, allocated from
the node's pod CIDR and not stable across a node rebuild) is what every request
through the `internal` Gateway carries by the time it reaches Grafana, Gatus,
Homepage or docs-proxy. It is not a pod, not a namespace, and has no stable
address that a `podSelector`, `namespaceSelector` or `ipBlock` can name safely.
Applying the flux-system `allow-egress` shape verbatim to `default` and
`monitoring` breaks LAN access to Grafana, Gatus, Homepage and the docs proxy,
which is the whole visible service inventory. PR1 must carry one Cilium-specific
object per routed namespace to allow this identity, or it must not be merged.

**B. Envoy runs as its own DaemonSet, not embedded in the agent.** The
`cilium-envoy` DaemonSet runs in `kube-system` with `hostNetwork: true`. There is
no proxy pod in `network`, so a namespaced NetworkPolicy there governs
`external-dns` and nothing else. `hostNetwork: true` is also why the proxy's
traffic arrives with a reserved identity rather than a pod identity.

**C. external-dns does not talk to Cloudflare.** It runs the AdGuard webhook
provider against a Pi on the LAN, with `domainFilters: [lab.fobiat.dev]` and
`sources: [gateway-httproute]`. Two consequences. The egress that must survive
PR1 is to the AdGuard API on the LAN and to the Kubernetes API, not to
Cloudflare. And the external Gateway added in PR3 cannot leak into any DNS zone,
because external-dns sources records from HTTPRoutes, the external Gateway has
zero routes, and `domainFilters` is a suffix match against `lab.fobiat.dev`,
which `insights.fobiat.dev` does not match. This is a
second independent reason nothing becomes public in Stage 3, and it is worth
stating as a safety property rather than leaving it as a happy accident.

**D. The API server calls a webhook inside `monitoring`.** The
`kube-prometheus-stack-admission` webhook targets
`monitoring/kube-prometheus-stack-operator:443`. On this single node the API
server is host-network on the same machine, so it arrives as `reserved:host`,
covered by Cilium's default `allow-localhost: auto`. It works today and would
break on a multi-node cluster, where the API server presents as
`reserved:remote-node`. This is recorded as a migration trap because the failure
mode, a PrometheusRule edit silently rejected, is invisible until it happens.

## PR1: NetworkPolicy baseline

Default-deny here has a specific meaning: a pod in `network`, `monitoring` or
`default` accepts connections only from pods in its own namespace, plus the
Gateway proxy where routes exist. Egress stays fully open, matching the existing
flux-system precedent (`egress: [{}]`).

This closes three of PHASE-TWO's four named pivot risks. Prometheus, Loki and
Grafana in `monitoring` become unreachable from outside that namespace. It does
not close the API-server pivot, which needs egress rules, and the legitimate
API-server users (Prometheus, Alloy, external-dns, Homepage) are mixed in with
everything else. That stays a named gap, controlled today only by RBAC.

One caveat has to be written down or the summary is wrong. A compromised pod in
`default` cannot reach `kube-prometheus-stack-grafana:3000` directly, but it can
reach `https://grafana.lab.fobiat.dev` through the Gateway, arriving back as
`reserved:ingress`, which the allow rule permits. The Gateway is a bypass for
any service that has a route. That is acceptable, since those services are
LAN-reachable from any device on the network anyway, but "monitoring is
isolated" is the wrong summary without this sentence attached.

### Why egress stays open

Deliberate, for three reasons. A wrong egress rule fails intermittently and
late, at the next cert renewal or the next tunnel reconnect, while ingress
mistakes break immediately and visibly. The destinations that would need
enumerating are awkward: the LAN AdGuard API, Cloudflare's changing anycast IPs
for cloudflared, the Kubernetes API. And it matches the existing three-policy
precedent rather than introducing a second style. The follow-up belongs on
`tasks.md` rather than in this stage: once cloudflared is running,
`hubble observe --namespace network --verdict FORWARDED` gives the real
destination set from observation instead of guesswork.

### The Cilium exception needs an ADR line

Standard NetworkPolicy cannot name `reserved:ingress`, so one
`CiliumNetworkPolicy` per routed namespace (`monitoring` and `default`) is
unavoidable. That is a second way to do a thing, which rule 11 flags as needing
a documented reason, so it goes in the ADR. Two alternatives were considered and
rejected: writing every policy as a CiliumNetworkPolicy, which locks three
namespaces to Cilium for no gain, and pinning an `ipBlock` to the current
`reserved:ingress` address, which breaks silently after re-IPAM and reads as a
magic number to the next person.

### Layout

Three sibling Flux apps, so each namespace's policies reconcile independently:

```
kubernetes/apps/network/netpol/{ks.yaml,app/{kustomization.yaml,networkpolicy.yaml}}
kubernetes/apps/monitoring/netpol/{ks.yaml,app/{kustomization.yaml,networkpolicy.yaml,ciliumnetworkpolicy.yaml}}
kubernetes/apps/default/netpol/{ks.yaml,app/{kustomization.yaml,networkpolicy.yaml,ciliumnetworkpolicy.yaml}}
```

Flux Kustomization names `network-netpol`, `monitoring-netpol`,
`default-netpol`. No `dependsOn` between them or onto anything else.

### `network`

Governs `external-dns` and nothing else, per finding B. No CiliumNetworkPolicy
here: cloudflared, arriving in PR4, accepts no inbound connections at all, so
there is no Gateway-ingress path into this namespace to allow.

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  egress:
    - {}
  ingress:
    - from:
        - podSelector: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-scraping
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: {}
      ports:
        - port: 7979
          protocol: TCP
        - port: 8080
          protocol: TCP
```

7979 is external-dns's own metrics port, 8080 the AdGuard webhook sidecar's.
Nothing scrapes either today. The rule ships anyway so that a later
ServiceMonitor does not silently show DOWN against a policy written weeks
earlier by someone else. That same reasoning applies forward: **PR4 adds port
2000 to this rule's port list in the same PR that adds cloudflared**, so the
allowance stays ahead of the ServiceMonitor rather than behind it, even though
Stage 3 ships no ServiceMonitor for cloudflared.

### `monitoring`

Prometheus, Grafana, Loki, Alloy, kube-state-metrics and node-exporter are all
in the same namespace as each other, so the intra-namespace ingress rule covers
them. Scraping targets outside the namespace is egress, which is unaffected.

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  egress:
    - {}
  ingress:
    - from:
        - podSelector: {}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-gateway-ingress
spec:
  # Gateway-proxied requests arrive as reserved:ingress, an identity no
  # standard NetworkPolicy selector can match. See ADR 0013.
  endpointSelector: {}
  ingress:
    - fromEntities:
        - ingress
```

`endpointSelector: {}` covers the whole namespace rather than requiring an
opt-in label per pod. The per-pod version was considered and rejected for this
stage: forgetting a label produces a broken route, not an unsafe one, so the
extra friction buys no safety. The control that actually governs exposure is the
Gateway and VAP layer, not this policy. Alertmanager, when it is eventually
enabled, lands in this namespace and needs no policy change.

### `default`

Gatus, Homepage and docs-proxy all have HTTPRoutes on the `internal` Gateway, so
this namespace takes the same two objects as `monitoring`, unchanged. Gatus is
the best test subject in the cluster: its checks resolve `*.lab.fobiat.dev`,
leave the pod, hit the Gateway, and come back as `reserved:ingress`. A green
Gatus dashboard after PR1 proves DNS, egress, the Gateway path and the ingress
allow in a single signal.

### Deliberate gaps

Stated here so they are not mistaken for oversights. `system-backup` and
`volsync-system` stay unprotected. Both hold restic credentials, and volsync's
controller can read every backed-up PVC, so they are the next namespaces to
cover. They are omitted for scope discipline, not because the risk was assessed
as low, and they go on `tasks.md` with that reasoning attached.
`cert-manager`, `kube-system`, `local-path-storage`, `kube-tools`, `reloader`
and `system-upgrade` also stay open; `flux-system` is already self-protected.
Egress is unrestricted everywhere in scope, so this stage does not constrain
exfiltration at all, only lateral movement into the three covered namespaces.
The API server remains reachable from every pod.

## PR2: admission policy

`ValidatingAdmissionPolicy` is GA at `admissionregistration.k8s.io/v1` on this
cluster (Kubernetes v1.36.3), so this costs no extra pods and no webhook
certificate. Two policies, split by resource so the CEL never has to switch on
`object.kind`.

```yaml
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: external-route-namespace
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["gateway.networking.k8s.io"]
        apiVersions: ["*"]
        operations: ["CREATE", "UPDATE"]
        resources: ["httproutes", "grpcroutes", "tlsroutes", "tcproutes", "udproutes"]
  variables:
    - name: parents
      expression: "has(object.spec.parentRefs) ? object.spec.parentRefs : []"
  validations:
    - expression: >-
        namespaceObject.metadata.name == 'network-public' ||
        !variables.parents.exists(p, p.name == 'external')
      message: "a parentRef named 'external' is only allowed in the network-public namespace"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: external-gateway-listeners
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["gateway.networking.k8s.io"]
        apiVersions: ["*"]
        operations: ["CREATE", "UPDATE"]
        resources: ["gateways"]
  validations:
    - expression: >-
        object.metadata.name != 'external' ||
        !object.spec.listeners.exists(l, !has(l.hostname) || l.hostname.contains('*'))
      message: "the external Gateway requires an exact FQDN on every listener"
      reason: Forbidden
    - expression: >-
        object.metadata.name != 'external' ||
        object.spec.listeners.all(l, !has(l.allowedRoutes) ||
          !has(l.allowedRoutes.namespaces) ||
          l.allowedRoutes.namespaces.from == 'Same')
      message: "the external Gateway may only accept routes from its own namespace"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: external-route-namespace
spec:
  policyName: external-route-namespace
  validationActions: [Deny]
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: external-gateway-listeners
spec:
  policyName: external-gateway-listeners
  validationActions: [Deny]
```

The route rule matches all five route CRDs installed on the cluster, not only
HTTPRoute, even though Cilium's controller implements a subset. Widening costs
nothing, and CRDs are what admission actually sees.

The listener check is an addition beyond PHASE-TWO's original four-layer
description, and it is worth calling out as such. Layer 1 of that description
(namespace isolation) depends on `allowedRoutes.namespaces.from: Same` staying
set on the Gateway. Without this CEL line, nothing stops a later edit changing
it to `All`. With it, the property is a guarantee instead of a convention.

Placement: `kubernetes/apps/network/gateway-guard/`. The objects are
cluster-scoped so `targetNamespace` is irrelevant, and this puts them in an
existing namespace directory, ahead of the namespace PR3 creates.

Two traps for the ADR. The policies match the literal name `external`, so
renaming the Gateway disarms all three validations silently; PHASE-TWO already
flags this for one of them. And the `XListenerSet` CRD exists on this cluster,
which could let another namespace attach listeners to the Gateway and route
around the exact-FQDN check. That is inert unless the Gateway sets
`spec.allowedListeners`, so the rule is: never set that field on the `external`
Gateway. It earns a comment on the Gateway manifest itself, because the danger
lives in a field's absence and nothing else would point at it.

### Proving it with zero residue

Use `--dry-run=server` rather than apply-then-delete. It runs the full admission
chain, persists nothing, leaves no object to clean up, and creates no window in
which a bad object exists. A denial on its own proves nothing, since a policy
that denies everything looks identical to one that works, so both a negative and
a positive control are needed. At PR2 time `network-public` does not exist yet,
so the positive control is an object that already does.

```sh
# Negative control: must be DENIED.
kubectl apply --dry-run=server -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vap-probe
  namespace: default
spec:
  parentRefs:
    - name: external
      namespace: network-public
  hostnames: ["probe.fobiat.dev"]
  rules:
    - backendRefs:
        - name: gatus
          port: 80
EOF

# Positive control: must be ALLOWED.
kubectl apply --dry-run=server -f kubernetes/apps/default/gatus/app/httproute.yaml
```

Both ship as `scripts/check-vap.sh`, asserting exit codes and message content,
rather than living as a snippet in a PR body. It is then re-runnable after the
Proxmox rebuild, and it becomes the positive-control step for PR3 as well, which
adds a third case: the same probe route, in `network-public`, must be allowed
once that namespace exists. This is a manual gate documented in the PR body,
because CI has no cluster to run it against.

## PR3: the external Gateway

Layout:

```
kubernetes/apps/network-public/kustomization.yaml
kubernetes/apps/network-public/gateway/{ks.yaml,app/{kustomization.yaml,gateway.yaml,certificate.yaml}}
kubernetes/apps/network-public/routes/{ks.yaml,app/kustomization.yaml}
```

plus `./network-public` appended to `kubernetes/apps/kustomization.yaml`.

The `routes` app ships with `resources: []` and no manifests. That is
deliberate, and it starts in Stage 3 rather than Stage 4, so that
`ls kubernetes/apps/network-public/routes/app/` is the complete answer to "what
is public?" from this stage onward instead of from the next one. One thing to
confirm during implementation: that `flux-local diff` tolerates a kustomization
with empty resources. If it does not, ship the directory and its
`kustomization.yaml` anyway but leave `ks.yaml` out, so Flux never reconciles it
until Stage 4 adds the first route alongside the wrapper. The directory has to
exist either way, because the stage's "done means" is checked by listing it.
Nothing else in PR3 depends on this.

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
spec:
  gatewayClassName: cilium
  listeners:
    - name: insights
      protocol: HTTPS
      port: 443
      hostname: insights.fobiat.dev
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: insights-fobiat-dev-tls
      allowedRoutes:
        namespaces:
          from: Same
```

The matching `Certificate` requests that single exact name against
`letsencrypt-production`, with no wildcard, using the same zone-scoped DNS-01
solver already in use.

Four things to state explicitly rather than discover later:

1. **Shipping the real hostname now is intentional.** The listener exists, the
   certificate issues, nothing attaches, nothing is reachable. Stage 4 adds only
   an HTTPRoute and a ReferenceGrant. The one visible side effect is that
   `insights.fobiat.dev` appears in Certificate Transparency logs from Stage 3,
   which publishes intent ahead of service. That is acceptable and it should be
   a stated sentence, not a surprise.
2. **No `external-dns.alpha.kubernetes.io/target` annotation in PR3.** The
   tunnel ID does not exist until PR4, so the annotation lands with or after it.
3. **Cilium creates a `cilium-gateway-external` LoadBalancer Service**, which
   takes the next LAN IP from the pool (192.168.0.241) and gets L2-announced.
   That is a real, immediate LAN change that PHASE-TWO's four-layer description
   does not mention. With zero routes and an exact-FQDN listener it answers
   nothing useful, but it exists and should be recorded.
4. **Nothing can publish this into DNS.** Three independent reasons, per finding
   C: external-dns sources from HTTPRoutes only, there are zero routes here, and
   its `domainFilters` suffix of `lab.fobiat.dev` does not match
   `insights.fobiat.dev`, against a provider that is AdGuard on the LAN rather
   than Cloudflare. That is why the stage genuinely ends with nothing resolvable
   on the internet, rather than ending with an intention not to publish.

## PR4: cloudflared

Placement is `kubernetes/apps/network/cloudflared/`, not `network-public`.
cloudflared is infrastructure of the same class as external-dns and the Gateway
controller, keeping `network-public` free of anything except the Gateway and its
routes preserves the one-`ls`-answers-what-is-public property, and it means
cloudflared inherits PR1's default-deny in `network`, which is exactly the
internet-facing pod PHASE-TWO worries about.

**Credential shape.** The tunnel-scoped Cloudflare API token is created manually
in the dashboard when this PR is reached, in the same way as the other pending
external credentials (R2, Discord, healthchecks.io). It is used once, from the
workstation, to `POST /accounts/{id}/cfd_tunnel` with `config_src: local`, and it
never enters the cluster. What the pod holds is the tunnel credentials JSON that
call returns (AccountTag, TunnelID, TunnelSecret), committed as
`cloudflared-credentials.sops.yaml`. Revoking access means deleting the tunnel,
not rotating a token. That matches PHASE-TWO's threat model, where a leaked
tunnel credential is an impersonation credential for the published hostnames and
not a route inbound, and it keeps the two-separate-tokens property honest.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
data:
  config.yaml: |
    tunnel: <tunnel-id>
    credentials-file: /etc/cloudflared/creds/credentials.json
    metrics: 0.0.0.0:2000
    no-autoupdate: true
    ingress:
      - service: http_status:404
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  annotations:
    # Without this the ingress list changes in Git and the running tunnel
    # keeps serving the old one until someone restarts it by hand.
    reloader.stakater.com/auto: "true"
spec:
  replicas: 2
  strategy:
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflared
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: docker.io/cloudflare/cloudflared:2026.8.0
          args: ["tunnel", "--config", "/etc/cloudflared/config.yaml", "run"]
          ports:
            - name: metrics
              containerPort: 2000
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 10
          volumeMounts:
            - name: config
              mountPath: /etc/cloudflared/config.yaml
              subPath: config.yaml
              readOnly: true
            - name: creds
              mountPath: /etc/cloudflared/creds
              readOnly: true
          resources:
            requests:
              cpu: 10m
              memory: 48Mi
            limits:
              memory: 128Mi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
      volumes:
        - name: config
          configMap:
            name: cloudflared-config
        - name: creds
          secret:
            secretName: cloudflared-credentials
```

`<tunnel-id>` above is the only value in this spec that cannot be filled in
during design. It is the ID returned by the tunnel-creation API call, so it is
substituted once at PR4 implementation time and then pinned in Git like any
other value. The image tag is the release current at drafting; confirm the
current tag when the PR is written, after which Renovate owns it.

Five notes that belong with this manifest:

- **The Reloader annotation is load-bearing.** PHASE-TWO's stated reason for two
  replicas is that a ConfigMap change rolls without dropping the tunnel, but a
  ConfigMap change alone triggers no rollout at all. That is the same shape as
  the Cilium ConfigMap trap already in the traps list: the value changes,
  nothing restarts, and the manifest looks correct. `reloader` is already
  deployed cluster-wide, so this is one annotation.
- **`maxUnavailable: 0` with `maxSurge: 1` means three cloudflared pods exist
  briefly** on a single node, 144Mi at peak. That is inside PHASE-TWO's ~160Mi
  line for cloudflared plus external-dns, which already counts external-dns's
  64Mi. Re-check headroom before merging, per PHASE-TWO's own rule.
- **Write no anti-affinity, on purpose.** This is a raw Deployment with none
  baked in, unlike a chart, and a `requiredDuringScheduling` podAntiAffinity
  would leave the second replica Pending forever on one node. Say so in the PR,
  so a future reviewer does not "fix" its absence.
- **Egress needed** is outbound UDP 7844 to the Cloudflare edge, with TCP
  7844/443 as fallback. Open egress in `network` covers it today. This is the
  concrete destination set that a future egress-tightening PR has to get right.
- **PR4 also edits `kubernetes/apps/network/netpol/app/networkpolicy.yaml`** to
  add port 2000 to the `allow-scraping` rule, per the PR1 section.

Stage 4's ingress entry, sketched now so that the ConfigMap's shape does not
have to change later:

```yaml
ingress:
  - hostname: insights.fobiat.dev
    service: https://cilium-gateway-external.network-public.svc.cluster.local:443
    originRequest:
      originServerName: insights.fobiat.dev
  - service: http_status:404
```

Sending SNI lets cloudflared verify the Gateway's real Let's Encrypt certificate
instead of needing `noTLSVerify`.

## Testing and rollback

The gate is the same everywhere: `task lint` locally, then CI's `lint` job
(yamllint, comment-budget check, `task docs:build`) plus the two path-filtered
`flux-diff` jobs. `lint` is the only required check under branch protection.
Stacked-PR handling follows the existing trap in the traps list: never
`--delete-branch` a lower PR until the one above it is confirmed retargeted.

### PR1

Safe to merge when `flux-diff` shows only the new policy objects. The real gate
runs after reconcile, not before merge, and any failure is treated as
revert-not-fix-forward:

1. `hubble observe --verdict DROPPED --namespace default --namespace monitoring
   --namespace network --last 200`, a few minutes after reconcile. Highest-value
   single check, because it names both identities for anything that broke.
2. Load `grafana.lab.fobiat.dev`, `status.lab.fobiat.dev`, Homepage's host and
   the docs proxy in a browser. Direct proof that the `reserved:ingress` allow
   works; if the CiliumNetworkPolicy is wrong, all four fail at once and
   unmistakably.
3. `kubectl get pods` in all three namespaces, everything Ready. Proves kubelet
   probes, which arrive as `reserved:host`, still get through.
4. Prometheus targets page, every target `up`. Pay attention to the
   `volsync-system` target specifically: it is in an unprotected namespace and
   must be unaffected, which is the control proving the scope was applied where
   it was meant to be and nowhere else.
5. `kubectl apply --dry-run=server -f` against an unmodified existing
   PrometheusRule. This exercises the `kube-prometheus-stack-admission` webhook
   path from the API server into `monitoring`, catching finding D's migration
   trap now rather than weeks later.
6. Gatus dashboard fully green, which re-proves step 2 from inside the cluster.
7. cert-manager needs no check. It is out of scope, DNS-01 only, with no inbound
   requirement. Saying so is better than inventing a check that proves nothing.

Rollback is a straight revert with no cleanup, since policies are stateless and
deletion takes effect immediately. `kubectl delete
networkpolicy,ciliumnetworkpolicy -n <ns> --all` restores service in seconds if
access needs unblocking first, but Flux re-applies the policies on its next
reconcile, so that is a stopgap of minutes and not a fix: suspend the
Kustomization if more time is needed, and follow it with an actual revert PR
either way.

### PR2

Safe to merge when CI passes and `scripts/check-vap.sh` shows the negative
control denied with `Forbidden` and the positive control allowed. Run it
pre-merge if possible; otherwise run it immediately after and treat failure as
revert.

The risk worth naming: `failurePolicy: Fail` means a CEL evaluation error blocks
every Gateway and route write cluster-wide, including Flux's own reconciles. The
positive control is the only thing standing between this PR and a stuck GitOps
loop. Rollback is a straight revert, with nothing persisted.

### PR3

Safe to merge when `flux-diff` shows only the new namespace, Gateway and
Certificate, and nothing touching the `internal` Gateway. After merge: the
Certificate reaches Ready (a couple of minutes over DNS-01), the `external`
Gateway shows Programmed, `cilium-gateway-external` has an IP from the pool,
`kubectl get httproute -A` shows zero routes attached to it, and
`check-vap.sh`'s third case now passes, with the probe route allowed inside
`network-public`.

Rollback is a revert. The only manual piece is a namespace that may sit in
Terminating; the LB IP releases itself, and the issued certificate needs no
cleanup, since the CT-log entry is permanent and does not matter.

### PR4

The only PR with a real out-of-cluster side effect. The tunnel is created before
the PR is opened, because its ID is needed in the ConfigMap, and the credentials
JSON is encrypted into the branch. Safe to merge when CI passes, the SOPS secret
is verifiably encrypted (check the diff, do not assume gitignore caught it), and
headroom has been re-checked. After merge: both replicas Running, the tunnel
Healthy with two connectors in the dashboard, zero hostnames configured, and no
DNS record anywhere pointing at `<tunnel-id>.cfargotunnel.com`.

Rollback is a revert **plus manual cleanup**. The revert removes the Deployment,
ConfigMap and Secret, but the tunnel keeps existing in the Cloudflare account and
needs `DELETE /accounts/{id}/cfd_tunnel/{tunnel_id}` with the same tunnel-scoped
token. A tunnel with no connectors is inert and routes nothing, so this is
hygiene rather than urgency, but skipping it means the next attempt collides with
an existing name.

### PR5

Contents are specified in the next section. Safe to merge when `lint` passes,
which includes `task docs:build` and therefore
catches a broken mkdocs nav entry. The two `flux-diff` jobs will not fire,
because they are path-filtered to `kubernetes/**`. That is expected and does not
block merge, since `lint` is the only required check. Rollback is a revert.

## PR5: documentation

PR5 in the home-ops repo carries two files: an ADR at
`docs/adr/0013-external-exposure-guardrails.md` (0013 is the next free number)
and a short `docs/exposure.md` describing what is public and how something
becomes public. Both get nav entries in `mkdocs.yml`. Neither file is created
during this design phase; they are written when PR5 is implemented.

The ADR is warranted regardless of the restructuring described below, because
Stage 3 makes at least four decisions worth recording: the VAP's name-matching
guard and its two traps, the CiliumNetworkPolicy exception to rule 11, the
`network-public` empty-routes convention, and cloudflared's credential model.

**Why PR5 is not what the plan originally said.** `AGENTS.md` and `PHASE-TWO.md`
are gitignored in the home-ops repo, because the real copies live in
`~/Projects/claude-configs/home-ops/`. A home-ops PR that only edited those two
files would be an empty PR. So the edits to them become a **separate
claude-configs commit**, made at the same time PR5 is implemented, and PR5
itself carries the ADR and the docs page. The content of that claude-configs
commit is specified below so it does not have to be re-derived.

**`AGENTS.md`, Domain section.** Replace "The apex is the personal website and
must stay uncoupled from the cluster" with wording that makes the distinction
explicit: uncoupled at the application layer, not at the DNS control plane.
Cloudflare cannot scope a DNS-edit token below zone level, so the DNS-01 solver
token can rewrite the apex. Nothing the cluster serves is reachable through the
apex, but a compromised cluster could still edit DNS and take the personal site
down. The mitigation is the second, tunnel-scoped token, so either can be
revoked independently; a narrower DNS token is not an option Cloudflare offers.
Add that public DNS records are upsert-only, so nothing in the cluster can issue
a delete against the zone that serves the personal site.

**`AGENTS.md`, traps list.** Two additions, both first-hand. The
`reserved:ingress` finding (A and B above), including the Hubble-verified detail
that the current address will not survive a node rebuild, so an `ipBlock` must
never be pinned to it. And the `reserved:host` versus `reserved:remote-node`
single-node-to-multi-node migration trap (D above).

**`PHASE-TWO.md`, Stage 3.** Add a checklist in the same shape the other stages
use, one line per PR, with a "done means" criterion matching the four conditions
at the top of this spec. Record the two corrections to the original design that
were found while building it: external-dns's AdGuard-not-Cloudflare setup is a
fifth defense layer worth naming, and the VAP now enforces, rather than merely
assuming, that `allowedRoutes.namespaces.from: Same` stays set.

## Follow-ups, not this stage

For `tasks.md` rather than for any of the five PRs:

- Extend default-deny to `system-backup` and `volsync-system`.
- Derive a real egress allow-list from
  `hubble observe --namespace network --verdict FORWARDED` once cloudflared has
  been running long enough to have shown its full destination set.
- The API-server pivot stays open and RBAC-controlled until egress rules exist.

One housekeeping note about this file: `mkdocs build` renders every Markdown
file under `docs/`, whether or not it appears in the nav, so this spec will be
published to the site along with everything else unless `docs/superpowers/` is
added to `exclude_docs` in `mkdocs.yml`. Nothing here is secret (the repo is
public), so this is site tidiness, not disclosure. References to files that do
not exist yet, `docs/adr/0013-external-exposure-guardrails.md` in particular,
are deliberately written as plain code spans rather than Markdown links, because
`mkdocs build --strict` fails on a link to a missing page.
