# 0016. Scheduled sync for new private-repo runner scale sets

Status: Accepted, 2026-08-17

## Context

ADR 0015 scaffolded four runner scale sets by hand. Kyle asked for this to stay current
automatically: a new private repo with a real CI pipeline should get a scale set without
someone remembering to come back and repeat ADR 0015's manual steps.

Three shapes were on the table.

**Manual, repeat ADR 0015's steps each time.** No new component, no new credential.
Relies on remembering, the exact failure mode the automation exists to remove.

**Scaffold-only automation.** A scheduled job opens a PR with the generated manifests,
but a human still clicks "Install App" on the new repo by hand. No credential broader
than what already exists. Kyle's own framing when asked (AskUserQuestion) was "full
auto," so this was offered but not chosen.

**Full automation**, the option chosen: a scheduled GitHub Actions workflow
(`.github/workflows/sync-actions-runners.yaml`) that finds private, non-archived,
non-fork repos with a `.github/workflows` directory and no scale set yet, scaffolds
their app directory the same way `scripts/sync-actions-runners.sh` does by hand, adds
the repo to the shared GitHub App's installation via the API, and opens a PR.

## Decision

### The credential is a real trade-off, not a free upgrade

GitHub's "Add a repository to an app installation" endpoint
(`PUT /user/installations/{id}/repositories/{repository_id}`) only accepts a classic
personal access token with the `repo` scope; it does not accept the App's own
installation token. Confirmed against GitHub's REST API docs directly, not assumed.
A `repo`-scope classic PAT is not narrowly scoped the way every other credential in this
repo is (the Cloudflare token, the R2 token, the Talos certificates): it grants
read/write on every repo the account can access, private or public, not just the four
this automation manages. Kyle chose to accept this after being shown the alternative
(scaffold-only, no broad credential) explicitly.

Stored as the `ARC_SYNC_PAT` repository secret (`gh secret set ARC_SYNC_PAT --repo
fobiat/home-ops`, piped via stdin, never echoed, same handling as every other secret
here). It is used for the two calls that actually need it (listing private repos,
adding a repo to the installation), and, less obviously, for the git push and PR
creation too:

**Pushes and PRs made with the default `GITHUB_TOKEN` don't trigger this repo's other
workflows.** GitHub's anti-recursion safeguard means a branch pushed and a PR opened
with the ambient token would never fire `lint` or the `diff` jobs, which is exactly the
required status check branch protection waits for (AGENTS.md rule 6). Using
`ARC_SYNC_PAT` for the whole job, not just the two API calls that strictly need it,
avoids opening PRs that can never satisfy branch protection. This is a real, easy-to-miss
trap, not a stylistic choice, worth the comment left in the workflow file.

### Add, never remove

The script only adds scale sets. A repo losing its CI workflow, being archived, or being
deleted is not auto-pruned; that stays a human decision. Auto-removing infrastructure is
a meaningfully different and more consequential action than auto-adding it, and nothing
about "keep this in sync" requires guessing what "in sync" means for the deletion
direction. If this turns out to matter in practice, it is a deliberate follow-up, not
something to have guessed at here.

### Every run still goes through review

The workflow opens a PR (`automation/sync-actions-runners`, reused across runs rather
than one branch per run) rather than pushing to `main` directly. `task lint` runs before
the commit, in-job, so an obviously broken scaffold never reaches the PR at all. Branch
protection (AGENTS.md rule 6) still requires Kyle to merge it. The bot commits as
`github-actions[bot]`, the same identity Renovate already uses in this repo, not as
Kyle and not attributed to any assistant session.

## Consequences

Good: a new private repo with CI gets a working runner with no one having to remember
ADR 0015's steps again. The generated manifests are byte-for-byte the same shape as the
hand-written ones (verified: `kustomize build` on a scaffolded fixture repo produces
output identical in structure to the real `cairn`/`rivet` app dirs).

Bad: `ARC_SYNC_PAT` is the single broadest credential in this repository, wider than the
Talos `os:admin` ServiceAccount tuppr uses (ADR 0010), because Kubernetes-style RBAC
scoping doesn't exist for classic PATs the way it does for Talos roles. It sits in
GitHub Actions secrets, not SOPS, since it is consumed by a workflow rather than a
cluster workload; if a repo maintainer ever gets removed or the token needs rotating,
this is the credential to reach for first. Weekly cadence (`cron: "17 6 * * 1"`, an
off-the-hour offset to avoid GitHub Actions' documented top-of-the-hour scheduling
congestion, the first cron schedule in this repo) plus `workflow_dispatch` for an
on-demand run.
