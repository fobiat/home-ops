# 0005. One node, and what that gives up

Status: Accepted, 2026-08-15

## Context

Version 1 ran on a Dell PowerEdge. It was retired partly because a full rack is loud,
hot and expensive to run. Version 2 went to a single Optiplex explicitly because UK
electricity hit 68.3p/kWh.

That constraint has largely gone. The Ofgem cap for July to September 2026 is 26.11p/kWh,
and an Optiplex idling around 12W costs roughly £25 to £38 a year. So the reason for one
node is no longer cost.

## Decision

Stay on one node anyway, and be explicit in the documentation about what that costs
rather than pretending the cluster is more resilient than it is.

## Consequences

The things that genuinely do not work, and are documented wherever they matter:

- **Every upgrade is an outage.** Cordon and drain have nowhere to send anything. The API
  server goes down with the node it runs on.
- **PodDisruptionBudgets protect nothing.** Talos ignores eviction failures during its
  own drains (an open upstream issue), and there would be nowhere to evict to regardless.
  A `minAvailable: 1` PDB here is a false sense of safety.
- **A naive upgrade can strand the node**, because the pod running the upgrade gets
  evicted before the reboot finishes. `tuppr` handles this by skipping drain entirely on
  single-node clusters, which is why it is the planned upgrade mechanism.
- **etcd has one member.** There is no quorum to lose, but there is also no peer to
  recover from. `talosctl bootstrap --recover-from` assumes a surviving node, which does
  not exist here. An etcd snapshot covers corruption on a live host, not a dead disk.
- **Charts assume more nodes.** Default `affinity` blocks and topology spread constraints
  leave replicas `Pending` forever. Every chart's defaults get checked.

What is deliberately not attempted: distributed storage, HA control plane, multi-replica
anything, Alertmanager clustering.

Because the cluster's own monitoring dies with the node, the deadman switch has to live
outside it. The `Watchdog` alert is routed to healthchecks.io from a Pi Zero W.

## Revisiting

A Minisforum MS-03 class machine is expected within months. That is a rebuild with a
fresh etcd rather than a move, so every persistent volume has to return from a backup.
This is why backups are a prerequisite for the hardware upgrade and not an optional
extra.
