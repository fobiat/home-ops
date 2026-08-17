# Umami

Umami is the privacy-focused analytics service for the personal site. Its dashboard
is private at `https://umami.lab.fobiat.dev`; it is reachable only from the LAN or
through Tailscale.

The service runs the upstream `ghcr.io/umami-software/umami:3.3.0` image as a
non-root user with a read-only root filesystem. Its PostgreSQL database is a
one-instance CloudNativePG cluster in the same namespace, using the `local-path`
storage class and a 10 GiB PVC. Both workloads have explicit requests and limits:
Umami requests 100m CPU and 128 MiB memory, and PostgreSQL requests 100m CPU and
256 MiB memory.

## Public collection

The browser collector is staged at `https://insights.fobiat.dev`, not enabled. The
cluster accepts only two exact paths through the external Gateway:

- `/script.js`, the tracker script
- `/api/send`, the event endpoint

There is no public DNS CNAME yet, so those routes are unreachable from the internet.
Before enabling collection, create the CNAME to the existing Cloudflare Tunnel,
install the WAF rate limit for `/api/send`, create the website in Umami, and add its
generated `data-website-id` to the personal site's tracker snippet. The site ID is
application data, not a cluster secret, and does not belong in this repository.

The gateway path restriction is a safety boundary, not a substitute for Cloudflare's
edge controls. See [Exposure](exposure.md) and
[ADR 0014](adr/0014-umami-analytics.md) for the complete publication decision.

## Backups

`umami-pgdump` creates one PostgreSQL custom-format dump every day at 03:05 UTC on
its own 2 GiB PVC. The job reads the database connection from CNPG's generated app
secret, writes as PostgreSQL's UID 26, checks that the archive is readable with
`pg_restore --list`, and retains seven local dumps.

A VolSync `ReplicationSource` copies that PVC at 04:10 UTC to a separate 5 GiB
restic repository PVC. It uses `copyMethod: Direct` because `local-path` does not
provide Kubernetes VolumeSnapshots. The first VolSync run occurs immediately when
the source is created, which can happen before the first scheduled dump. A successful
empty-directory skip is expected in that case; the next scheduled sync is the first
archive of real data.

The repository is an interim same-node copy until the R2 Barman plugin and off-node
retention are configured. It protects against an accidental PVC deletion, not loss of
the host or its data disk. Restore testing is still required before calling this a
recovery path.

## Checks

Gatus checks the private dashboard at `https://umami.lab.fobiat.dev`. CloudNativePG's
PodMonitor exposes PostgreSQL metrics to the existing Prometheus stack. The dashboard
is healthy only when the Umami Deployment, the `umami-db` Cluster, and its generated
app secret are all ready.
