# 0006. Building v3 on the 2021 repository

Status: Accepted, 2026-08-15

## Context

Four repositories had accumulated for what is really one ongoing project: `k8s-gitops`
(v1, January 2021 to January 2023, 162 commits, 5 stars), `k3s-homelab` (v2, 2022 to
2023, 3 stars), `home-ops` (an abandoned three-commit cluster-template stub from February
2023), and `homelab-config` (private, December 2023, never inspected).

Version 3 needed one of them, and the name `home-ops` was taken by the emptiest one.

## Decision

Build v3 on the old `k8s-gitops` repository, renamed to `home-ops`. The other three take
a `-DEPRECIATED-` prefix, following the convention already used once.

The v1 `clusters/` tree was deleted rather than archived into the working tree. Git
history is the record.

## Consequences

Good: v3 inherits five years of history and the only stars and inbound links any of these
repositories have. One live repository, three obviously dead ones.

Bad: the lineage is now odd. v1 and v3 share a history, while v2 sits in a separate
repository at its own `v2` tag. Anyone reading `git log` sees a 2023 k8s cluster then a
2026 Talos one with nothing between them. The README says so explicitly.

Renaming changes URLs. GitHub redirects the old paths, but any local clone with an old
remote needs `git remote set-url`.

## Alternatives

**Keep building on `k3s-homelab`.** The immediate predecessor, so the lineage would have
read correctly. Rejected because it has fewer stars, less history, and a name that is
wrong the moment the cluster runs Talos.

**Grafting v2's history in as a second root.** Would have put all three versions in one
place. Rejected as git surgery producing a repository with two unrelated roots, for a
tidiness benefit only.
