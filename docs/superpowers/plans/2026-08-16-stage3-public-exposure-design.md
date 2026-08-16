# Stage 3 Public Exposure Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the infrastructure that will one day let a service be published (default-deny NetworkPolicy, an admission guard, an external Gateway, a Cloudflare tunnel) while publishing nothing at all.

**Architecture:** Five stacked PRs, each branched from the previous one and merged bottom-up, in an order forced by dependency: NetworkPolicy first because the first internet-facing pod is also the first pod that could pivot; the `ValidatingAdmissionPolicy` before the Gateway it guards, so the guard is never briefly absent; cloudflared last because it is the only piece with an out-of-cluster side effect. Everything lands as Flux Kustomizations under `kubernetes/apps/`, following the repo's three-level app shape.

**Tech Stack:** Talos Linux, Kubernetes v1.36.3, Flux v2, Cilium CNI and Gateway API, cert-manager with a Cloudflare DNS-01 solver, SOPS with age, `cloudflare/cloudflared`, kustomize, yamllint, kubeconform, flux-local.

## Global Constraints

Every task's requirements implicitly include this section.

- **Source spec:** `docs/superpowers/specs/2026-08-16-stage3-public-exposure-design.md`. Where this plan quotes YAML, it is quoted from there verbatim. Do not redesign; if something in the spec looks wrong, stop and raise it rather than improvising.
- **Nothing becomes public in this stage.** The stage is done when the tunnel is Healthy with zero hostnames configured, no public DNS record resolves to anything in the cluster, `ls kubernetes/apps/network-public/routes/app/` lists no routes, and every LAN service still loads exactly as before.
- **Do not add the `external-dns.alpha.kubernetes.io/target` annotation anywhere in this stage.** It belongs to Stage 4. Adding it early is the one edit that could turn this stage into a live publish.
- **If it is not in Git, it does not exist** (AGENTS.md rule 4). The only `kubectl` writes permitted anywhere in this plan are `--dry-run=server`, which persists nothing. There is one deliberate exception outside the cluster: the Cloudflare tunnel in Task 12, which is created through the API because its ID is an input to a manifest.
- **Every app follows the three-level shape** (AGENTS.md rule 15): `kubernetes/apps/<namespace>/<app>/ks.yaml` plus `kubernetes/apps/<namespace>/<app>/app/`, with the namespace's `kustomization.yaml` listing only `ks.yaml` files, and `kubernetes/apps/kustomization.yaml` listing only namespace directories.
- **Comment budget 3 to 5 percent, 10 percent is a hard failure** (AGENTS.md rule 2, enforced by `scripts/comment-budget.sh` over tracked `*.yaml`, `*.yml`, `*.sh`). The tree measures 4.1 percent (455 of 11221 non-blank lines) at the time of writing. The comments this plan asks you to write are load-bearing and are already counted for; do not add others.
- **Writing style:** no em dashes, anywhere, including YAML comments, commit messages, PR bodies, the ADR and the docs page. Plain and specific. The repo is public and strangers read it.
- **Pin every image tag** (AGENTS.md rule 10). No `latest`.
- **Gate before every commit:** `task lint` (yamllint, kubeconform, comment budget, `task docs:build`). Gate before opening every PR: `task diff`.
- **Cluster commands do not work from inside this worktree.** `.mise.toml` pins `KUBECONFIG` and `TALOSCONFIG` to gitignored paths under `{{config_root}}`, and mise's `[env]` beats a shell `export`, so `kubectl` silently tries `localhost:8080`. Run every `kubectl`, `hubble`, `talosctl` and `flux` command from the main checkout at `~/Projects/home-ops`, or symlink `kubeconfig` and `talos/clusterconfig/` into the worktree first. `task lint` and `task diff` are git-only and run fine here.
- **Stacked PR trap:** never `gh pr merge --delete-branch` a lower PR while a PR above it still targets that branch. GitHub auto-closes the stacked PR rather than retargeting it, and will not reliably reopen it. Merge without `--delete-branch`, confirm the next PR up has retargeted to `main`, then delete.
- **Commits:** conventional-commit style matching the existing history, for example `feat(network): default-deny ingress in the three routed namespaces`. Author is Kyle Tarff <kyle@fobiat.dev>, GPG-signed, no Claude attribution and no session or job identifiers.
- **Secret scan before every commit and push.** Check the diff itself; do not assume `.gitignore` caught anything.
- **Branch protection:** `main` requires a PR and a passing, current `lint` check. `diff (helmrelease)` and `diff (kustomization)` are `paths: ["kubernetes/**"]` filtered, so they do not fire on a docs-only PR. That is expected and does not block merge.

---

## Why the test order is inverted here, and where it is not

The skill this plan follows assumes a unit test suite: write a failing test, watch it fail, implement, watch it pass, commit. This repo has no such suite, and half of what Stage 3 builds cannot be proven without a live cluster reconciling it. The plan therefore uses two shapes, and each task says which one it is using.

**Shape A, ordinary red-green, used for PR2 and PR3's admission guard.** `scripts/check-vap.sh` is a real executable test with real assertions. It is written first and run first, against the live cluster with `--dry-run=server`, which mutates nothing. It fails, because the policy it tests does not exist yet. The manifests then land, Flux reconciles, and the same script passes. The only difference from a unit test is that the green run happens after the merge, because Flux is what installs the code under test.

**Shape B, verification after reconcile, used for PR1, PR3's Gateway and PR4.** There is no way to write an executable test for "Grafana still loads through the Gateway" that fails before the NetworkPolicy exists, because it passes before the NetworkPolicy exists. That is the whole point: PR1's risk is a regression, not a missing feature, so the pre-merge assertion is a recorded baseline (the thing works now, and here is the command proving it) and the post-merge assertion is that the same commands still hold. The pre-merge gate is `task lint` plus `task diff` showing only the intended objects. The post-merge gate is the live verification list. Failure is handled as revert, never fix-forward, because a broken NetworkPolicy is a cluster you cannot reach the dashboards of.

Do not pretend Shape B is Shape A. Recording the baseline before the change is what makes the post-merge check mean something, and skipping it turns the verification into an opinion.

---

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `kubernetes/apps/network/netpol/ks.yaml` | Flux Kustomization `network-netpol`, targetNamespace `network` |
| `kubernetes/apps/network/netpol/app/kustomization.yaml` | Lists `./networkpolicy.yaml` |
| `kubernetes/apps/network/netpol/app/networkpolicy.yaml` | `allow-egress` and `allow-scraping` for `network`. Modified again in Task 14 |
| `kubernetes/apps/monitoring/netpol/ks.yaml` | Flux Kustomization `monitoring-netpol`, targetNamespace `monitoring` |
| `kubernetes/apps/monitoring/netpol/app/kustomization.yaml` | Lists the two policy files |
| `kubernetes/apps/monitoring/netpol/app/networkpolicy.yaml` | `allow-egress` for `monitoring` |
| `kubernetes/apps/monitoring/netpol/app/ciliumnetworkpolicy.yaml` | `allow-gateway-ingress`, the `reserved:ingress` allowance |
| `kubernetes/apps/default/netpol/ks.yaml` | Flux Kustomization `default-netpol`, targetNamespace `default` |
| `kubernetes/apps/default/netpol/app/kustomization.yaml` | Lists the two policy files |
| `kubernetes/apps/default/netpol/app/networkpolicy.yaml` | `allow-egress` for `default` |
| `kubernetes/apps/default/netpol/app/ciliumnetworkpolicy.yaml` | `allow-gateway-ingress` for `default` |
| `scripts/check-vap.sh` | The executable proof that the admission policies deny and allow the right things |
| `kubernetes/apps/network/gateway-guard/ks.yaml` | Flux Kustomization `network-gateway-guard` |
| `kubernetes/apps/network/gateway-guard/app/kustomization.yaml` | Lists `./validatingadmissionpolicy.yaml` |
| `kubernetes/apps/network/gateway-guard/app/validatingadmissionpolicy.yaml` | Both policies and both bindings, cluster-scoped |
| `kubernetes/apps/network-public/kustomization.yaml` | Namespace directory index, lists only `ks.yaml` files |
| `kubernetes/apps/network-public/gateway/ks.yaml` | Flux Kustomization `network-public-gateway` |
| `kubernetes/apps/network-public/gateway/app/kustomization.yaml` | Namespace component plus the two resources |
| `kubernetes/apps/network-public/gateway/app/gateway.yaml` | The `external` Gateway, one exact-FQDN HTTPS listener |
| `kubernetes/apps/network-public/gateway/app/certificate.yaml` | `insights.fobiat.dev` certificate, no wildcard |
| `kubernetes/apps/network-public/routes/ks.yaml` | Flux Kustomization `network-public-routes`, deliberately reconciling nothing |
| `kubernetes/apps/network-public/routes/app/kustomization.yaml` | `resources: []`. The empty directory is the answer to "what is public?" |
| `kubernetes/apps/network/cloudflared/ks.yaml` | Flux Kustomization `network-cloudflared`, with SOPS decryption |
| `kubernetes/apps/network/cloudflared/app/kustomization.yaml` | Lists the ConfigMap, Deployment and encrypted Secret |
| `kubernetes/apps/network/cloudflared/app/configmap.yaml` | Tunnel config with an ingress list of exactly one 404 |
| `kubernetes/apps/network/cloudflared/app/deployment.yaml` | Two replicas, Reloader annotation, no anti-affinity |
| `kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml` | Encrypted tunnel credentials JSON |
| `docs/adr/0013-external-exposure-guardrails.md` | The four decisions and two traps Stage 3 makes |
| `docs/exposure.md` | What is public, and how something becomes public |

### Modified

| Path | Change |
|---|---|
| `kubernetes/apps/network/kustomization.yaml` | Add `./netpol/ks.yaml` (Task 1), `./gateway-guard/ks.yaml` (Task 6), `./cloudflared/ks.yaml` (Task 13) |
| `kubernetes/apps/monitoring/kustomization.yaml` | Add `./netpol/ks.yaml` (Task 2) |
| `kubernetes/apps/default/kustomization.yaml` | Add `./netpol/ks.yaml` (Task 3) |
| `kubernetes/apps/kustomization.yaml` | Add `./network-public` (Task 8) |
| `kubernetes/apps/network/netpol/app/networkpolicy.yaml` | Add port 2000 to `allow-scraping` (Task 14, part of PR4) |
| `mkdocs.yml` | Nav entry for ADR 0013 (Task 16) and for `exposure.md` (Task 17) |
| `docs/adr/README.md` | Table row for 0013 (Task 16) |

### Modified outside this repository

`~/Projects/claude-configs/home-ops/` is gitignored from home-ops and is a separate git repository. Task 18 commits there, separately from PR5.

| Path | Change |
|---|---|
| `~/Projects/claude-configs/home-ops/AGENTS.md` | Domain section rewording, two new traps |
| `~/Projects/claude-configs/home-ops/PHASE-TWO.md` | Stage 3 checklist, done-means, two corrections |
| `~/Projects/claude-configs/home-ops/tasks.md` | Stage 3 moved to Done, four follow-ups added to Backlog |

### Two additions to the spec's verification, surfaced rather than slipped in

The spec specifies `scripts/check-vap.sh` with a negative control and a positive control for the `external-route-namespace` policy, plus a third case at PR3. This plan adds two more cases, for a reason the spec itself supplies: "A denial on its own proves nothing, since a policy that denies everything looks identical to one that works", and `failurePolicy: Fail` means a CEL evaluation error blocks every Gateway write cluster-wide, Flux's own reconciles included.

- **Case 3 (Task 5), the existing `internal` Gateway must be allowed.** The spec's two controls only ever submit an HTTPRoute, so the `external-gateway-listeners` policy is never evaluated by them. Without this case, a CEL error in that policy ships unproven and its first symptom is a stuck GitOps loop.
- **Case 5 (Task 10), a wildcard listener on a Gateway named `external` must be denied.** This is the negative control for the same policy, and it is the only check that proves the exact-FQDN rule does anything.

Both are the same shape as the cases the spec asked for, both run through `--dry-run=server`, and neither changes a manifest. Record them in the ADR's consequences (Task 16) so the addition is on the record.

---

## Task 1: NetworkPolicy for the `network` namespace

Shape B. This is PR1, branch `netpol/stage3-baseline`, based on `main`.

`network` holds `external-dns` and nothing else today, because `cilium-envoy` runs as its own `hostNetwork: true` DaemonSet in `kube-system` rather than as a proxy pod here. There is no CiliumNetworkPolicy in this namespace: cloudflared, arriving in PR4, accepts no inbound connections at all, so there is no Gateway-ingress path into `network` to allow.

**Files:**
- Create: `kubernetes/apps/network/netpol/ks.yaml`
- Create: `kubernetes/apps/network/netpol/app/kustomization.yaml`
- Create: `kubernetes/apps/network/netpol/app/networkpolicy.yaml`
- Modify: `kubernetes/apps/network/kustomization.yaml`

**Interfaces:**
- Consumes: nothing. This is the first task in the stack.
- Produces: branch `netpol/stage3-baseline`. Flux Kustomization named `network-netpol` in namespace `flux-system`, targetNamespace `network`, path `./kubernetes/apps/network/netpol/app`, no `dependsOn`. NetworkPolicy objects named `allow-egress` and `allow-scraping` in namespace `network`. Task 14 modifies `allow-scraping`'s port list in PR4 and needs that exact object name and file path.

- [ ] **Step 1: Create the branch**

From the worktree root:

```bash
git checkout main
git pull --ff-only
git checkout -b netpol/stage3-baseline
```

- [ ] **Step 2: Record the baseline, from the main checkout**

This is the Shape B stand-in for a failing test: prove the policies are absent now, so the post-merge check in Task 4 means something.

```bash
kubectl get networkpolicy -A
kubectl get ciliumnetworkpolicy -A
```

Expected: three NetworkPolicy objects, all in `flux-system` (`allow-egress`, `allow-scraping`, `allow-webhooks`), and no CiliumNetworkPolicy anywhere. Nothing in `network`, `monitoring` or `default`. Paste both outputs into the PR body in Task 4.

- [ ] **Step 3: Write the policy manifest**

Create `kubernetes/apps/network/netpol/app/networkpolicy.yaml`:

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

7979 is external-dns's own metrics port and 8080 the AdGuard webhook sidecar's. Nothing scrapes either today. The rule ships anyway so a later ServiceMonitor does not silently show DOWN against a policy written weeks earlier. Do not add a comment saying so; that reasoning belongs in the ADR from Task 16.

- [ ] **Step 4: Write the app kustomization**

Create `kubernetes/apps/network/netpol/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./networkpolicy.yaml
```

No `components/namespace`: `network-certificates` already owns that Namespace object, and two apps claiming it is a reconcile fight.

- [ ] **Step 5: Write the Flux Kustomization**

Create `kubernetes/apps/network/netpol/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: network-netpol
  namespace: flux-system
spec:
  targetNamespace: network
  commonMetadata:
    labels:
      app.kubernetes.io/name: network-netpol
  path: ./kubernetes/apps/network/netpol/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
```

No `dependsOn`, on purpose. The policies are stateless and depend on nothing, and each namespace's policies reconcile independently of the others.

- [ ] **Step 6: Wire it into the namespace index**

Edit `kubernetes/apps/network/kustomization.yaml`, appending one line to `resources`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./certificates/ks.yaml
  - ./lb-ipam/ks.yaml
  - ./gateway/ks.yaml
  - ./external-dns/ks.yaml
  - ./netpol/ks.yaml
```

- [ ] **Step 7: Run the lint gate**

Run: `task lint`
Expected: PASS. yamllint clean, kubeconform validates the two NetworkPolicy objects, the comment ratio stays near 4.1 percent, `task docs:build` unaffected.

- [ ] **Step 8: Commit**

```bash
git add kubernetes/apps/network/netpol kubernetes/apps/network/kustomization.yaml
git commit -m "feat(network): default-deny ingress in the network namespace"
```

---

## Task 2: NetworkPolicy and CiliumNetworkPolicy for `monitoring`

Shape B. Still PR1, branch `netpol/stage3-baseline`.

Gateway-proxied traffic reaches backends carrying Cilium's `reserved:ingress` identity, which is not a pod, not a namespace, and has no stable address a `podSelector`, `namespaceSelector` or `ipBlock` can name. This was confirmed by Hubble flow capture, not assumed. A standard NetworkPolicy cannot express it, so this namespace needs a Cilium-specific object alongside the standard one, or LAN access to Grafana breaks the moment the policy lands.

**Files:**
- Create: `kubernetes/apps/monitoring/netpol/ks.yaml`
- Create: `kubernetes/apps/monitoring/netpol/app/kustomization.yaml`
- Create: `kubernetes/apps/monitoring/netpol/app/networkpolicy.yaml`
- Create: `kubernetes/apps/monitoring/netpol/app/ciliumnetworkpolicy.yaml`
- Modify: `kubernetes/apps/monitoring/kustomization.yaml`

**Interfaces:**
- Consumes: branch `netpol/stage3-baseline` from Task 1.
- Produces: Flux Kustomization named `monitoring-netpol`, targetNamespace `monitoring`, no `dependsOn`. A NetworkPolicy named `allow-egress` and a CiliumNetworkPolicy named `allow-gateway-ingress`, both in namespace `monitoring`. Task 4's verification, Task 16's ADR and Task 18's trap entry all refer to `allow-gateway-ingress` by that exact name.

- [ ] **Step 1: Write the standard policy**

Create `kubernetes/apps/monitoring/netpol/app/networkpolicy.yaml`:

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
```

Prometheus, Grafana, Loki, Alloy, kube-state-metrics and node-exporter all sit in this namespace, so the intra-namespace rule covers every path between them. Scraping targets outside the namespace is egress, which stays fully open.

- [ ] **Step 2: Write the Cilium policy**

Create `kubernetes/apps/monitoring/netpol/app/ciliumnetworkpolicy.yaml`:

```yaml
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

Keep that comment exactly as written. It is the one place a reader meets a second policy dialect, and the ADR it cites is written in Task 16. `endpointSelector: {}` covers the whole namespace rather than requiring an opt-in label per pod, because forgetting a label produces a broken route rather than an unsafe one.

- [ ] **Step 3: Write the app kustomization**

Create `kubernetes/apps/monitoring/netpol/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./networkpolicy.yaml
  - ./ciliumnetworkpolicy.yaml
```

- [ ] **Step 4: Write the Flux Kustomization**

Create `kubernetes/apps/monitoring/netpol/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: monitoring-netpol
  namespace: flux-system
spec:
  targetNamespace: monitoring
  commonMetadata:
    labels:
      app.kubernetes.io/name: monitoring-netpol
  path: ./kubernetes/apps/monitoring/netpol/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
```

- [ ] **Step 5: Wire it into the namespace index**

Edit `kubernetes/apps/monitoring/kustomization.yaml`, appending one line to `resources`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./kube-prometheus-stack/ks.yaml
  - ./loki/ks.yaml
  - ./alloy/ks.yaml
  - ./grafana-dashboards/ks.yaml
  - ./grafana-restore/ks.yaml
  - ./netpol/ks.yaml
```

- [ ] **Step 6: Run the lint gate**

Run: `task lint`
Expected: PASS. `scripts/kubeconform.sh` passes `-ignore-missing-schemas`, so an unresolved CiliumNetworkPolicy schema is skipped rather than failing. If kubeconform reports a hard error on the CiliumNetworkPolicy rather than skipping it, stop and read `scripts/crd-schemas.sh` before changing the manifest.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/apps/monitoring/netpol kubernetes/apps/monitoring/kustomization.yaml
git commit -m "feat(monitoring): default-deny ingress, with the Gateway path allowed"
```

---

## Task 3: NetworkPolicy and CiliumNetworkPolicy for `default`

Shape B. Still PR1, branch `netpol/stage3-baseline`.

Gatus, Homepage and docs-proxy all have HTTPRoutes on the `internal` Gateway, so this namespace takes the same two objects as `monitoring`. Gatus is the best test subject in the cluster: its checks resolve `*.lab.fobiat.dev`, leave the pod, hit the Gateway and come back as `reserved:ingress`, so a green Gatus dashboard proves DNS, egress, the Gateway path and the ingress allow in one signal.

**Files:**
- Create: `kubernetes/apps/default/netpol/ks.yaml`
- Create: `kubernetes/apps/default/netpol/app/kustomization.yaml`
- Create: `kubernetes/apps/default/netpol/app/networkpolicy.yaml`
- Create: `kubernetes/apps/default/netpol/app/ciliumnetworkpolicy.yaml`
- Modify: `kubernetes/apps/default/kustomization.yaml`

**Interfaces:**
- Consumes: branch `netpol/stage3-baseline` from Tasks 1 and 2.
- Produces: Flux Kustomization named `default-netpol`, targetNamespace `default`, no `dependsOn`. A NetworkPolicy named `allow-egress` and a CiliumNetworkPolicy named `allow-gateway-ingress`, both in namespace `default`.

- [ ] **Step 1: Write the standard policy**

Create `kubernetes/apps/default/netpol/app/networkpolicy.yaml`:

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
```

- [ ] **Step 2: Write the Cilium policy**

Create `kubernetes/apps/default/netpol/app/ciliumnetworkpolicy.yaml`:

```yaml
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

Identical to the `monitoring` one by design. Same object name, same selector, same comment. Two namespaces with the same problem get the same answer, and a diff between the two files should be empty.

- [ ] **Step 3: Write the app kustomization**

Create `kubernetes/apps/default/netpol/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./networkpolicy.yaml
  - ./ciliumnetworkpolicy.yaml
```

- [ ] **Step 4: Write the Flux Kustomization**

Create `kubernetes/apps/default/netpol/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: default-netpol
  namespace: flux-system
spec:
  targetNamespace: default
  commonMetadata:
    labels:
      app.kubernetes.io/name: default-netpol
  path: ./kubernetes/apps/default/netpol/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
```

- [ ] **Step 5: Wire it into the namespace index**

Edit `kubernetes/apps/default/kustomization.yaml`, appending one line to `resources`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./homepage/ks.yaml
  - ./gatus/ks.yaml
  - ./gatus-restore/ks.yaml
  - ./docs-proxy/ks.yaml
  - ./netpol/ks.yaml
```

- [ ] **Step 6: Run the lint gate**

Run: `task lint`
Expected: PASS.

- [ ] **Step 7: Confirm the two Cilium policies are byte-identical**

Run: `diff kubernetes/apps/monitoring/netpol/app/ciliumnetworkpolicy.yaml kubernetes/apps/default/netpol/app/ciliumnetworkpolicy.yaml`
Expected: no output. If they differ, one of them is wrong.

- [ ] **Step 8: Commit**

```bash
git add kubernetes/apps/default/netpol kubernetes/apps/default/kustomization.yaml
git commit -m "feat(default): default-deny ingress, with the Gateway path allowed"
```

---

## Task 4: Open, merge and verify PR1

Shape B, verification half. The seven checks below run **after** Flux reconciles, not before merge, for the reason given in the "Why the test order is inverted here" section: PR1's risk is a regression in traffic that already works, so there is nothing that could fail before the change lands. Any failure is treated as revert, never fix-forward.

**Files:** none created or modified. This task produces a merged PR and a verification record.

**Interfaces:**
- Consumes: branch `netpol/stage3-baseline` carrying Tasks 1 to 3. The baseline output recorded in Task 1 Step 2. The object names `allow-egress`, `allow-scraping` and `allow-gateway-ingress`.
- Produces: `netpol/stage3-baseline` merged into `main`, and the three Flux Kustomizations `network-netpol`, `monitoring-netpol`, `default-netpol` Ready in the cluster. PR2 branches from `netpol/stage3-baseline`, so do not delete that branch yet.

- [ ] **Step 1: Run the diff gate**

Run: `task diff`
Expected: only the new objects appear. Two NetworkPolicy objects in `network`, one NetworkPolicy and one CiliumNetworkPolicy each in `monitoring` and `default`, plus the three Flux Kustomization wrappers. Nothing else changes. If anything touches an existing Deployment, HelmRelease or Gateway, stop.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin netpol/stage3-baseline
gh pr create --base main --title "feat: default-deny NetworkPolicy in network, monitoring and default" --body-file -
```

The body must state: this is part 1 of 5 in the Stage 3 stack; egress stays fully open on purpose, matching the flux-system precedent; the CiliumNetworkPolicy exists because `reserved:ingress` cannot be named by a standard selector and ADR 0013 in PR5 records why; the Task 1 Step 2 baseline output; and the seven verification steps below as the post-merge gate.

- [ ] **Step 3: Wait for CI, then merge**

Run: `gh pr checks --watch`
Expected: `lint` passes. `diff (kustomization)` posts a comment matching Step 1.

Merge with `gh pr merge --squash` and **without** `--delete-branch`. PR2 is stacked on this branch.

- [ ] **Step 4: Wait for reconcile, then check for drops**

From the main checkout, a few minutes after the merge:

```bash
flux get kustomizations | grep netpol
hubble observe --verdict DROPPED --namespace default --namespace monitoring --namespace network --last 200
```

Expected: three Kustomizations Ready. Zero dropped flows between workloads. This is the highest-value single check, because it names both identities for anything that broke. Kubelet probes arriving as `reserved:host` are covered by Cilium's default `allow-localhost: auto` and must not appear here.

- [ ] **Step 5: Load all four LAN services in a browser**

Open `grafana.lab.fobiat.dev`, `status.lab.fobiat.dev`, Homepage's host and the docs proxy.
Expected: all four load. This is the direct proof that the `reserved:ingress` allow works. If `allow-gateway-ingress` is wrong, all four fail at once and unmistakably, which is exactly the signal you want.

- [ ] **Step 6: Check pods and Prometheus targets**

```bash
kubectl get pods -n network
kubectl get pods -n monitoring
kubectl get pods -n default
```

Expected: everything Ready, proving kubelet probes still get through. Three separate invocations, because a repeated `-n` flag keeps only the last namespace and would quietly check one namespace out of three.

Then open the Prometheus targets page. Expected: every target `up`. Pay specific attention to the `volsync-system` target: it sits in an unprotected namespace and must be unaffected, which is the control proving the scope landed where it was meant to and nowhere else.

- [ ] **Step 7: Exercise the admission webhook path into `monitoring`**

The API server calls `monitoring/kube-prometheus-stack-operator:443` for PrometheusRule validation. On this single node it arrives as `reserved:host` and works; on a multi-node cluster it would arrive as `reserved:remote-node` and would be denied, with the failure showing up as a silently rejected PrometheusRule edit weeks later.

```bash
kubectl apply --dry-run=server -f kubernetes/apps/monitoring/kube-prometheus-stack/app/prometheusrule-node.yaml
```

Expected: `configured (server dry run)`, no webhook timeout. A `context deadline exceeded` or `failed calling webhook` error means the policy has cut the API server off from the operator, and the fix is a revert.

- [ ] **Step 8: Confirm Gatus is green**

Open the Gatus dashboard. Expected: every check green. This re-proves step 5 from inside the cluster, over a path that leaves a pod, resolves `*.lab.fobiat.dev`, transits the Gateway and returns as `reserved:ingress`.

cert-manager needs no check here. It is DNS-01 only, with no inbound requirement, and inventing a check that proves nothing is worse than saying so.

- [ ] **Step 9: If anything failed, revert**

```bash
kubectl delete networkpolicy,ciliumnetworkpolicy -n <namespace> --all
```

restores service in seconds, but Flux re-applies on its next reconcile, so that is a stopgap of minutes and not a fix. `flux suspend kustomization <name>` buys more time. Either way, follow it with a real revert PR. Policies are stateless and deletion takes effect immediately, so there is no cleanup beyond that.

---

## Task 5: Write `scripts/check-vap.sh` and watch it fail

Shape A, red phase. This is PR2, branch `gateway/external-vap`, based on `netpol/stage3-baseline`.

The script is the test. It is written before the policies, run before the policies exist, and must fail. It uses `--dry-run=server` throughout rather than apply-then-delete: that runs the full admission chain, persists nothing, leaves no object to clean up, and creates no window in which a bad object exists.

**Files:**
- Create: `scripts/check-vap.sh`

**Interfaces:**
- Consumes: branch `netpol/stage3-baseline` from Task 4. The existing manifests `kubernetes/apps/default/gatus/app/httproute.yaml` and `kubernetes/apps/network/gateway/app/gateway.yaml` as positive controls.
- Produces: branch `gateway/external-vap`. An executable `scripts/check-vap.sh` taking no arguments, exiting 0 when every case passes and 1 otherwise, printing one `PASS` or `FAIL` line per case. Task 10 appends cases 4 and 5 to the same script and relies on the `expect_denied` and `expect_allowed` helper names and the `$fail` accumulator defined here.

- [ ] **Step 1: Create the branch**

```bash
git checkout netpol/stage3-baseline
git checkout -b gateway/external-vap
```

Branch from `netpol/stage3-baseline`, not from `main`. This is the stacked-PR convention, and PR2's positive control depends on nothing from PR1, but the merge order does.

- [ ] **Step 2: Write the script**

Create `scripts/check-vap.sh`:

```bash
#!/usr/bin/env bash
# Proves the external-exposure admission policies deny and allow the right things.
# Runs everything through --dry-run=server, so it persists nothing. See ADR 0013.
set -uo pipefail

fail=0

expect_denied() {
  local name=$1 want=$2 manifest=$3 out rc
  out=$(kubectl apply --dry-run=server -f - <<<"$manifest" 2>&1) && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf 'FAIL %s: expected a denial, the API server accepted it\n' "$name" >&2
    fail=1
  elif ! grep -qF "$want" <<<"$out"; then
    printf 'FAIL %s: denied, but not by the expected rule\n  wanted: %s\n  got: %s\n' \
      "$name" "$want" "$out" >&2
    fail=1
  else
    printf 'PASS %s: denied as expected\n' "$name"
  fi
}

expect_allowed() {
  local name=$1 file=$2 out rc
  out=$(kubectl apply --dry-run=server -f "$file" 2>&1) && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf 'FAIL %s: expected acceptance, got: %s\n' "$name" "$out" >&2
    fail=1
  else
    printf 'PASS %s: allowed as expected\n' "$name"
  fi
}

expect_denied "route-outside-network-public" \
  "a parentRef named 'external' is only allowed in the network-public namespace" \
  "$(cat <<'EOF'
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
)"

expect_allowed "existing-gatus-route" kubernetes/apps/default/gatus/app/httproute.yaml
expect_allowed "existing-internal-gateway" kubernetes/apps/network/gateway/app/gateway.yaml

exit "$fail"
```

Three cases. The first is the negative control. The second is the positive control the spec names, and it is the only thing standing between PR2 and a stuck GitOps loop, because `failurePolicy: Fail` means a CEL evaluation error blocks every route write cluster-wide including Flux's own. The third is this plan's addition: without it the `external-gateway-listeners` policy is never evaluated by any case, and the same stuck-loop risk applies to every Gateway write.

- [ ] **Step 3: Make it executable**

```bash
chmod +x scripts/check-vap.sh
```

- [ ] **Step 4: Run it and confirm it fails, from the main checkout**

Run: `bash scripts/check-vap.sh`
Expected: `FAIL route-outside-network-public: expected a denial, the API server accepted it`, then `PASS` for the two positive controls, and exit code 1. This is the red phase and it is the point of writing the script first: it proves the guard is genuinely absent right now, so the green run in Task 7 is evidence rather than assertion.

Check the exit code explicitly: `bash scripts/check-vap.sh; echo "exit $?"` must print `exit 1`.

- [ ] **Step 5: Run the lint gate**

Run: `task lint`
Expected: PASS. `scripts/comment-budget.sh` counts `*.sh` files, and this script carries three comment lines against roughly 55 lines of code, which sits inside the budget.

- [ ] **Step 6: Commit the failing test**

```bash
git add scripts/check-vap.sh
git commit -m "test(gateway): check-vap.sh, which fails until the admission policies exist"
```

---

## Task 6: The ValidatingAdmissionPolicy pair

Shape A, implementation half. Still PR2, branch `gateway/external-vap`.

`ValidatingAdmissionPolicy` is GA at `admissionregistration.k8s.io/v1` on this cluster (Kubernetes v1.36.3), so this costs no extra pods and no webhook certificate. Two policies, split by resource so the CEL never has to switch on `object.kind`. They land before the Gateway they guard so the guard is never briefly absent, and so they can be proven against zero real objects.

**Files:**
- Create: `kubernetes/apps/network/gateway-guard/ks.yaml`
- Create: `kubernetes/apps/network/gateway-guard/app/kustomization.yaml`
- Create: `kubernetes/apps/network/gateway-guard/app/validatingadmissionpolicy.yaml`
- Modify: `kubernetes/apps/network/kustomization.yaml`

**Interfaces:**
- Consumes: branch `gateway/external-vap` and `scripts/check-vap.sh` from Task 5, whose case 1 asserts the exact message string `a parentRef named 'external' is only allowed in the network-public namespace`. That string must match the manifest character for character.
- Produces: Flux Kustomization named `network-gateway-guard`, targetNamespace `network`, no `dependsOn`. Cluster-scoped ValidatingAdmissionPolicy objects named `external-route-namespace` and `external-gateway-listeners`, each with a ValidatingAdmissionPolicyBinding of the same name. Task 8's Gateway must be named `external` and its listener hostname must be an exact FQDN, or these policies reject it.

- [ ] **Step 1: Write the policy manifest**

Create `kubernetes/apps/network/gateway-guard/app/validatingadmissionpolicy.yaml`:

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

The route rule matches all five route CRDs installed on the cluster, not only HTTPRoute, even though Cilium's controller implements a subset. Widening costs nothing, and CRDs are what admission actually sees.

The second listener validation is an addition beyond the original four-layer description in PHASE-TWO.md. Layer 1 of that description depends on `allowedRoutes.namespaces.from: Same` staying set on the Gateway, and without this line nothing stops a later edit changing it to `All`. With it, the property is a guarantee rather than a convention.

- [ ] **Step 2: Write the app kustomization**

Create `kubernetes/apps/network/gateway-guard/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./validatingadmissionpolicy.yaml
```

- [ ] **Step 3: Write the Flux Kustomization**

Create `kubernetes/apps/network/gateway-guard/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: network-gateway-guard
  namespace: flux-system
spec:
  targetNamespace: network
  commonMetadata:
    labels:
      app.kubernetes.io/name: network-gateway-guard
  path: ./kubernetes/apps/network/gateway-guard/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
```

The objects are cluster-scoped, so `targetNamespace` has no effect on them. It is set for consistency with every other app in this namespace directory, and `network` is used because it already exists, ahead of the `network-public` namespace that PR3 creates.

- [ ] **Step 4: Wire it into the namespace index**

Edit `kubernetes/apps/network/kustomization.yaml`, appending one line to `resources`, so it reads:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./certificates/ks.yaml
  - ./lb-ipam/ks.yaml
  - ./gateway/ks.yaml
  - ./external-dns/ks.yaml
  - ./netpol/ks.yaml
  - ./gateway-guard/ks.yaml
```

- [ ] **Step 5: Confirm the message string matches the test**

Run: `grep -F "a parentRef named 'external' is only allowed in the network-public namespace" kubernetes/apps/network/gateway-guard/app/validatingadmissionpolicy.yaml scripts/check-vap.sh`
Expected: two hits, one per file. A mismatch here makes case 1 fail in Task 7 for the wrong reason, and the failure looks like a broken policy rather than a typo.

- [ ] **Step 6: Run the lint gate**

Run: `task lint`
Expected: PASS. kubeconform resolves `admissionregistration.k8s.io/v1` from the default schema location, since these are core Kubernetes types rather than CRDs.

- [ ] **Step 7: Run the diff gate**

Run: `task diff`
Expected: only the two ValidatingAdmissionPolicy objects, the two bindings and the `network-gateway-guard` wrapper. No change to any existing Gateway or route.

- [ ] **Step 8: Commit**

```bash
git add kubernetes/apps/network/gateway-guard kubernetes/apps/network/kustomization.yaml
git commit -m "feat(network): admission policies constraining how the external Gateway can be used"
```

---

## Task 7: Open, merge and verify PR2

Shape A, green phase. The script from Task 5 runs again unchanged and must now pass every case.

**Files:** none created or modified.

**Interfaces:**
- Consumes: branch `gateway/external-vap` carrying Tasks 5 and 6. The red run recorded in Task 5 Step 4.
- Produces: `gateway/external-vap` merged into `main`, both policies live, `scripts/check-vap.sh` exiting 0. PR3 branches from `gateway/external-vap`, so do not delete that branch yet.

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin gateway/external-vap
gh pr create --base netpol/stage3-baseline --title "feat: admission policies for the external Gateway" --body-file -
```

Base is `netpol/stage3-baseline`, not `main`. The body must state: stacked on PR1, part 2 of 5, merge after PR1; `scripts/check-vap.sh` is the gate and CI cannot run it because CI has no cluster, so it is a manual gate; the red run output from Task 5 Step 4; and the named risk, that `failurePolicy: Fail` means a CEL evaluation error blocks every Gateway and route write cluster-wide including Flux's own reconciles, which is what the positive controls exist to catch.

- [ ] **Step 2: Optional stronger pre-merge gate**

If you want the green phase before the merge rather than after, bring up the throwaway cluster with `task talos:test` (AGENTS.md rule 8), apply the policy manifest there, and run `scripts/check-vap.sh` against it. This is optional because the two positive controls reference manifests that exist in this repo and the throwaway cluster has no Gateway CRDs installed by default, which makes the setup cost real. Skipping it is fine; the merge-then-verify path below is the documented one.

- [ ] **Step 3: Merge after PR1 is in**

Confirm PR1 has merged and this PR has retargeted to `main`. Run `gh pr checks --watch`, expect `lint` to pass, then `gh pr merge --squash` without `--delete-branch`.

- [ ] **Step 4: Wait for reconcile, then run the test green**

From the main checkout:

```bash
flux get kustomizations | grep gateway-guard
bash scripts/check-vap.sh; echo "exit $?"
```

Expected: `network-gateway-guard` Ready, then

```
PASS route-outside-network-public: denied as expected
PASS existing-gatus-route: allowed as expected
PASS existing-internal-gateway: allowed as expected
exit 0
```

Case 1 flipping from FAIL to PASS while cases 2 and 3 stay PASS is the whole proof. A policy that denied everything would show case 1 passing and cases 2 and 3 failing, which is why both halves are needed.

- [ ] **Step 5: Confirm Flux itself is not stuck**

Run: `flux get kustomizations --all-namespaces`
Expected: everything Ready, nothing in a reconcile failure mentioning admission. If any Kustomization managing a Gateway or route is failing, that is the `failurePolicy: Fail` risk realised, and the fix is an immediate revert. Nothing is persisted by these policies, so the revert is clean.

---

## Task 8: The `network-public` namespace and the external Gateway

Shape B for the Gateway itself, since the Certificate and the LoadBalancer only exist once Flux reconciles. PR3, branch `gateway/external`, based on `gateway/external-vap`.

Shipping the real hostname now is intentional. The listener exists, the certificate issues, nothing attaches, nothing is reachable. The one visible side effect is that `insights.fobiat.dev` appears in Certificate Transparency logs from this stage, which publishes intent ahead of service. That is acceptable and it is stated rather than discovered.

**Files:**
- Create: `kubernetes/apps/network-public/kustomization.yaml`
- Create: `kubernetes/apps/network-public/gateway/ks.yaml`
- Create: `kubernetes/apps/network-public/gateway/app/kustomization.yaml`
- Create: `kubernetes/apps/network-public/gateway/app/gateway.yaml`
- Create: `kubernetes/apps/network-public/gateway/app/certificate.yaml`
- Modify: `kubernetes/apps/kustomization.yaml`

**Interfaces:**
- Consumes: branch `gateway/external-vap` from Task 7, and the live `external-gateway-listeners` policy, which rejects this Gateway unless it is named `external`, every listener carries an exact FQDN hostname with no `*`, and every listener sets `allowedRoutes.namespaces.from: Same`.
- Produces: branch `gateway/external`. Namespace `network-public`. Flux Kustomization named `network-public-gateway`. A Gateway named `external` with a single listener named `insights` on port 443 for `insights.fobiat.dev`, referencing Secret `insights-fobiat-dev-tls`. A Certificate named `insights-fobiat-dev` producing that Secret. Cilium creates a Service named `cilium-gateway-external` in `network-public`. Task 10, Task 11 and Task 13 all use these exact names.

- [ ] **Step 1: Create the branch**

```bash
git checkout gateway/external-vap
git checkout -b gateway/external
```

- [ ] **Step 2: Write the Gateway**

Create `kubernetes/apps/network-public/gateway/app/gateway.yaml`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
spec:
  # Never set spec.allowedListeners here. The XListenerSet CRD is installed, and
  # allowing it would let another namespace attach listeners that skip the
  # exact-FQDN check in the external-gateway-listeners policy.
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

Keep that comment. It is the one case in this stage where the danger lives in a field's absence, so nothing else in the tree would ever point at it.

- [ ] **Step 3: Write the Certificate**

Create `kubernetes/apps/network-public/gateway/app/certificate.yaml`:

```yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insights-fobiat-dev
spec:
  secretName: insights-fobiat-dev-tls
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
  dnsNames:
    - insights.fobiat.dev
```

One exact name, no wildcard, against the same zone-scoped DNS-01 solver already in use for `*.lab.fobiat.dev`.

- [ ] **Step 4: Write the app kustomization**

Create `kubernetes/apps/network-public/gateway/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
components:
  - ../../../../components/namespace
resources:
  - ./certificate.yaml
  - ./gateway.yaml
```

This app owns the namespace, so it pulls in the `namespace` component. The component ships a Namespace named `_` which kustomize's namespace transformer renames to whatever `targetNamespace` the including Kustomization sets. Use `namespace`, not `namespace-privileged`: nothing here needs hostPath, so nothing needs the Pod Security exemption.

- [ ] **Step 5: Write the Flux Kustomization**

Create `kubernetes/apps/network-public/gateway/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: network-public-gateway
  namespace: flux-system
spec:
  targetNamespace: network-public
  dependsOn:
    - name: cert-manager-cluster-issuers
    - name: network-lb-ipam
  commonMetadata:
    labels:
      app.kubernetes.io/name: network-public-gateway
  path: ./kubernetes/apps/network-public/gateway/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
```

`dependsOn` mirrors `network-gateway`: the ClusterIssuer must exist before the Certificate, and the LB IPAM pool before Cilium can hand the Gateway's Service an address.

- [ ] **Step 6: Write the namespace index**

Create `kubernetes/apps/network-public/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./gateway/ks.yaml
```

Task 9 appends `./routes/ks.yaml` to this file.

- [ ] **Step 7: Wire the namespace into the apps index**

Edit `kubernetes/apps/kustomization.yaml`, appending `./network-public` to `resources` so it reads:

```yaml
resources:
  - ./cert-manager
  - ./network
  - ./reloader
  - ./local-path-storage
  - ./volsync-system
  - ./monitoring
  - ./system-backup
  - ./default
  - ./kube-tools
  - ./system-upgrade
  - ./network-public
```

Leave the file's existing header comment untouched.

- [ ] **Step 8: Run the lint gate**

Run: `task lint`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add kubernetes/apps/network-public kubernetes/apps/kustomization.yaml
git commit -m "feat(network-public): the external Gateway, with one exact-FQDN listener and no routes"
```

---

## Task 9: The empty `routes` app

Still PR3, branch `gateway/external`.

The `routes` app ships with `resources: []` and no manifests. That is deliberate and it starts in Stage 3 rather than Stage 4, so that `ls kubernetes/apps/network-public/routes/app/` is the complete answer to "what is public?" from this stage onward instead of from the next one.

**Files:**
- Create: `kubernetes/apps/network-public/routes/ks.yaml`
- Create: `kubernetes/apps/network-public/routes/app/kustomization.yaml`
- Modify: `kubernetes/apps/network-public/kustomization.yaml`

**Interfaces:**
- Consumes: branch `gateway/external` and `kubernetes/apps/network-public/kustomization.yaml` from Task 8.
- Produces: Flux Kustomization named `network-public-routes`, targetNamespace `network-public`, `dependsOn: network-public-gateway`, reconciling an empty resource list. Stage 4 adds its HTTPRoute into `kubernetes/apps/network-public/routes/app/` and lists it in that kustomization.

- [ ] **Step 1: Write the empty app kustomization**

Create `kubernetes/apps/network-public/routes/app/kustomization.yaml`:

```yaml
---
# Empty on purpose. `ls` on this directory is the complete answer to what is
# public, and Stage 4 adds the first route here.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

- [ ] **Step 2: Write the Flux Kustomization**

Create `kubernetes/apps/network-public/routes/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: network-public-routes
  namespace: flux-system
spec:
  targetNamespace: network-public
  dependsOn:
    - name: network-public-gateway
  commonMetadata:
    labels:
      app.kubernetes.io/name: network-public-routes
  path: ./kubernetes/apps/network-public/routes/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
```

- [ ] **Step 3: Wire it into the namespace index**

Edit `kubernetes/apps/network-public/kustomization.yaml` so it reads:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./gateway/ks.yaml
  - ./routes/ks.yaml
```

- [ ] **Step 4: Confirm the tooling tolerates an empty resource list**

Run: `task lint`
Then run: `task diff`

Expected: both pass, and `task diff` shows the `network-public-routes` wrapper with no resources under it.

If either fails on the empty kustomization, take the documented fallback rather than inventing a placeholder resource: keep `kubernetes/apps/network-public/routes/app/kustomization.yaml` exactly as written, delete `kubernetes/apps/network-public/routes/ks.yaml`, and remove the `./routes/ks.yaml` line from the namespace index. Flux then never reconciles the directory until Stage 4 adds the first route alongside its wrapper. The directory has to exist either way, because the stage's done-means is checked by listing it. Nothing else in PR3 depends on which branch of this you take, but record which one you took in the PR body and in Task 16's ADR.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/network-public
git commit -m "feat(network-public): an empty routes app, so listing it answers what is public"
```

---

## Task 10: Add the `network-public` cases to `check-vap.sh`

Shape A, red phase again. Still PR3, branch `gateway/external`.

Two cases, both of which can only exist now that `network-public` does. Case 4 is the one the spec asks for: the same probe route that was denied in `default` must be allowed inside `network-public`, and the object is byte-identical apart from the namespace, which makes it a clean control. Case 5 is this plan's addition and is the negative control for `external-gateway-listeners`, the only check that proves the exact-FQDN rule does anything.

**Files:**
- Modify: `scripts/check-vap.sh`

**Interfaces:**
- Consumes: `scripts/check-vap.sh` from Task 5, specifically the `expect_denied` and `expect_allowed` helpers and the `fail` accumulator. Namespace `network-public` and Gateway name `external` from Task 8.
- Produces: a five-case `scripts/check-vap.sh`, still exiting 0 only when all five pass. Task 11 runs it as PR3's post-merge gate.

- [ ] **Step 1: Add an inline-manifest allow helper**

`expect_allowed` takes a file path, and case 4 needs a heredoc. Add this helper immediately after `expect_allowed` in `scripts/check-vap.sh`:

```bash
expect_allowed_inline() {
  local name=$1 manifest=$2 out rc
  out=$(kubectl apply --dry-run=server -f - <<<"$manifest" 2>&1) && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf 'FAIL %s: expected acceptance, got: %s\n' "$name" "$out" >&2
    fail=1
  else
    printf 'PASS %s: allowed as expected\n' "$name"
  fi
}
```

- [ ] **Step 2: Add cases 4 and 5**

Insert both immediately before the final `exit "$fail"` line:

```bash
expect_allowed_inline "route-inside-network-public" "$(cat <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vap-probe
  namespace: network-public
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
)"

expect_denied "wildcard-listener-on-external" \
  "the external Gateway requires an exact FQDN on every listener" \
  "$(cat <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: network-public
spec:
  gatewayClassName: cilium
  listeners:
    - name: wildcard
      protocol: HTTPS
      port: 443
      hostname: "*.fobiat.dev"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: insights-fobiat-dev-tls
      allowedRoutes:
        namespaces:
          from: Same
EOF
)"
```

Case 5 submits an object with the same name as the real Gateway. `--dry-run=server` persists nothing, so the live Gateway is never touched, and the denial happens in admission before anything reaches storage.

- [ ] **Step 3: Run it and confirm the new cases fail**

From the main checkout, before PR3 merges:

Run: `bash scripts/check-vap.sh; echo "exit $?"`
Expected: cases 1, 2 and 3 PASS (PR2 is already live), case 4 FAILs because namespace `network-public` does not exist yet, case 5 PASSes already because `external-gateway-listeners` is live and does not care whether the Gateway exists. Exit code 1.

Case 5 passing in the red run is correct and not a mistake in the plan: the policy it tests shipped in PR2, and its object is submitted rather than fetched. Case 4 is the one that must flip.

- [ ] **Step 4: Run the lint gate**

Run: `task lint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/check-vap.sh
git commit -m "test(gateway): prove routes are allowed inside network-public and wildcards are not"
```

---

## Task 11: Open, merge and verify PR3

Mixed: Shape A green for `check-vap.sh` case 4, Shape B for the Gateway, Certificate and LoadBalancer, which cannot exist before Flux reconciles.

**Files:** none created or modified.

**Interfaces:**
- Consumes: branch `gateway/external` carrying Tasks 8 to 10.
- Produces: `gateway/external` merged into `main`. Gateway `external` Programmed, Certificate `insights-fobiat-dev` Ready, Service `cilium-gateway-external` holding an IP from the pool, zero routes attached. PR4 branches from `gateway/external`, so do not delete that branch yet.

- [ ] **Step 1: Run the diff gate**

Run: `task diff`
Expected: the `network-public` Namespace, the `external` Gateway, the `insights-fobiat-dev` Certificate and the two Flux wrappers. **Nothing touching the `internal` Gateway.** If the `internal` Gateway appears in the diff, stop: something in the new kustomization is reaching outside its own directory.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin gateway/external
gh pr create --base gateway/external-vap --title "feat: the external Gateway, with zero routes attached" --body-file -
```

The body must state: stacked on PR2, part 3 of 5; the real hostname ships now on purpose and `insights.fobiat.dev` will appear in Certificate Transparency logs from this PR, which publishes intent ahead of service; no `external-dns.alpha.kubernetes.io/target` annotation is added here because the tunnel ID does not exist until PR4; Cilium creates a `cilium-gateway-external` LoadBalancer Service that takes the next LAN IP from the pool and gets L2-announced, which is a real immediate LAN change; and nothing can publish this into DNS, for three independent reasons, namely that external-dns sources records from HTTPRoutes only, there are zero routes here, and its `domainFilters` suffix of `lab.fobiat.dev` does not match `insights.fobiat.dev`, against a provider that is AdGuard on the LAN rather than Cloudflare.

- [ ] **Step 3: Merge after PR2 is in**

Confirm PR2 has merged and this PR has retargeted to `main`. Run `gh pr checks --watch`, then `gh pr merge --squash` without `--delete-branch`.

- [ ] **Step 4: Verify the Gateway came up**

From the main checkout, a couple of minutes after reconcile (DNS-01 needs a propagation round trip):

```bash
flux get kustomizations | grep network-public
kubectl get certificate -n network-public
kubectl get gateway -n network-public
kubectl get svc -n network-public cilium-gateway-external
kubectl get httproute -A
```

Expected: both Kustomizations Ready. Certificate `insights-fobiat-dev` `READY=True`. Gateway `external` showing Programmed. Service `cilium-gateway-external` with an external IP from the pool, which is the next free LAN address after the ones already allocated. `kubectl get httproute -A` shows the existing LAN routes and **zero** routes whose parent is `external`.

- [ ] **Step 5: Confirm nothing became resolvable**

```bash
dig +short insights.fobiat.dev
```

Expected: no answer, or an answer that has nothing to do with this cluster. If this resolves to a cluster address, stop and revert: something published a record, which is the one outcome this stage is built to prevent.

- [ ] **Step 6: Run the test green**

```bash
bash scripts/check-vap.sh; echo "exit $?"
```

Expected: all five cases PASS, exit 0. Case 4 flipping from FAIL to PASS is the proof that the namespace exception works, and it now uses a namespace that really exists rather than a hypothetical one.

- [ ] **Step 7: If anything failed, revert**

A straight revert. The only manual piece is a namespace that may sit in Terminating for a while. The LB IP releases itself, and the issued certificate needs no cleanup: the CT log entry is permanent and does not matter.

---

## Task 12: Create the Cloudflare tunnel and encrypt its credentials

Shape B. PR4, branch `cloudflared/deploy`, based on `gateway/external`. This is the only out-of-cluster side effect in the whole stage, and it happens before the PR is opened because the tunnel ID is an input to a manifest.

The tunnel-scoped Cloudflare API token is created manually in the dashboard, the same way as the other pending external credentials. It is used once, from the workstation, and **it never enters the cluster**. What the pod holds is the tunnel credentials JSON, which is an impersonation credential for the published hostnames and not a route inbound. Revoking access means deleting the tunnel, not rotating a token.

**Files:**
- Create: `kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml`

**Interfaces:**
- Consumes: branch `gateway/external` from Task 11.
- Produces: branch `cloudflared/deploy`. A Cloudflare tunnel named `home-ops` with `config_src: local`. A value **TUNNEL_ID**, the tunnel's UUID, which Task 13 substitutes into the ConfigMap's `tunnel:` field and Task 15 uses to check for a stray DNS record. An encrypted Secret named `cloudflared-credentials` in namespace `network` with a single key `credentials.json`, which Task 13's Deployment mounts at `/etc/cloudflared/creds`.

- [ ] **Step 1: Create the branch**

```bash
git checkout gateway/external
git checkout -b cloudflared/deploy
```

- [ ] **Step 2: Create the tunnel-scoped API token by hand**

In the Cloudflare dashboard, create an API token with the **Account: Cloudflare Tunnel: Edit** permission scoped to the account, and nothing else. This is deliberately a second token, separate from the DNS-01 solver token, so either can be revoked independently. Do not commit it, do not echo it into a shell history file, and do not put it in the cluster. Export it for this shell only:

```bash
read -rs CF_API_TOKEN && export CF_API_TOKEN
```

- [ ] **Step 3: Create the tunnel**

```bash
ACCOUNT_ID=$(curl -sf -H "Authorization: Bearer $CF_API_TOKEN" \
  https://api.cloudflare.com/client/v4/accounts | jq -r '.result[0].id')

TUNNEL_SECRET=$(openssl rand -base64 32)

RESP=$(curl -sf -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$(jq -n --arg s "$TUNNEL_SECRET" \
    '{name:"home-ops", config_src:"local", tunnel_secret:$s}')")

TUNNEL_ID=$(jq -r '.result.id' <<<"$RESP")
echo "TUNNEL_ID=$TUNNEL_ID"
```

Expected: a UUID. `config_src: local` is what keeps the entire ingress list in Git rather than in a dashboard, so an exposure change shows up in `flux-local diff` like any other change. Generating `tunnel_secret` locally rather than letting the API mint one means you hold every field of the credentials file without a second call.

Write `TUNNEL_ID` down. Task 13 needs it and Task 15 needs it.

- [ ] **Step 4: Build the credentials file**

```bash
jq -n --arg a "$ACCOUNT_ID" --arg t "$TUNNEL_ID" --arg s "$TUNNEL_SECRET" \
  '{AccountTag:$a, TunnelID:$t, TunnelSecret:$s}' > /tmp/cloudflared-credentials.json
```

- [ ] **Step 5: Write the plaintext Secret, then encrypt it in place**

```bash
mkdir -p kubernetes/apps/network/cloudflared/app
cat > kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflared-credentials
type: Opaque
stringData:
  credentials.json: |
$(sed 's/^/    /' /tmp/cloudflared-credentials.json)
EOF

task sops:encrypt -- kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml
shred -u /tmp/cloudflared-credentials.json
unset CF_API_TOKEN TUNNEL_SECRET
```

The `.sops.yaml` creation rule already matches `kubernetes/.*\.sops\.ya?ml` with `encrypted_regex: ^(data|stringData)$`, so no config change is needed.

- [ ] **Step 6: Prove it is actually encrypted**

```bash
grep -c "ENC\[AES256_GCM" kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml
grep -i "TunnelSecret\|AccountTag" kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml
```

Expected: the first prints at least 1. The second prints nothing. If any plaintext credential field is visible, do not commit: delete the file, revoke the tunnel, and start the task again. Verify the encryption itself, do not assume `.gitignore` caught anything.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml
git commit -m "feat(network): encrypted credentials for the cloudflared tunnel"
```

Do not run `task lint` expecting it to check this file: yamllint ignores `kubernetes/**/*.sops.yaml` and kubeconform is invoked with `-skip Secret`. Step 6 is the check that matters here.

---

## Task 13: The cloudflared Deployment and ConfigMap

Shape B. Still PR4, branch `cloudflared/deploy`.

Placement is `kubernetes/apps/network/cloudflared/`, not `network-public`. cloudflared is infrastructure of the same class as external-dns and the Gateway controller, keeping `network-public` free of anything except the Gateway and its routes preserves the one-`ls`-answers-what-is-public property, and it means cloudflared inherits PR1's default-deny in `network`, which is exactly the internet-facing pod the threat model worries about.

**Files:**
- Create: `kubernetes/apps/network/cloudflared/ks.yaml`
- Create: `kubernetes/apps/network/cloudflared/app/kustomization.yaml`
- Create: `kubernetes/apps/network/cloudflared/app/configmap.yaml`
- Create: `kubernetes/apps/network/cloudflared/app/deployment.yaml`
- Modify: `kubernetes/apps/network/kustomization.yaml`

**Interfaces:**
- Consumes: **TUNNEL_ID** from Task 12, and the Secret `cloudflared-credentials` with key `credentials.json` from the same task.
- Produces: Flux Kustomization named `network-cloudflared`, targetNamespace `network`, with SOPS decryption. A ConfigMap named `cloudflared-config` and a Deployment named `cloudflared`, two replicas, metrics on container port 2000. Task 14 adds port 2000 to the `allow-scraping` NetworkPolicy so that port is reachable from other namespaces.

- [ ] **Step 1: Confirm the image tag**

```bash
curl -sf https://api.github.com/repos/cloudflare/cloudflared/releases/latest | jq -r .tag_name
```

The spec pins `docker.io/cloudflare/cloudflared:2026.8.0`, which was current at drafting. If the command returns a newer tag, use that one verbatim in Step 3 and note the change in the PR body. Either way the tag is pinned, never `latest`, and Renovate owns it from here.

- [ ] **Step 2: Write the ConfigMap**

Create `kubernetes/apps/network/cloudflared/app/configmap.yaml`, substituting the real UUID from Task 12 for `<tunnel-id>`:

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
```

The ingress list is one entry, and it is a 404. That is the closed default: nothing is published, and Stage 4 adds the first real hostname above it. The `config.yaml` value is a string inside YAML, so neither yamllint nor kubeconform parses it. Read it once by eye before committing, per the embedded-config trap.

- [ ] **Step 3: Write the Deployment**

Create `kubernetes/apps/network/cloudflared/app/deployment.yaml`:

```yaml
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

Three things about this manifest that a reviewer will otherwise try to fix:

The Reloader annotation is load-bearing. The stated reason for two replicas is that a ConfigMap change rolls without dropping the tunnel, but a ConfigMap change alone triggers no rollout at all. That is the same shape as the Cilium ConfigMap trap: the value changes, nothing restarts, and the manifest looks correct. Reloader is already deployed cluster-wide, so this is one annotation.

There is **no anti-affinity, on purpose**. This is a raw Deployment with none baked in, unlike a chart, and a `requiredDuringScheduling` podAntiAffinity would leave the second replica Pending forever on one node.

Explicit requests are mandatory, not decoration. Talos SIGKILLs BestEffort cgroups first when the node runs out of memory, so an unset request is what takes the cluster down.

- [ ] **Step 4: Write the app kustomization**

Create `kubernetes/apps/network/cloudflared/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./cloudflared-credentials.sops.yaml
  - ./configmap.yaml
  - ./deployment.yaml
```

- [ ] **Step 5: Write the Flux Kustomization**

Create `kubernetes/apps/network/cloudflared/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: network-cloudflared
  namespace: flux-system
spec:
  targetNamespace: network
  dependsOn:
    - name: reloader
  commonMetadata:
    labels:
      app.kubernetes.io/name: network-cloudflared
  path: ./kubernetes/apps/network/cloudflared/app
  prune: true
  wait: true
  interval: 1h
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

The `decryption` block is required or the encrypted Secret never becomes a usable Secret. `dependsOn: reloader` is there because the annotation is inert without it, and an inert annotation is worse than an absent one: it looks like the rollout problem is solved.

- [ ] **Step 6: Wire it into the namespace index**

Edit `kubernetes/apps/network/kustomization.yaml` so it reads:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./certificates/ks.yaml
  - ./lb-ipam/ks.yaml
  - ./gateway/ks.yaml
  - ./external-dns/ks.yaml
  - ./netpol/ks.yaml
  - ./gateway-guard/ks.yaml
  - ./cloudflared/ks.yaml
```

- [ ] **Step 7: Re-check memory headroom, from the main checkout**

```bash
kubectl describe node talos-1 | grep -A8 "Allocated resources"
talosctl memory
```

Two replicas at 48Mi is 96Mi steady. `maxUnavailable: 0` with `maxSurge: 1` means three pods exist briefly on this single node, 144Mi at peak. Allocatable is 7307Mi and requests already sit around 3046Mi, so the working headroom is roughly 3.9GB, not the 16GB an older note claimed. Confirm there is room before merging rather than after.

- [ ] **Step 8: Run the lint gate**

Run: `task lint`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add kubernetes/apps/network/cloudflared kubernetes/apps/network/kustomization.yaml
git commit -m "feat(network): cloudflared, with an ingress list of exactly one 404"
```

---

## Task 14: Add port 2000 to the `network` scrape rule

Still PR4, branch `cloudflared/deploy`. This edit belongs to PR4 and to no other PR: it lands in the same PR that adds cloudflared, so the allowance stays ahead of any future ServiceMonitor rather than behind it, even though Stage 3 ships no ServiceMonitor for cloudflared.

**Files:**
- Modify: `kubernetes/apps/network/netpol/app/networkpolicy.yaml`

**Interfaces:**
- Consumes: the NetworkPolicy named `allow-scraping` in namespace `network`, created in Task 1 at `kubernetes/apps/network/netpol/app/networkpolicy.yaml`. The container port 2000 declared by the cloudflared Deployment in Task 13.
- Produces: `allow-scraping` permitting TCP 7979, 8080 and 2000 from any namespace. Nothing later in this plan modifies this object again.

- [ ] **Step 1: Add the port**

Edit `kubernetes/apps/network/netpol/app/networkpolicy.yaml`. Only the second document changes, and only its `ports` list. After the edit the second document reads:

```yaml
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
        - port: 2000
          protocol: TCP
```

Leave the `allow-egress` document above it untouched.

- [ ] **Step 2: Confirm nothing else in the file changed**

Run: `git diff kubernetes/apps/network/netpol/app/networkpolicy.yaml`
Expected: exactly two added lines, `- port: 2000` and `  protocol: TCP`. Anything else is a mistake.

- [ ] **Step 3: Run the lint gate**

Run: `task lint`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/network/netpol/app/networkpolicy.yaml
git commit -m "feat(network): allow scraping cloudflared's metrics port"
```

---

## Task 15: Open, merge and verify PR4

Shape B. The only PR in this stage with a real out-of-cluster side effect, and the only one whose rollback needs manual cleanup.

**Files:** none created or modified.

**Interfaces:**
- Consumes: branch `cloudflared/deploy` carrying Tasks 12 to 14, and **TUNNEL_ID** from Task 12.
- Produces: `cloudflared/deploy` merged into `main`. Two cloudflared pods Running, the tunnel Healthy with two connectors and zero hostnames. PR5 branches from `cloudflared/deploy`, so do not delete that branch yet.

- [ ] **Step 1: Run the diff gate and scan the diff for secrets**

```bash
task diff
git diff origin/main...HEAD -- kubernetes/apps/network/cloudflared/app/cloudflared-credentials.sops.yaml
```

Expected: `task diff` shows the ConfigMap, Deployment, Secret and the `network-cloudflared` wrapper, plus the one-port change to `allow-scraping`. The second command shows only ciphertext. Read it, do not assume.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin cloudflared/deploy
gh pr create --base gateway/external --title "feat: cloudflared, with an empty ingress list" --body-file -
```

The body must state: stacked on PR3, part 4 of 5; the tunnel already exists in the Cloudflare account because its ID is an input to the ConfigMap; the credentials JSON in the branch is an impersonation credential for published hostnames and not a route inbound, because the tunnel is outbound only; the anti-affinity is absent on purpose and must not be "fixed"; the egress this needs is outbound UDP 7844 to the Cloudflare edge with TCP 7844 and 443 as fallback, which open egress in `network` covers today; and the headroom figure from Task 13 Step 7.

- [ ] **Step 3: Merge after PR3 is in**

Confirm PR3 has merged and this PR has retargeted to `main`. Run `gh pr checks --watch`, then `gh pr merge --squash` without `--delete-branch`.

- [ ] **Step 4: Verify the pods and the tunnel**

From the main checkout:

```bash
flux get kustomizations | grep cloudflared
kubectl get pods -n network -l app.kubernetes.io/name=cloudflared
kubectl logs -n network -l app.kubernetes.io/name=cloudflared --tail=20
```

Expected: Kustomization Ready, both replicas Running and Ready, and logs showing registered connections to the Cloudflare edge with no credential errors.

- [ ] **Step 5: Verify in the Cloudflare dashboard**

Expected: the `home-ops` tunnel shows **Healthy**, with two connectors, and **zero hostnames configured**. Zero hostnames is the check that matters. A tunnel with connectors and no hostnames routes nothing.

- [ ] **Step 6: Confirm no DNS record points at the tunnel**

```bash
dig +short insights.fobiat.dev
dig +short <tunnel-id>.cfargotunnel.com
```

Substituting the real UUID. Expected: nothing anywhere in the `fobiat.dev` zone resolves to `<tunnel-id>.cfargotunnel.com`. Check the Cloudflare DNS tab for the zone as well as the `dig` output, since a proxied record can behave differently from an unproxied one.

- [ ] **Step 7: Confirm the stage's four done-means conditions**

```bash
ls kubernetes/apps/network-public/routes/app/
```

Expected: only `kustomization.yaml`, no routes. Together with steps 5 and 6, and one more pass over `grafana.lab.fobiat.dev`, `status.lab.fobiat.dev`, Homepage and the docs proxy in a browser, that is all four conditions: tunnel Healthy with zero hostnames, no public DNS record resolving into the cluster, no routes listed, every LAN service loading exactly as before.

- [ ] **Step 8: If anything failed, revert plus manual cleanup**

A revert removes the Deployment, ConfigMap and Secret, but the tunnel keeps existing in the Cloudflare account:

```bash
curl -sf -X DELETE \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

with the same tunnel-scoped token. A tunnel with no connectors is inert and routes nothing, so this is hygiene rather than urgency, but skipping it means the next attempt collides with an existing name.

---

## Task 16: ADR 0013

PR5, branch `docs`, based on `cloudflared/deploy`. Its gate is `task lint`, which includes `task docs:build` and therefore catches a broken mkdocs nav entry. The two `flux-diff` jobs will not fire, because they are path-filtered to `kubernetes/**`. That is expected and does not block merge, since `lint` is the only required check.

**Files:**
- Create: `docs/adr/0013-external-exposure-guardrails.md`
- Modify: `mkdocs.yml`
- Modify: `docs/adr/README.md`

**Interfaces:**
- Consumes: branch `cloudflared/deploy` from Task 15. The object names `allow-gateway-ingress`, `external-route-namespace`, `external-gateway-listeners`, the Gateway name `external` and the namespace `network-public`, all as created in Tasks 2, 3, 6 and 8. The CiliumNetworkPolicy comments written in Tasks 2 and 3 cite this ADR by number, so 0013 must be the number used.
- Produces: branch `docs`. `docs/adr/0013-external-exposure-guardrails.md`, reachable from the mkdocs nav and from the ADR index table.

- [ ] **Step 1: Create the branch**

```bash
git checkout cloudflared/deploy
git checkout -b docs
```

- [ ] **Step 2: Write the ADR**

Create `docs/adr/0013-external-exposure-guardrails.md`, following the shape of `docs/adr/0012-data-disk-never-mounted.md`: a `# 0013. <title>` heading, `Status: Accepted, 2026-08-16`, then `## Context`, `## Decision`, `## Consequences`, `## Alternatives`. Title it "External exposure guardrails, and the four decisions behind them". Read 0012 first for the voice: plain, specific, first-person about what was measured.

Four decisions it must record, each with the reasoning attached rather than only the outcome:

1. **The VAP matches the literal name `external`.** Renaming the Gateway silently disarms all three validations. And the `XListenerSet` CRD exists on this cluster, which could let another namespace attach listeners that route around the exact-FQDN check; that is inert unless the Gateway sets `spec.allowedListeners`, so the rule is that this field is never set on the `external` Gateway, and the manifest carries a comment saying so because the danger lives in a field's absence.
2. **The CiliumNetworkPolicy exception to rule 11.** Rule 11 says one way to do each thing, and this is a second policy dialect, so it needs a documented reason. The reason is that Gateway-proxied traffic reaches backends as `reserved:ingress`, an identity that is not a pod, not a namespace, and has no stable address, so no `podSelector`, `namespaceSelector` or `ipBlock` can name it. This was confirmed by Hubble flow capture rather than assumed. Two alternatives were considered and rejected: writing every policy as a CiliumNetworkPolicy, which locks three namespaces to Cilium for no gain, and pinning an `ipBlock` to the current `reserved:ingress` address, which breaks silently after re-IPAM and reads as a magic number to the next person.
3. **The `network-public` empty-routes convention.** `ls kubernetes/apps/network-public/routes/app/` is the complete answer to "what is public?", which is why the directory ships empty in Stage 3 rather than appearing in Stage 4. Record which branch of Task 9 Step 4 was taken, meaning whether `routes/ks.yaml` shipped or was deferred.
4. **cloudflared's credential model.** The tunnel-scoped API token is created by hand, used once from the workstation, and never enters the cluster. What the pod holds is the tunnel credentials JSON, an impersonation credential for the published hostnames rather than a route inbound. Revoking access means deleting the tunnel, not rotating a token, and keeping this token separate from the DNS-01 solver token is what makes either revocable independently.

The Consequences section must also state, honestly, the caveat that makes "monitoring is isolated" the wrong summary on its own: a compromised pod in `default` cannot reach `kube-prometheus-stack-grafana:3000` directly, but it can reach `https://grafana.lab.fobiat.dev` through the Gateway, arriving back as `reserved:ingress`, which `allow-gateway-ingress` permits. The Gateway is a bypass for any service that has a route. That is acceptable, since those services are LAN-reachable from any device on the network anyway.

It must also record what this stage does not close: egress is unrestricted everywhere in scope, so nothing here constrains exfiltration, only lateral movement into the three covered namespaces. The API server stays reachable from every pod, controlled today only by RBAC. `system-backup` and `volsync-system` stay unprotected, and both hold restic credentials while volsync's controller can read every backed-up PVC, so they are the next namespaces to cover; they were omitted for scope discipline rather than because the risk was assessed as low.

Finally, record the two additions this stage made to the spec's verification, so they are on the record rather than folklore: `check-vap.sh` case 3 (the existing `internal` Gateway must be allowed, which is the only case that evaluates `external-gateway-listeners` at all) and case 5 (a wildcard listener on a Gateway named `external` must be denied, the negative control for the same policy).

- [ ] **Step 3: Add the mkdocs nav entry**

Edit `mkdocs.yml`, appending one line to the `Decisions` block, immediately after the 0012 line:

```yaml
      - 0013 External exposure guardrails: adr/0013-external-exposure-guardrails.md
```

- [ ] **Step 4: Add the ADR index row**

Edit `docs/adr/README.md`, appending one row to the table, immediately after the 0012 row:

```markdown
| [0013](0013-external-exposure-guardrails.md) | External exposure guardrails, and the four decisions behind them | Accepted |
```

- [ ] **Step 5: Run the lint gate**

Run: `task lint`
Expected: PASS, including `task docs:build`. `mkdocs build --strict` fails on a link to a missing page, so if the ADR references files that do not exist yet, write them as plain code spans rather than Markdown links.

- [ ] **Step 6: Commit**

```bash
git add docs/adr/0013-external-exposure-guardrails.md docs/adr/README.md mkdocs.yml
git commit -m "docs: ADR 0013, the guardrails that keep Stage 3 from publishing anything"
```

---

## Task 17: `docs/exposure.md`, then merge PR5

Still PR5, branch `docs`.

**Files:**
- Create: `docs/exposure.md`
- Modify: `mkdocs.yml`

**Interfaces:**
- Consumes: branch `docs` from Task 16 and ADR 0013, which this page links to. Object and path names from Tasks 1 to 14.
- Produces: `docs/exposure.md` in the nav, and `docs` merged into `main`. Task 18 then commits to a different repository.

- [ ] **Step 1: Write the page**

Create `docs/exposure.md`, titled "Exposure". Short, and aimed at someone who wants to publish something and needs to know what stops them. Four sections:

**What is public.** As of Stage 3: nothing. The `external` Gateway exists in `network-public` with one listener for `insights.fobiat.dev` and zero routes attached, and the cloudflared tunnel is Healthy with an ingress list of exactly one 404. The complete answer to "what is public?" is `ls kubernetes/apps/network-public/routes/app/`, and that is the answer to keep using rather than a list maintained in this page, because a list in prose drifts and a directory listing cannot.

**How something becomes public.** Four objects in three places, deliberately: an HTTPRoute in `kubernetes/apps/network-public/routes/app/`, a `ReferenceGrant` in the app's own namespace so the backend is resolvable, which is the app's own consent; a listener on the `external` Gateway carrying that exact FQDN; and an entry in cloudflared's ingress list. Missing any one of them fails safe, and name each failure: a route from the wrong namespace gets `NotAllowedByListeners`, a wrong hostname gets `NoMatchingListenerHostname`, a missing ReferenceGrant gives a 500 rather than a route somewhere unintended, and a missing tunnel entry gets the closing 404.

**What stops it happening by accident.** The `external-route-namespace` policy denies a `parentRef` named `external` from any namespace except `network-public`, including a hand `kubectl apply` that Flux would only revert an hour later. The `external-gateway-listeners` policy denies a wildcard or absent listener hostname and denies `allowedRoutes.namespaces.from` being anything other than `Same`. `scripts/check-vap.sh` proves both, and it is re-runnable after the Proxmox rebuild. And external-dns cannot publish any of this even if the rest failed: it sources records from HTTPRoutes only, its provider is AdGuard on the LAN rather than Cloudflare, and its `domainFilters` suffix of `lab.fobiat.dev` does not match `insights.fobiat.dev`.

**What this does not protect.** Egress is unrestricted, so this constrains lateral movement rather than exfiltration. The Gateway is a bypass for any LAN service that already has a route. `system-backup` and `volsync-system` have no NetworkPolicy yet.

Link to `adr/0013-external-exposure-guardrails.md` for the reasoning; do not restate its argument here.

- [ ] **Step 2: Add the mkdocs nav entry**

Edit `mkdocs.yml`, inserting one line into the top-level `nav`, after the `tuppr` line and before `Runbooks`:

```yaml
  - Exposure: exposure.md
```

- [ ] **Step 3: Run the lint gate**

Run: `task lint`
Expected: PASS, `mkdocs build --strict` included. A typo in the ADR link fails here rather than on the published site.

- [ ] **Step 4: Commit**

```bash
git add docs/exposure.md mkdocs.yml
git commit -m "docs: what is public, and what it takes to publish something"
```

- [ ] **Step 5: Push, open and merge the PR**

```bash
git push -u origin docs
gh pr create --base cloudflared/deploy --title "docs: ADR 0013 and the exposure page" --body-file -
```

The body must state: stacked on PR4, part 5 of 5; the two `flux-diff` jobs will not fire because they are path-filtered to `kubernetes/**`, which is expected and does not block merge since `lint` is the only required check; and that the matching edits to `AGENTS.md` and `PHASE-TWO.md` are a separate commit in the `claude-configs` repository, because both files are gitignored here.

Confirm PR4 has merged and this PR has retargeted to `main`. Merge with `gh pr merge --squash`.

- [ ] **Step 6: Now delete the stack's branches**

Every PR is merged, so nothing is left targeting an intermediate branch:

```bash
git push origin --delete netpol/stage3-baseline gateway/external-vap gateway/external cloudflared/deploy docs
```

- [ ] **Step 7: Confirm the published site built**

Check the `docs` workflow run on `main`. Expected: green, with `exposure.md` and the 0013 ADR both reachable in the nav on the published site.

---

## Task 18: The claude-configs commit

**This is a different repository and a separate commit.** `~/Projects/claude-configs/home-ops/AGENTS.md` and `PHASE-TWO.md` are gitignored inside home-ops, because the real copies live in claude-configs. A home-ops PR that only edited those two files would be an empty PR, which is why PR5 carries the ADR and the docs page instead. Do not add any of these files to a home-ops commit, and do not fold this work into PR5.

**Files:**
- Modify: `~/Projects/claude-configs/home-ops/AGENTS.md`
- Modify: `~/Projects/claude-configs/home-ops/PHASE-TWO.md`
- Modify: `~/Projects/claude-configs/home-ops/tasks.md`

**Interfaces:**
- Consumes: everything merged in Tasks 4, 7, 11, 15 and 17. The findings recorded in ADR 0013 from Task 16.
- Produces: one commit in the `claude-configs` repository. Nothing downstream in this plan consumes it; this is where Stage 3 ends.

- [ ] **Step 1: Reword the Domain section of `AGENTS.md`**

In `~/Projects/claude-configs/home-ops/AGENTS.md`, replace "The apex is the personal website and must stay uncoupled from the cluster" with wording that makes the distinction explicit: uncoupled at the application layer, not at the DNS control plane. Cloudflare cannot scope a DNS-edit token below zone level, so the DNS-01 solver token can rewrite the apex. Nothing the cluster serves is reachable through the apex, but a compromised cluster could still edit DNS and take the personal site down. The mitigation is the second, tunnel-scoped token, so either can be revoked independently; a narrower DNS token is not an option Cloudflare offers. Add that public DNS records are upsert-only, so nothing in the cluster can issue a delete against the zone that serves the personal site.

- [ ] **Step 2: Add two traps to `AGENTS.md`**

Append both to the "Traps worth remembering" list, in the same voice as its existing entries, both first-hand:

**Gateway-proxied traffic arrives as `reserved:ingress`, and no standard NetworkPolicy can name it.** Confirmed by Hubble flow capture: every request through the `internal` Gateway reaches Grafana, Gatus, Homepage and docs-proxy carrying Cilium's `reserved:ingress` identity, which was `10.244.0.71/32` when measured. That address is allocated from the node's pod CIDR and will not survive a node rebuild, so an `ipBlock` must never be pinned to it. Applying the flux-system `allow-egress` shape verbatim to `default` and `monitoring` breaks LAN access to all four services at once. The fix is one `CiliumNetworkPolicy` named `allow-gateway-ingress` per routed namespace, using `fromEntities: [ingress]`. Related: `cilium-envoy` runs as its own `hostNetwork: true` DaemonSet in `kube-system` rather than embedded in the agent, which is both why there is no proxy pod in `network` and why the traffic carries a reserved identity rather than a pod identity.

**`reserved:host` today, `reserved:remote-node` on a multi-node cluster.** The API server calls the `kube-prometheus-stack-admission` webhook at `monitoring/kube-prometheus-stack-operator:443`. On this single node the API server is host-network on the same machine, so it arrives as `reserved:host`, covered by Cilium's default `allow-localhost: auto`, and the default-deny policy in `monitoring` does not block it. On a multi-node cluster it would arrive as `reserved:remote-node` and be denied. The failure mode is a PrometheusRule edit silently rejected, which is invisible until it happens, so re-test this on the Proxmox rebuild with `kubectl apply --dry-run=server` against an existing PrometheusRule.

- [ ] **Step 3: Update Stage 3 in `PHASE-TWO.md`**

Add a checklist to the Stage 3 section, one line per PR, and a done-means line matching the four conditions:

```markdown
**Checklist.**

- [x] PR1 `netpol/stage3-baseline`: default-deny in `network`, `monitoring`, `default`
- [x] PR2 `gateway/external-vap`: two ValidatingAdmissionPolicy objects, their bindings, `scripts/check-vap.sh`
- [x] PR3 `gateway/external`: `network-public` namespace, the `external` Gateway, its Certificate
- [x] PR4 `cloudflared/deploy`: cloudflared Deployment, ConfigMap, tunnel credentials, port 2000 on the scrape rule
- [x] PR5 `docs`: ADR 0013 and `docs/exposure.md`

**Done means** the tunnel is Healthy in the Cloudflare dashboard with zero
hostnames configured, no public DNS record resolves to anything in the cluster,
`ls kubernetes/apps/network-public/routes/app/` lists no routes, and every LAN
service still loads exactly as before. Three of those four are statements about
absence, which is the point.
```

Then record the two corrections found while building the stage. First, external-dns runs the AdGuard webhook provider against a Pi on the LAN with `domainFilters: [lab.fobiat.dev]` and `sources: [gateway-httproute]`, so it does not talk to Cloudflare at all; that is a fifth defense layer worth naming, and it is a second independent reason nothing became public in Stage 3 rather than a happy accident. Second, the VAP now enforces, rather than merely assuming, that `allowedRoutes.namespaces.from: Same` stays set on the `external` Gateway, so layer 1 of the four-layer description is a guarantee instead of a convention.

- [ ] **Step 4: Update `tasks.md`**

Move Stage 3 to Done. Add four items to Backlog, each with its reasoning attached rather than as a bare line:

- Extend default-deny to `system-backup` and `volsync-system`. Both hold restic credentials, and volsync's controller can read every backed-up PVC. They were omitted from Stage 3 for scope discipline, not because the risk was assessed as low.
- Derive a real egress allow-list from `hubble observe --namespace network --verdict FORWARDED` once cloudflared has been running long enough to have shown its full destination set. The known floor is outbound UDP 7844 to the Cloudflare edge with TCP 7844 and 443 as fallback, plus the LAN AdGuard API and the Kubernetes API.
- The API-server pivot stays open and RBAC-controlled until egress rules exist. Prometheus, Alloy, external-dns and Homepage are legitimate API-server users mixed in with everything else, which is why closing it needs egress rules rather than ingress ones.
- Re-run `scripts/check-vap.sh` and the `reserved:host` webhook check after the Proxmox rebuild, since both properties are single-node artefacts.

- [ ] **Step 5: Commit in the claude-configs repository**

```bash
cd ~/Projects/claude-configs
git add home-ops/AGENTS.md home-ops/PHASE-TWO.md home-ops/tasks.md
git commit -m "home-ops: record Stage 3, its two traps, and the DNS control plane correction"
```

Committing here is routine. Pushing needs confirmation, same as any other push.

- [ ] **Step 6: Confirm nothing leaked into home-ops**

```bash
cd ~/Projects/home-ops
git status --porcelain
```

Expected: clean, with no `AGENTS.md`, `PHASE-TWO.md` or `tasks.md` showing as untracked or modified. If any of them appear, they are gitignored and should stay that way; check `.gitignore` rather than committing them.

---

## Self-review record

Run after the plan was written, against the spec with fresh eyes.

**1. Spec coverage.** Every section of the spec maps to a task. PR1's three namespaces are Tasks 1 to 3 and its seven-step verification is Task 4. PR2 is Tasks 5 to 7, PR3 is Tasks 8 to 11, PR4 is Tasks 12 to 15, PR5 is Tasks 16 to 18. The spec's four verified findings appear where they change behaviour: finding A in Tasks 2 and 3 and in Task 18's trap, finding B in Task 1's preamble, finding C in Task 11's PR body and Task 18's correction, finding D in Task 4 Step 7 and Task 18's second trap. The spec's `mkdocs` housekeeping note is already satisfied in the repo: `mkdocs.yml` carries `exclude_docs: superpowers/`, so no task adds it.

**2. Issues found and fixed inline.**

- The spec's two `check-vap.sh` controls never submit a Gateway, so `external-gateway-listeners` would have shipped with its CEL unproven, against a `failurePolicy: Fail` that blocks every Gateway write cluster-wide on an evaluation error. Fixed by adding case 3 in Task 5 and case 5 in Task 10, both flagged as additions in a dedicated section, in the PR bodies, and in ADR 0013's consequences.
- The spec numbers PR3's new check "the third case"; with the addition above it is the fourth. Task 10 says so explicitly so an implementer reading both documents is not confused.
- Task 10 case 5 passes on its first run rather than failing, because the policy it tests shipped in PR2. That would read as a broken red phase, so Task 10 Step 3 states the expected result per case and explains why case 5 is already green.
- The spec's `expect_allowed` control takes a file path, but PR3's new positive control is an inline heredoc. Fixed by defining `expect_allowed_inline` in Task 10 Step 1 rather than leaving the implementer to improvise.
- `<tunnel-id>` is the one value the spec cannot fill in. Rather than leaving a placeholder, Task 12 produces it as a named output (**TUNNEL_ID**) with the exact commands, and Tasks 13 and 15 declare it as a consumed input.

**3. Type and name consistency.** Checked across every task: Flux Kustomization names `network-netpol`, `monitoring-netpol`, `default-netpol`, `network-gateway-guard`, `network-public-gateway`, `network-public-routes`, `network-cloudflared`. Policy object names `allow-egress`, `allow-scraping`, `allow-gateway-ingress`, `external-route-namespace`, `external-gateway-listeners`. Gateway `external` with listener `insights`, Certificate `insights-fobiat-dev` producing Secret `insights-fobiat-dev-tls`, Service `cilium-gateway-external`. ConfigMap `cloudflared-config`, Secret `cloudflared-credentials` with key `credentials.json`, Deployment `cloudflared` with label `app.kubernetes.io/name: cloudflared`. Shell helpers `expect_denied`, `expect_allowed`, `expect_allowed_inline` and the `fail` accumulator. The denial message asserted by `check-vap.sh` case 1 is checked against the manifest by an explicit `grep -F` step (Task 6 Step 5) rather than by eye. `allow-scraping` is created in Task 1 and modified only in Task 14, which is inside PR4 as the spec requires and appears nowhere else.
