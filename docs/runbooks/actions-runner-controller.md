# Activating the private-repo runner scale sets

!!! warning "PARTIALLY PROVEN (cairn only)"

    Steps 1-4 are done: the GitHub App exists (`fobiat-actions-runner-controller`,
    app ID `4623315`), installed on all four repos, credential encrypted into
    `controller/app/github-app.sops.yaml`, all four scale sets unsuspended.

    **2026-08-17: Step 5 confirmed for `cairn` only.** `fobiat/cairn` PR #9
    (`ci/pool-cluster-and-laptop`) put `check`/`manifests`/`notify` on the
    `cairn-runners` label. Watched it live: an ephemeral runner pod
    (`cairn-runners-qjp2j-runner-mcwrf`) registered against
    `https://github.com/fobiat/cairn`, claimed the `notify` job, and
    `containerMode: kubernetes` created a matching `<runner>-workflow` pod
    running `alpine:3.20` inside the namespace's `ResourceQuota`/`LimitRange`
    (confirmed with `kubectl -n actions-runner-system get resourcequota,limitrange`);
    the step ran `apk add curl jq` and posted to Discord successfully. This is
    direct proof the mechanism ADR 0015 flags as unproven does work as
    documented.

    Still not proven: `check` and `manifests` (their job containers are
    `node:26` and `ubuntu:24.04`) have not yet completed a real step —
    every attempt so far has died in the runner's own "Set up job" phase
    downloading `actions/checkout` from `codeload.github.com`, HTTP 429,
    three retries in a row across both the cluster and laptop runners. That
    is GitHub-side throttling of this laptop's outbound IP, not a scale-set
    defect (the laptop runner hit the identical error). Retry later once the
    throttle clears rather than immediately again; three reruns in ~20
    minutes is almost certainly what triggered it. `Rivet`, `rivet-workstation`
    and `AppleJackRP-sandbox` remain entirely unproven — none of their
    workflows have been pointed at their scale set's label yet.

    **Separate finding, same session, and the first diagnosis was wrong.**
    While watching PR #9, `kube-scheduler` and `kube-controller-manager` were
    both `CrashLoopBackOff` and new pods took minutes to schedule. Both pods'
    last-terminated state was `reason: Error` (exit 1), not `OOMKilled`, and
    their logs showed leader-election renewals timing out (`context deadline
    exceeded` against the local apiserver). `/proc/loadavg` read 17-26 on
    four allocatable cores, so this was written up as CPU starvation and
    PR #93 shipped 200m CPU requests on both as the mitigation. **The
    restarts never stopped.**

    Re-measured on 2026-08-21 with no CI running at all: CPU utilisation 29%
    and cpu PSI wait 0.11, against `pgmajfault` at 208/s sustained (one 10s
    sample caught 714/s), `MemAvailable` at 29.1% of total, and `sda` reads
    of 80-101 MB/s against roughly 323 KB/s of writes. The node is page-cache
    starved. Reclaim evicts executable pages, processes block faulting them
    back in, and `kube-scheduler`'s 5-second lease renewal blows its
    deadline. The high load average was processes blocked on disk, not
    contention for cores. Two details pin it at node level rather than
    ADR 0007's cgroup level: no container exceeds 68% of its own memory
    limit, and reads dwarf writes by two orders of magnitude.

    **The fix is RAM, not a second node.** The host has 32GB and the VM has
    8GB; 16GB takes page cache from roughly 2.7GB to 10GB, and ADR 0007
    already performed this same fix once at the previous size. That keeps
    ADR 0005's single-node decision intact. `--kube-reserved` /
    `--system-reserved`, `cpuManagerPolicy: static` and PriorityClass are all
    dead ends here: none of them touch page reclaim, and on Talos the
    control-plane static pods live in `kubepods` rather than the reserved
    slices. Concurrent CI still makes the bursts worse, so treat it as an
    aggravator of a memory problem rather than the cause.

The controller and its resource guardrails are live once
`kubernetes/apps/actions-runner-system` is merged. Four runner scale sets
ship alongside it, one per private repo with a real CI pipeline today:
`fobiat/AppleJackRP-sandbox`, `fobiat/Rivet`, `fobiat/rivet-workstation` and
`fobiat/cairn`. All four reference one shared GitHub App. Steps 1-4 below are
kept as the reference procedure (and for adding a fifth repo later); skip to
Step 5 to finish proving this out.

## Step 1: create the GitHub App

1. Go to `https://github.com/settings/apps/new` under the `fobiat` account.
2. **GitHub App name**: anything unique, e.g. `fobiat-actions-runner-controller`.
3. **Homepage URL**: `https://github.com/fobiat/AppleJackRP-sandbox` (required
   field, not otherwise used).
4. **Webhook**: uncheck "Active". These scale sets poll; none use
   webhook-driven scaling.
5. **Repository permissions**:
   - Actions: **Read-only**
   - Administration: **Read and write**
   - Metadata: **Read-only** (mandatory default)

   No organisation permissions are needed; these repositories are on a
   personal account, not an org. Confirmed against
   `actions/actions-runner-controller`'s own
   `authenticating-to-the-github-api.md` for repository-scoped runners.
6. Create the app, then on its settings page:
   - Note the **App ID** at the top.
   - Under "Private keys", **Generate a private key**. This downloads a
     `.pem` file once; it cannot be re-downloaded, only regenerated.

## Step 2: install the App on all four repos

1. On the App's settings page, open **Install App**.
2. Install it on the `fobiat` account, **Only select repositories**:
   `AppleJackRP-sandbox`, `Rivet`, `rivet-workstation`, `cairn`. Do not
   select "All repositories." (A repo can be added to this same
   installation later from the same page, without creating a second App.)
3. After installing, the URL bar shows
   `https://github.com/settings/installations/<INSTALLATION_ID>`. That
   number is the **Installation ID**, shared by all four repos since they
   are one installation.

## Step 3: encrypt the credential

One secret, shared by all four `helmrelease.yaml`s, same shape as every
other credential this repo has staged this way (ADR 0009's backup
certificates, `alertmanager-discord-webhook.PLACEHOLDER.yaml`):

```bash
cd kubernetes/apps/actions-runner-system/controller/app
cp github-app.PLACEHOLDER.yaml github-app.sops.yaml
```

Edit the copy: set `github_app_id` and `github_app_installation_id` to the
values from steps 1 and 2 (as strings, quoted), and replace
`github_app_private_key`'s placeholder with the full contents of the
downloaded `.pem` file, indented to match the existing block scalar.

```bash
sops --encrypt --in-place github-app.sops.yaml
```

Then:

1. Add `./github-app.sops.yaml` to this directory's `kustomization.yaml`
   (uncomment the line already there).
2. Set `spec.suspend` to `false` in whichever of the four scale sets'
   `helmrelease.yaml` files are ready to go live. They do not have to move
   together; unsuspending `applejackrp-sandbox/app/helmrelease.yaml` alone
   first, to prove the pattern before flipping the other three, is
   reasonable.
3. Delete `github-app.PLACEHOLDER.yaml`.
4. Delete the local `.pem` file once it is encrypted into Git; it should not
   sit on disk outside the SOPS file.

Open this as its own PR, with the real `flux-local diff` in front of the
reviewer (AGENTS.md rule 6), same as every other change here.

## Step 4: confirm it came up

```bash
kubectl -n actions-runner-system get autoscalingrunnerset
kubectl -n actions-runner-system get pods
```

Expect one listener pod per unsuspended scale set. `kubectl describe
autoscalingrunnerset <name>-runners` surfaces the GitHub API error directly
if the App ID, installation ID or key are wrong, faster than reading pod
logs.

On the GitHub side, each repo's Settings → Actions → Runners should show
its scale set as a runner group.

## Step 5: prove it with a real workflow

Trigger any workflow in one of the four repos with
`runs-on: <scale-set-name>` (the scale set name defaults to the Helm
release name: `applejackrp-sandbox-runners`, `rivet-runners`,
`rivet-workstation-runners` or `cairn-runners`). Watch:

```bash
kubectl -n actions-runner-system get pods -w
```

A runner pod should appear, run the job, and terminate (ephemeral runners do
not persist between jobs). This is the point ADR 0015 flags as unproven
until it actually happens: confirm `containerMode: kubernetes` job-step pods
land inside the namespace's `ResourceQuota`/`LimitRange`
(`kubectl -n actions-runner-system get resourcequota,limitrange`) rather than
running unbounded, and that ordinary jobs actually complete without hitting
the 1 core / 1Gi per-container ceiling. `Rivet`'s cargo builds are the most
likely of the four to hit that ceiling first. If a real workflow needs more
than it, raise `limitrange.yaml`'s `max` deliberately, in its own PR, rather
than loosening it as a side effect of getting one job to pass. Since the
`ResourceQuota` is shared across all four repos, also watch what happens if
two of them run CI at the same time: the second build's pods should queue as
`Pending`, not fail outright.

Once a run has gone green on each repo actually using this, remove this
runbook's `UNTESTED` banner.

## Adding a fifth private repo later

This is now automatic (ADR 0016): `.github/workflows/sync-actions-runners.yaml` runs
weekly and opens a PR for any private, non-archived, non-fork repo with a
`.github/workflows` directory that doesn't have a scale set yet, installing the shared
App on it automatically. Run it on demand from the Actions tab
(`workflow_dispatch`) instead of waiting for the schedule.

**One-time setup this automation needs, not yet done:** a classic PAT with the `repo`
scope, stored as the `ARC_SYNC_PAT` repository secret. Create it at
`https://github.com/settings/tokens/new` (Tokens (classic), scope: `repo`, no
expiration or a long one since a lapsed token silently stops the automation rather than
failing loudly), then set it directly rather than pasting it into chat:

```bash
gh secret set ARC_SYNC_PAT --repo fobiat/home-ops
```

(paste the token when prompted, or pipe it via stdin). See ADR 0016 for why this
specific credential is needed and why it's broader than everything else in this repo.

To do it by hand instead: copy one of the app directories to a new one, change
`githubConfigUrl`, the `OCIRepository`/`HelmRelease` names, and add its `ks.yaml` to
`kubernetes/apps/actions-runner-system/kustomization.yaml`. `githubConfigSecret` stays
`actions-runner-github-app` if the new repo is added to the existing App's installation
(Install App page, add the repo to the same installation); only create a second App if
that repo's blast radius genuinely needs to be separate from the others'.
