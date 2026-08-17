# 0014. Umami analytics on CNPG, with a private dashboard and narrow public ingest

Status: Accepted, 2026-08-17

## Context

The personal site needs basic audience analytics without coupling the site itself to
the cluster. The dashboard needs durable PostgreSQL storage, while browser collection
needs one public endpoint. Publishing the dashboard, its API, or a broad path prefix
would turn a small telemetry feature into a second public application.

The node has roughly 7.1 GiB of allocatable memory and already hosts the platform
services. A database choice therefore needs explicit resource bounds and an upgrade
path that does not rely on manually managed PostgreSQL state.

## Decision

Run Umami 3.3.0 privately in the `umami` namespace with a one-instance CloudNativePG
PostgreSQL 18 cluster on `local-path` storage. The dashboard is served only through the
internal Gateway at `umami.lab.fobiat.dev`.

Publish collection separately through `insights.fobiat.dev`. The public Gateway route
matches only `/script.js` and `/api/send`, and its cross-namespace backend is allowed
by a ReferenceGrant owned by Umami. cloudflared forwards that hostname to the external
Gateway. The route is staged before public DNS exists, so a CNAME to the tunnel and a
Cloudflare WAF rate limit for `/api/send` are both explicit later actions.

Until off-node backups are configured, a daily custom-format `pg_dump` lands on its
own PVC and VolSync copies that PVC to a separate local restic repository. This is a
short-lived safety net, not disaster recovery. The planned R2 Barman plugin will own
WAL archival and durable database backups.

## Consequences

The dashboard stays off the public internet and the collector cannot proxy arbitrary
Umami paths. The external DNS step cannot be mistaken for a routine manifest change:
it is the moment public collection becomes reachable and requires the edge rate limit
to be ready first.

CloudNativePG gives the database a declarative lifecycle and metrics integration, but
one instance on local storage has no host-level availability. The dump plus same-node
VolSync repository reduces accidental-deletion risk only. R2 credentials, bucket
provisioning, and a restore drill remain necessary to close the backup design.

The tracker requires a website UUID created in Umami. That identifier is intentionally
kept in the personal site's source, alongside the script that uses it, rather than in
cluster configuration.

## Alternatives

**Use SQLite.** Rejected because the service needs a supported PostgreSQL deployment
and the phase already standardises on CloudNativePG for database lifecycle and backups.

**Publish the dashboard through the external Gateway.** Rejected because collection is
the only public requirement. Keeping the dashboard private avoids a login surface and
keeps the public route easy to audit.

**Expose an `/api` or catch-all prefix.** Rejected because an exact allow-list is small
enough to review and prevents unrelated Umami endpoints becoming public with no new
publication decision.
