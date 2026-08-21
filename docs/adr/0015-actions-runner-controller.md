# 0015. actions-runner-controller for self-hosted GitHub Actions runners

Status: Accepted, 2026-08-17

## Context

Public GitHub repositories get unlimited Actions minutes; private ones draw on a
2,000-minute/month free tier and are capped at two hosted cores. `home-ops` itself is
public and saves nothing here. `AppleJackRP-sandbox` is private and real workflow time on
it, so it is the actual reason phase three's runner work exists at all, named directly in
`PLAN.md`. Kyle's call on 2026-08-17 extended the scope to every private repo with a real
CI pipeline today, not just the one `PLAN.md` named: `Rivet` and `rivet-workstation` (both
Rust, cargo build/test/clippy) and `cairn` (TypeScript, its own `ci.yml`) join
`AppleJackRP-sandbox`. Private repos without an existing pipeline (`agents-configs`,
`blog`, `random-things`, `openDVS`, `Ohmic-Labs`) were deliberately left out; a repo with
no CI today gains nothing from a faster runner.

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

Ship the controller live (`kubernetes/apps/actions-runner-system/controller/`) and four
runner scale sets, one per repo (`applejackrp-sandbox/`, `rivet/`,
`rivet-workstation/`, `cairn/`), each shipped `spec.suspend: true` until a real GitHub App
credential exists. Adding a fifth private repo later means copying one of these app
directories with a new `githubConfigUrl`, `OCIRepository`/`HelmRelease` name and `ks.yaml`
entry, not a new controller and not necessarily a new App (see below).

### Auth: one GitHub App, installed on all four repos, not a PAT

A PAT is user-scoped and expires, taking every runner down with it when it does (the
exact failure `PLAN.md` calls out). A GitHub App does not expire and its private key can
be rotated without touching any runner set's config.

**One App shared across all four repos, not four separate Apps.** A GitHub App
installed with "Only select repositories" covers every repo chosen under one
Installation ID, so one App ID / Installation ID / private key triple works for all
four `githubConfigSecret` references. The alternative, a separate App per repo, gives
each repo its own blast radius if a credential leaks, at the cost of four App
registrations, four private keys and four rotation schedules to track instead of one.
For a single-operator homelab that overhead buys little: rule 12 (prefer boring) and the
same reasoning ADR 0010 gave for tuppr's `os:admin` credential (concentrating access in
one place a person already has to trust, rather than multiplying credentials for their
own sake) apply here too. The shared secret lives once, in
`controller/app/github-app.PLACEHOLDER.yaml`, not duplicated per repo.

Chart-side this uses the "pre-defined secret" form (`githubConfigSecret: <secret-name>`),
not the chart's inline GitHub App values, because the inline form would put the private
key directly in the HelmRelease's `values:` block, outside this repo's one SOPS-and-age
secrets mechanism (ADR 0003, AGENTS.md rule 11).

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
requests capped at 1 core / 2Gi, limits at 1500m / 4Gi. On a four-core node that leaves
well over half the machine for the platform regardless of what CI is doing, matching
AGENTS.md rule 7. A build that would exceed the quota does not take anything down; its
pod simply stays `Pending` until room frees up. The limits figure started at 2 cores and
was cut on 2026-08-17; the addendum below has the arithmetic and the reason.

This quota is deliberately namespace-wide rather than per-scale-set, which matters now
that there are four. `maxRunners: 1` on each of the four `AutoscalingRunnerSet`s is a
local, per-repo cap; nothing coordinates between them, so in principle all four could
try to scale at once. The shared quota is what actually stops that from mattering:
whichever pods land first get the room, the rest queue as `Pending` rather than the node
seeing four repos' worth of unbounded concurrent builds. This started at `maxRunners: 2`,
per `PLAN.md`'s explicit "start at 2," and was cut to 1 on 2026-08-17 once each job
turned out to cost a pair of pods.

### Suspended until the credential exists

The GitHub App does not exist yet, and creating one, generating its private key and
installing it on all four repos are all steps only Kyle can do (same shape as the R2
bucket, healthchecks.io check and Discord webhook before it). Each `helmrelease.yaml`
ships fully wired, `spec.suspend: true`, alongside
`controller/app/github-app.PLACEHOLDER.yaml`, which spells out the exact `sops`
encryption step, the same pattern ADR 0009 used for the etcd and machine-config backup
credentials and the alertmanager Discord webhook. `docs/runbooks/actions-runner-controller.md`
has the full walkthrough, including the GitHub App creation steps themselves. The four
scale sets can be unsuspended independently once the shared secret exists; nothing
requires flipping all four at once.

### Not yet proven on Talos

AGENTS.md rule 8 says manifests get proven on the throwaway Talos-in-Docker cluster
first. That is only partly possible here: the controller and its guardrails can be
validated there, but `containerMode: kubernetes`'s actual per-step pod behaviour needs a
real GitHub App and a real workflow run to observe, which the throwaway cluster cannot
provide without its own scratch repo and App installation. Treat the first real workflow
run against this scale set as the point this gets proven, not this PR.

## Consequences

Good: `AppleJackRP-sandbox`, `Rivet`, `rivet-workstation` and `cairn` all get runners
with more than two cores and no minutes ceiling, on one credential that does not expire.
The resource guardrails are namespace-wide, so the next private repo's scale set inherits
them automatically rather than needing its own copy, and one App install covers a fifth
repo too if it is added to the same install rather than needing a new one.

Bad: two deliberate, manual steps sit between this PR and a working runner: the GitHub
App has to be created and installed on all four repos by hand, and the first real
workflow run on each is the only way to confirm `containerMode: kubernetes` behaves as
documented on this specific node. Until both happen, all four scale sets are suspended
HelmReleases doing nothing, the same shape ADR 0010 accepted for tuppr's controller. The
shared App is also a shared blast radius: a leaked key gives Administration write access
to all four repos at once, not just one, the trade-off named above.

## Addendum, 2026-08-17: proven live, twice, both times not the way this ADR assumed

The first real workflow runs (the point this document said would prove
`containerMode: kubernetes`) surfaced two things this ADR got wrong, not just unproven:

**A job with no `container:` is refused outright, not run on the runner's own
filesystem.** `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER` is set wherever `containerMode:
kubernetes` is, and a bare job errors immediately ("Jobs without a job container are
forbidden on this runner"). Every workflow targeting one of these scale sets needs an
explicit `container:` naming an image with whatever the job needs.

**Each job costs a *pair* of pods, not one.** The runner control pod (this document's
`template.spec.containers[name=runner]`) spawns a second, separate job-container pod via
its own k8s hook once a job starts — the control pod only orchestrates; the actual
`npm`/`cargo`/`dotnet` work happens in the second pod. The ResourceQuota math above never
accounted for this: 500m (control) + 500m (job-container, the LimitRange default) is
1000m per job, double what was budgeted. Worse, the two pods fail differently: ARC's own
reconciliation loop retries a blocked *control* pod gracefully every 30s, but a blocked
*job-container* pod does not retry — it hard-fails the run. Two repos' jobs landing close
together exhausted the quota and hard-failed rather than queuing.

Fixed in the same pass as the listener resize below: the control pod's own resources cut
to 25m/250m (it doesn't do the real work, so it doesn't need runner-workload sizing), and
`limits.cpu` retuned to 1500m specifically so a *second* job's control pod is never
admitted while a first job's pair is still up — any collision is caught at the
gracefully-retried stage, not the hard-failing one. See `resourcequota.yaml`'s own comment
for the arithmetic. This is tighter than the original 2 cores (50% of the node), not
looser: 1.5 cores is 37.5%, a wider platform margin.

Also discovered live: `rivet-workstation-runners`' listener pod had never come up at all
(silently missing from `kubectl get pods` since day one) — the four listeners' *own*
unsized resource footprint (500m each, the LimitRange default, for a long-poll HTTP
client that needs a fraction of that) had already consumed the entire original quota
before job pods entered the picture. Fixed via `listenerTemplate` overrides, 10m/100m
each.
