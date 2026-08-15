# home-ops

One Talos node, one Flux repository, no configuration done by hand.

If you are looking for something specific:

- **Setting this up from nothing**: [Bootstrap](bootstrap.md)
- **The disk died**: [Restore](runbooks/restore.md)
- **Upgrading Talos or Kubernetes**: [Upgrade](runbooks/upgrade.md)
- **Something is broken**: [Troubleshooting](runbooks/troubleshooting.md)
- **Why is it like this**: [Decision records](adr/README.md)

## The shape of it

Flux watches this repository and reconciles it into the cluster. Nothing else writes to
the cluster. A change is a pull request, and the pull request carries a rendered diff of
what will actually change.

Talos owns the node. Its configuration is a file in `talos/`, applied through an API.
There is no SSH and no package manager, so there is no way for the node to drift from
what is written down.

Access is Tailscale first. Services live on `*.lab.fobiat.dev` and resolve only inside
the tailnet or on the local network. Making something public is a deliberate, documented
act rather than a default.

## Honest limitations

This is one machine. Upgrades are outages. There is no failover, no quorum, and no
second copy of anything running. The [single node decision record](adr/0005-single-node.md)
lists exactly what that costs and what is deliberately not attempted because of it.

Backups currently go to a second disk in the same machine, which protects against
deleting a volume and against nothing else. Offsite is planned and is a prerequisite for
the hardware upgrade.
