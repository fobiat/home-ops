# Decision records

Short notes on decisions that were not obvious, written when the decision was made.

Each one says what was decided, why, and what it costs. The point is that in two years
nobody has to reverse-engineer the reasoning from the manifests, and that a decision can
be revisited on purpose rather than drifted away from by accident.

Two of these go against what most of the community does. Those are the ones worth
reading.

| | Decision | Status |
|---|---|---|
| [0001](0001-talos-over-k3s.md) | Talos Linux rather than k3s | Accepted |
| [0002](0002-cilium-gateway-api.md) | Cilium's Gateway API rather than Envoy Gateway | Accepted |
| [0003](0003-sops-age-over-external-secrets.md) | SOPS and age rather than External Secrets | Accepted |
| [0004](0004-local-path-storage.md) | local-path rather than TopoLVM or Longhorn | Accepted |
| [0005](0005-single-node.md) | One node, and what that gives up | Accepted |
| [0006](0006-repository-lineage.md) | Building v3 on the 2021 repository | Accepted |
| [0007](0007-resource-requests-on-critical-pods.md) | Resource requests on cluster-critical pods, never BestEffort QoS | Accepted |
| [0008](0008-headlamp-token-login.md) | Headlamp: token login, not OIDC or auto-login | Accepted |
| [0009](0009-cluster-backup-credentials.md) | Etcd snapshots and machine-config backups from in-cluster CronJobs | Accepted |
| [0010](0010-tuppr-upgrades.md) | tuppr for Talos and Kubernetes upgrades | Accepted |
