# 0001. Talos Linux rather than k3s

Status: Accepted, 2026-08-15

## Context

Version 2 ran k3s on Ubuntu, bootstrapped with k3sup. It worked, but the node accumulated
state nobody was tracking: packages installed by hand, a kubelet flag changed once during
debugging, config that existed only because someone had typed it. Rebuilding it would
have meant remembering all of that.

The realistic options were k3s again, plain kubeadm, or Talos.

## Decision

Talos Linux. The node has no shell and no SSH, is configured entirely through an API from
a file in this repository, and cannot accumulate undocumented state because there is
nowhere for that state to live.

## Consequences

Good: the machine configuration is a file, so rebuilding is applying it again. Upgrades
are atomic with A/B partitions and automatic rollback on boot failure. There is no
package manager to drift.

Bad: no SSH means no poking at a broken node the familiar way, and `talosctl` has to be
learned. Anything normally installed on the host has to exist as a system extension baked
into the boot image, decided before install rather than added later. The blast radius of
a mistake in the machine config is the whole node.

The specific cost that bit immediately: Tailscale has to be in the Image Factory
schematic from the start, because adding it later means rebuilding the image.

## Alternatives

**k3s again.** Familiar, and the v2 config could have been carried forward. Rejected
because carrying it forward is exactly the problem: it would have brought the
undocumented state with it.

**kubeadm.** More control, considerably more to maintain, and no answer to the drift
problem.
