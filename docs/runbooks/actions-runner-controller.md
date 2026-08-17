# Activating the AppleJackRP-sandbox runner scale set

!!! warning "UNTESTED"

    Not yet executed on this cluster. See AGENTS.md rule 9. The controller and
    guardrails can be proven on the throwaway Talos-in-Docker cluster; a real
    workflow run against this scale set cannot, since that needs the real
    GitHub App. See ADR 0015.

The controller and its resource guardrails are live once
`kubernetes/apps/actions-runner-system` is merged. The runner scale set for
`fobiat/AppleJackRP-sandbox` ships alongside it, `spec.suspend: true`,
because it needs a GitHub App that does not exist yet. This is how you
create that App and turn the scale set on.

## Step 1: create the GitHub App

1. Go to `https://github.com/settings/apps/new` under the `fobiat` account.
2. **GitHub App name**: anything unique, e.g. `fobiat-arc-applejackrp-sandbox`.
3. **Homepage URL**: `https://github.com/fobiat/AppleJackRP-sandbox` (required
   field, not otherwise used).
4. **Webhook**: uncheck "Active". This scale set polls; it does not use
   webhook-driven scaling.
5. **Repository permissions**:
   - Actions: **Read-only**
   - Administration: **Read and write**
   - Metadata: **Read-only** (mandatory default)

   No organisation permissions are needed; this repository is on a personal
   account, not an org. Confirmed against
   `actions/actions-runner-controller`'s own
   `authenticating-to-the-github-api.md` for repository-scoped runners.
6. Create the app, then on its settings page:
   - Note the **App ID** at the top.
   - Under "Private keys", **Generate a private key**. This downloads a
     `.pem` file once; it cannot be re-downloaded, only regenerated.

## Step 2: install the App on the one repo

1. On the App's settings page, open **Install App**.
2. Install it on the `fobiat` account, **Only select repositories**:
   `AppleJackRP-sandbox`. Do not select "All repositories."
3. After installing, the URL bar shows
   `https://github.com/settings/installations/<INSTALLATION_ID>`. That
   number is the **Installation ID**.

## Step 3: encrypt the credential

Same shape as every other credential this repo has staged this way (ADR
0009's backup certificates, `alertmanager-discord-webhook.PLACEHOLDER.yaml`):

```bash
cd kubernetes/apps/actions-runner-system/applejackrp-sandbox/app
cp github-app.PLACEHOLDER.yaml applejackrp-sandbox-runner-github-app.sops.yaml
```

Edit the copy: set `github_app_id` and `github_app_installation_id` to the
values from steps 1 and 2 (as strings, quoted), and replace
`github_app_private_key`'s placeholder with the full contents of the
downloaded `.pem` file, indented to match the existing block scalar.

```bash
sops --encrypt --in-place applejackrp-sandbox-runner-github-app.sops.yaml
```

Then:

1. Add `./applejackrp-sandbox-runner-github-app.sops.yaml` to this
   directory's `kustomization.yaml` (uncomment the line already there).
2. Set `helmrelease.yaml`'s `spec.suspend` to `false`.
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

Expect one listener pod once the `AutoscalingRunnerSet` picks up the
unsuspended HelmRelease. `kubectl describe autoscalingrunnerset
applejackrp-sandbox-runners` surfaces the GitHub API error directly if the
App ID, installation ID or key are wrong, faster than reading pod logs.

On the GitHub side, `AppleJackRP-sandbox` → Settings → Actions → Runners
should show the scale set as a runner group.

## Step 5: prove it with a real workflow

Trigger any workflow in `AppleJackRP-sandbox` with
`runs-on: <scale-set-name>` (the scale set name defaults to the Helm release
name, `applejackrp-sandbox-runners`). Watch:

```bash
kubectl -n actions-runner-system get pods -w
```

A runner pod should appear, run the job, and terminate (ephemeral runners do
not persist between jobs). This is the point ADR 0015 flags as unproven
until it actually happens: confirm `containerMode: kubernetes` job-step pods
land inside the namespace's `ResourceQuota`/`LimitRange`
(`kubectl -n actions-runner-system get resourcequota,limitrange`) rather than
running unbounded, and that ordinary jobs actually complete without hitting
the 1 core / 1Gi per-container ceiling. If a real workflow needs more than
that ceiling, raise `limitrange.yaml`'s `max` deliberately, in its own PR,
rather than loosening it as a side effect of getting one job to pass.

Once a run has gone green, remove this runbook's `UNTESTED` banner.

## Adding a second private repo later

Copy `applejackrp-sandbox/` to a new directory, change `githubConfigUrl`,
`githubConfigSecret`'s name, the `OCIRepository`/`HelmRelease` names, and add
its `ks.yaml` to `kubernetes/apps/actions-runner-system/kustomization.yaml`.
Either reuse this GitHub App (install it on the new repo too, from the same
App's Install App page) or create a separate one; the controller and its
guardrails are shared either way.
