# Activating the private-repo runner scale sets

!!! warning "UNTESTED"

    Not yet executed on this cluster. See AGENTS.md rule 9. The controller and
    guardrails can be proven on the throwaway Talos-in-Docker cluster; a real
    workflow run against any scale set cannot, since that needs the real
    GitHub App. See ADR 0015.

The controller and its resource guardrails are live once
`kubernetes/apps/actions-runner-system` is merged. Four runner scale sets
ship alongside it, each `spec.suspend: true`, one per private repo with a
real CI pipeline today: `fobiat/AppleJackRP-sandbox`, `fobiat/Rivet`,
`fobiat/rivet-workstation` and `fobiat/cairn`. All four reference one shared
GitHub App that does not exist yet. This is how you create it and turn the
scale sets on.

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

Copy one of the four app directories to a new one, change
`githubConfigUrl`, the `OCIRepository`/`HelmRelease` names, and add its
`ks.yaml` to `kubernetes/apps/actions-runner-system/kustomization.yaml`.
`githubConfigSecret` stays `actions-runner-github-app` if the new repo is
added to the existing App's installation (Install App page, add the repo to
the same installation); only create a second App if that repo's blast
radius genuinely needs to be separate from the other four's.
