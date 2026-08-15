# Changelog

Notable changes to this homelab. Versions here are cluster generations, not software
releases, and the dates are when the cluster actually changed rather than when a commit
landed.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Repository scaffolding for v3: docs site, decision records, issue templates, CI, and
  the Taskfile and mise setup that pins the tooling.

### Removed

- The v1 `clusters/` tree. Git history is the record; nothing was archived into the
  working tree.

## [v2] - 2023-02-02

k3s on a Dell Optiplex 3050 under Proxmox. Flux v0.39, Calico, Traefik, Cloudflare DDNS.
Lives in [-DEPRECIATED-k3s-homelab](https://github.com/fobiat/-DEPRECIATED-k3s-homelab)
at the `v2` tag, not in this repository.

## [v1] - 2021-01-11 to 2023-01-27

Kubernetes on a Dell PowerEdge, Flux v2, MetalLB. The history is in this repository,
below the v3 scaffolding commit.
