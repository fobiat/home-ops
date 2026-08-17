# 0015. actions-runner-controller for self-hosted GitHub Actions runners

Status: Accepted, 2026-08-17

## Context

Public GitHub repositories get unlimited Actions minutes; private ones draw on a
2,000-minute/month free tier and are capped at two hosted cores. `home-ops` itself is
public and saves nothing here. `AppleJackRP-sandbox` is private and real workflow time on
it, so it is the actual reason phase three's runner work exists at all, named directly in
`PLAN.md`.

Three shapes were on the table.

**Status quo, hosted runners.** No new component, no new credential. Costs real money or
a hard minutes ceiling on `AppleJackRP-sandbox`, and stays capped at two cores regardless.

**Forgejo Actions.** Both `bjw-s-labs/home-ops` and `deedee-ops/home-ops` moved CI to a
self-hosted Forgejo entirely, sidestepping GitHub minutes as a concept. That means
self-hosting Git, a materially bigger change than adding a runner. Noted in `PLAN.md`,
not chosen.

**actions-runner-controller (ARC)**, the option chosen: a controller plus per-repo
`AutoscalingRunnerSet` custom resources, ephemeral runner pods scaled from zero. This is
the current supported ARC architecture; the older `RunnerDeployment` CRDs are
deprecated.

## Decision

Ship the controller live (`kubernetes/apps/actions-runner-system/controller/`) and one
runner scale set for `AppleJackRP-sandbox`
(`kubernetes/apps/actions-runner-system/applejackrp-sandbox/`), shipped
`spec.suspend: true` until a real GitHub App credential exists. Adding a second private
repo later means copying the `applejackrp-sandbox/` app directory with a new
`githubConfigUrl`, secret name and scale-set name, not a new controller.

### Auth: GitHub App, not a PAT

A PAT is user-scoped and expires, taking every runner down with it when it does (the
exact failure `PLAN.md` calls out). A GitHub App installed on just this one repository is
scoped to it, does not expire, and its private key can be rotated without touching the
runner set's config. Chart-side this uses the "pre-defined secret" form
(`githubConfigSecret: <secret-name>`), not the chart's inline GitHub App values, because
the inline form would put the private key directly in the HelmRelease's `values:` block,
outside this repo's one SOPS-and-age secrets mechanism (ADR 0003, AGENTS.md rule 11).

Required GitHub App permissions, confirmed against `actions/actions-runner-controller`'s
own `authenticating-to-the-github-api.md` for repository (not organisation) runners:
Actions (read), Administration (read/write), Metadata (read). No organisation
permissions and no webhook subscription, since this does not use webhook-driven scaling.

### Container mode: kubernetes, not dind

Talos ships no Docker daemon and blocks workload kernel module loading, ruling out a
privileged DinD sidecar as anything but a last resort. `containerMode.type: kubernetes`
runs each workflow step as its own pod via ARC's Kubernetes hooks, no Docker socket
anywhere in the namespace. The trade-off, and the reason this still needs the guardrail
below: those per-step pods come from whatever (or nothing) the workflow YAML declares
for `resources:`, not from anything this repo controls directly.

### The guardrail is a LimitRange, not just a ResourceQuota

`PLAN.md`'s stated risk is a runaway matrix build taking the API server down with it.
kubernetesModeWorkVolumeClaim's per-step pods make a bare ResourceQuota insufficient on
its own: a ResourceQuota constrains totals, but a pod with no `resources:` block at all
is invisible to it, an unbounded step schedules exactly the same as a bounded one, right
up until the node runs out of room. `kubernetes/apps/actions-runner-system/controller/app/limitrange.yaml`
gives every container in the namespace a default request/limit and, more importantly, a
`max` (1 core / 1Gi) that applies even to steps that do declare their own `resources:`.
`resourcequota.yaml` in the same directory is the namespace-wide backstop on top of that:
requests capped at 1 core / 2Gi, limits at 2 cores / 4Gi. On a four-core node this leaves
at least half the machine for the platform regardless of what CI is doing, matching
AGENTS.md rule 7. A build that would exceed the quota does not take anything down; its
pod simply stays `Pending` until room frees up.

`maxRunners: 2`, per `PLAN.md`'s explicit "start at 2."

### Suspended until the credential exists

The GitHub App does not exist yet, and creating one, generating its private key and
installing it on the repo are all steps only Kyle can do (same shape as the R2 bucket,
healthchecks.io check and Discord webhook before it). `helmrelease.yaml` ships fully
wired, `spec.suspend: true`, alongside
`applejackrp-sandbox/app/github-app.PLACEHOLDER.yaml`, which spells out the exact `sops`
encryption step, the same pattern ADR 0009 used for the etcd and machine-config backup
credentials and the alertmanager Discord webhook. `docs/runbooks/actions-runner-controller.md`
has the full walkthrough, including the GitHub App creation steps themselves.

### Not yet proven on Talos

AGENTS.md rule 8 says manifests get proven on the throwaway Talos-in-Docker cluster
first. That is only partly possible here: the controller and its guardrails can be
validated there, but `containerMode: kubernetes`'s actual per-step pod behaviour needs a
real GitHub App and a real workflow run to observe, which the throwaway cluster cannot
provide without its own scratch repo and App installation. Treat the first real workflow
run against this scale set as the point this gets proven, not this PR.

## Consequences

Good: `AppleJackRP-sandbox` gets runners with more than two cores and no minutes
ceiling, on a credential that is scoped to one repository and does not expire. The
resource guardrails are namespace-wide, so the next private repo's scale set inherits
them automatically rather than needing its own copy.

Bad: two deliberate, manual steps sit between this PR and a working runner: the GitHub
App has to be created and installed by hand, and the first real workflow run is the only
way to confirm `containerMode: kubernetes` behaves as documented on this specific node.
Until both happen, `applejackrp-sandbox-runners` is a suspended HelmRelease doing
nothing, the same shape ADR 0010 accepted for tuppr's controller.
