# Repository working rules

These rules apply to local work, remote work and contributors. Project rules take
precedence over workflow tools. Keep changes within the agreed issue and record
follow-ups in the issue tracker.

## Hard rules

- Treat Git as the source of truth. Commit manifests and let Flux reconcile them.
  Do not replace GitOps with live `kubectl apply`, `helm install` or dashboard edits.
- Commit Talos machine configuration before applying it. Rehearse cluster changes
  on the throwaway Talos-in-Docker cluster before using the real node.
- Every change, including documentation, goes through a pull request. Cluster
  changes include the rendered Flux diff. Deploy from the default branch after
  the gate passes.
- Keep service access private by default. Public exposure needs an explicit owner
  decision and documentation. Preserve the existing gateway, secrets and storage
  boundaries; document any new alternative in an ADR.
- Pin chart and image versions. Declare resource requests and limits for
  workloads outside the platform. Each app owns its health check and backup
  policy alongside its manifests.
- Keep the app layout: the root app kustomization lists namespaces, each namespace
  lists app `ks.yaml` files, and each app's Flux Kustomization targets its `app/`
  directory. Preserve dependency and health-check declarations.
- Work in an isolated worktree. Respect other work in progress and the assigned
  file ownership. Only the coordinating maintainer commits, merges and pushes
  shared work. Run the full gate after implementation lanes finish.
- Changes to code or manifests need an independent review pinned to the final
  commit, with a passing gate at that commit. Fix blocking findings before merge.
  Keep the pull request as a draft while required verification is blocked.
- Never force-push, bypass hooks, rewrite shared history or commit destructive
  actions. Leave provider authentication and runtime state alone.
- Keep credentials encrypted or outside the repository. Do not publish personal
  locations, filesystem paths, nonpublic hostnames, IP addresses or identifiers.
  Scan changes for secrets and leaks before publishing them.
- Update user documentation and the changelog with visible changes. Explain
  boundary changes in architecture documentation and argued decisions in ADRs.
  Mark untested runbooks `UNTESTED` until they have been walked.
- Write plain, human prose without em dashes. Keep implementation comments short
  and explain the non-obvious reason. The comment-budget gate enforces the limit.
- Record observed results accurately. Distinguish fixture checks, rendered
  manifests, rehearsals and real service checks; prove the real path once.

## Gate

Run from the repository root before committing:

```sh
task lint
task diff
task talos:test
```

`task lint` checks YAML, rendered Kubernetes schemas, comment density, tunnel
routing and the documentation build. `task diff` runs `flux-local diff` against
`origin/main`; attach its output to the pull request. `task talos:test` creates the
throwaway Talos cluster. Rehearse the changed manifests there and verify the
result; creating the cluster alone does not test the change.

Run any additional build and tests needed for the changed component. Review the
staged patch for secrets and leaks. Keep evidence for required checks and report
blocked or unverified steps explicitly. A targeted check does not satisfy the
full gate.

## Commits and landing

Use Kyle's approved maintainer identity and sign each commit with the approved
key. Do not add repository-local identity overrides. Verify the resulting
signature with:

```sh
git log -1 --pretty='%G? %GS'
```

Use a concise subject that names the component and resulting behaviour, such as
`homepage: add Cambridge weather`. Reference the fixing issue in the pull
request and close it with the fixing commit. Use signed fast-forward landing
and preserve the reviewed commit. Do not add automated authorship trailers,
generation notices, tool branding or execution identifiers to repository content
or history. Keep checkpoint commits off the default branch.
