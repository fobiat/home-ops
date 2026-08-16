# 0008. Headlamp: token login, not OIDC or auto-login

Status: Accepted, 2026-08-16

## Context

Headlamp is a CNCF cluster management UI going in at `headlamp.lab.fobiat.dev` on the
existing `internal` Gateway: browse resources, tail logs, exec a shell, start and stop
pods. That is a different job from Homepage, which is a status page linking out to
already-running services. Headlamp is the tool that administers the cluster, so who can
open it matters more than it does for Homepage.

The Helm chart supports three ways to answer that:

1. **Token login (the default).** A user pastes a bearer token into the login screen.
   Headlamp's backend proxies every API request using that token, so the ServiceAccount
   the token belongs to controls what the session can do.
2. **OIDC.** The chart has full support for it, but this cluster runs no identity
   provider anywhere. Standing one up just so one person can log into one tool is new
   infrastructure to run and patch, against rule 12 (prefer boring), and is explicitly
   out of scope for this change.
3. **`config.unsafeUseServiceAccountToken: true`.** Skips login entirely: every visitor
   is silently authenticated as the pod's own ServiceAccount. The chart's own values.yaml
   calls this out as "UNSAFE... only safe behind an auth proxy."

The `internal` Gateway is reachable from Tailscale **and** the LAN (see AGENTS.md,
Domain section: "Tailscale or LAN only", not "Tailscale only"). The LAN is the household
network, shared with other people's phones, laptops and smart devices, not a network
under sole control. "The Gateway is already private" means the public internet cannot
reach it; it does not mean only the operator can reach it.

## Decision

Use Headlamp's default token login. Do not configure OIDC. Do not set
`config.unsafeUseServiceAccountToken: true`.

A dedicated `headlamp-admin` ServiceAccount and ClusterRoleBinding to `cluster-admin`
ship with the app (`kubernetes/apps/kube-tools/headlamp/app/rbac.yaml`), so there is a
documented identity to log in as. No token is stored as a Secret or committed anywhere;
it is minted on demand with `kubectl create token` (see `docs/headlamp.md`), which
already requires the caller to hold working cluster credentials. Token issuance sits
behind the same gate as `kubectl`/`talosctl` access, not something self-service from
the LAN.

The chart's own release ServiceAccount is stripped of the permissions it does not need
for this mode: `clusterRoleBinding.create: false` (the chart otherwise binds its own pod
identity to `cluster-admin` by default, regardless of login method) and
`automountServiceAccountToken: false` (nothing in the pod reads that token when
`unsafeUseServiceAccountToken` is off). Without this, the pod would carry a live
cluster-admin credential it has no use for.

## Consequences

Good: nobody gets cluster-admin from Headlamp without a token minted through `kubectl`,
which already means they have cluster credentials. An RCE or a shell exec'd into the
Headlamp pod does not hand over cluster-admin for free, because the pod's own identity
carries none. Exposure matches the rest of phase one: private Gateway, one explicit
access step, recorded here per rule 13.

Bad, stated plainly: the login page is reachable to anyone on the LAN, not just
Tailscale, and once a token is pasted into a browser, that session is cluster-admin for
up to the session TTL (chart default 24 hours). This is trust-the-household-network plus
an explicit auth step, not a defence against a hostile device already on the LAN
watching traffic, reading browser history, or looking over a shoulder while a token is
typed. That risk is accepted here because the alternative (auto-login) removes the auth
step entirely and OIDC adds infrastructure with no other consumer.

Revisit if the threat model ever needs to be stronger than "trusted household network":
a shorter default token duration, a narrower ClusterRole than `cluster-admin` for
`headlamp-admin`, or moving Headlamp behind tighter Tailscale ACLs are the next levers,
in that order.

## Alternatives considered

**OIDC.** Rejected: no identity provider exists, and building one to gate a single
login is disproportionate infrastructure for a single-user homelab.

**`unsafeUseServiceAccountToken: true`.** Rejected: it removes the one auth step that
distinguishes "on the LAN" from "administering the cluster," and the chart's own docs
call it unsafe outside an auth proxy this cluster does not have.

**A narrower default ClusterRole than `cluster-admin` for `headlamp-admin`.** Rejected
for now: there is one operator, and Headlamp's entire purpose here is administering the
cluster: exec, delete, edit. A read-only role would defeat the point of installing it.
Worth reconsidering only if a second, less-trusted person ever needs Headlamp access.
