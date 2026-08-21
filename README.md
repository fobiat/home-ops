# home-ops

Single-node Kubernetes cluster running at home, managed with Flux.

One Talos Linux node, everything in this repository, nothing configured by hand. If the
machine dies I want to rebuild it from a clean disk and this Git history, which is the
whole reason it is laid out this way.

## Status

Live. This is version 3, on Talos, running real workloads: monitoring
(kube-prometheus-stack, alerting to Discord), CNPG-backed Postgres, self-hosted GitHub
Actions runners for several private repos, Umami analytics, Gatus health checks, and
[Cairn](https://github.com/fobiat/cairn), a UK live-incident lookup service deployed
straight from its own repository via Flux and served internally at `cairn.lab.fobiat.dev`.

Everything with state is backed up nightly and the restore path is written down, though
the repository still lives on the same machine. See [Backups](#backups).

The history here goes back to January 2021. Version 1 was Kubernetes on a Dell PowerEdge
and lived in this repository until electricity prices made a full rack unappealing.
Version 2 was k3s on a Dell Optiplex and lives in
[-DEPRECIATED-k3s-homelab](https://github.com/fobiat/-DEPRECIATED-k3s-homelab) at the `v2`
tag. Version 3 starts here, on Talos.

## Hardware

| | |
|---|---|
| Node | Dell Optiplex 3050 SFF, 4 cores, 8 threads, 32GB |
| Runs as | Talos VM on Hyper-V, external virtual switch |
| Storage | NVMe boot, second SSD for persistent volumes |
| Planned | Minisforum MS-03 class, at which point the Optiplex becomes the spare |

One node means no high availability. Upgrades take the cluster down, because there is
nowhere to drain to. The docs say so wherever it matters rather than pretending
otherwise.

## What runs it

| Tool | Job |
|---|---|
| [Talos Linux](https://www.talos.dev) | The OS. Immutable, no SSH, configured by API |
| [Flux](https://fluxcd.io) | Reconciles this repository into the cluster |
| [Cilium](https://cilium.io) | CNI, kube-proxy replacement, and the Gateway API implementation |
| [cert-manager](https://cert-manager.io) | Wildcard certificates over DNS-01 |
| [external-dns](https://github.com/kubernetes-sigs/external-dns) | DNS records from HTTPRoutes |
| [SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age) | Secrets, encrypted in this repository |
| [Tailscale](https://tailscale.com) | How I reach the node and the cluster |
| [VolSync](https://github.com/backube/volsync) | Restic backups of every persistent volume |
| [Gatus](https://github.com/TwiN/gatus) | Health checks, and the status page |
| [Renovate](https://github.com/renovatebot/renovate) | Keeps everything current |

## How it is reached

Nothing is public by default. Services live on `*.lab.fobiat.dev` and resolve only over
Tailscale or the local network. Anything that genuinely needs to be reachable by someone
without my tailnet gets its own name and goes through a Cloudflare Tunnel, one service at
a time, as a deliberate decision rather than a default.

Exactly one thing is public today: `insights.fobiat.dev`, which is Umami's collector. The
route matches two exact paths, `/script.js` and `/api/send`, and nothing else. A request
for `/` returns 404 because there is no rule for it, which is the intended surface rather
than a fault. The dashboard itself stays inside the tailnet.

Tailscale runs as a Talos system extension rather than in the cluster, so the node is
reachable before Kubernetes starts. That matters on the day the cluster is the thing that
is broken.

## Backups

Three things get backed up, on their own schedules, through
[restic](https://restic.net):

| What | When (UTC) | Kept |
|---|---|---|
| etcd snapshot | 03:15 | 14 |
| Talos machine config | 03:30 | 30 |
| Persistent volumes | 04:00, 04:10, 04:40 | 7 daily, 5 weekly, 6 monthly |

The order matters. Both cluster-level jobs finish well before VolSync copies the volume
they write into, so one restic snapshot holds a consistent set.

The honest caveat: the restic repository is a second SSD **on the same machine**. That
survives a bad upgrade, a corrupted etcd, or a fat-fingered `kubectl delete`. It does not
survive the machine. Moving the repository to object storage is the open piece of work,
and until it lands this is a rollback mechanism rather than disaster recovery.

Restoring is the part people skip, so it has its own runbook:
[Restore](docs/runbooks/restore.md) for the whole node, and
[Etcd snapshot restore](docs/runbooks/etcd-restore.md) for the control plane on its own.

## Layout

```
talos/           Machine configuration, encrypted secrets, Image Factory schematic
bootstrap/       Cilium and Flux, installed once before GitOps takes over
kubernetes/
  flux/          Root Kustomization and cluster-wide variables
  components/    Shared Kustomize components
  apps/          Everything else, by namespace
docs/            Runbooks, decision records, and how to rebuild this from nothing
```

## Documentation

Published at [fobiat.github.io/home-ops](https://fobiat.github.io/home-ops/), and
mirrored inside the tailnet at `docs.lab.fobiat.dev`. The source is in
[`docs/`](docs/). Worth reading first:

- [Bootstrap](docs/bootstrap.md), bare disk to running cluster
- [Restore](docs/runbooks/restore.md), what to do when the disk is gone
- [Decision records](docs/adr/), why things are the way they are, including the two
  choices that go against what most people do

## Prior art

This borrows heavily. Worth your time if you are building something similar:

- [onedr0p/home-ops](https://github.com/onedr0p/home-ops) and [cluster-template](https://github.com/onedr0p/cluster-template)
- [buroa/k8s-gitops](https://github.com/buroa/k8s-gitops), for the namespace component trick
- [carpenike/k8s-gitops](https://github.com/carpenike/k8s-gitops), for the flux-local diff workflow
- [home-operations](https://github.com/home-operations), particularly `tuppr`, which is the
  only thing I found that properly handles upgrading a cluster with one node in it
- [kubesearch.dev](https://kubesearch.dev), for finding who else runs a given chart

The k8s-at-home organisation was archived in May 2026. The community moved to the
[Home Operations Discord](https://discord.gg/home-operations).

## Licence

[MIT](LICENSE). Take whatever is useful.
