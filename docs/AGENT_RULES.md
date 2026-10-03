# Agent rules

Hard rules for agents and contributors in this repository. This page is public-safe: it
names the gate, the identity rules and the boundaries, and nothing private.

| Rule | Detail |
|---|---|
| Status | Archived in place: the cluster was decommissioned on 2026-09-29, so changes are limited to documentation and the decommission itself |
| Gate | `task lint` passes before any commit; CI runs the same yamllint, comment budget, cloudflared ingress and docs build steps on every push and pull request |
| Commits | Signed only, as Kyle <kyle@fobiat.dev>; prove with `git log -1 --pretty='%G? %GS'` |
| Secrets | Never in Git in plain text; secrets are encrypted with SOPS and age, and the age private key never enters this repository |
| Attribution | No assistant, model or vendor names, session IDs or co-author lines in commits, pull requests, issues, code or docs |
| Tracking | GitHub issues are the tracker: each task, bug or follow-up is an issue, and each pull request names the issue it closes |
| Docs | A visible change updates the docs and `CHANGELOG.md` in the same commit |

Read the [README](https://github.com/fobiat/home-ops#readme) for the current status, and
the [decision records](adr/README.md) for why the cluster was built the way it was.
