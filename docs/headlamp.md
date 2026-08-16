# Headlamp access

Headlamp is the cluster management UI, at `https://headlamp.lab.fobiat.dev`, Tailscale
or LAN only. See [ADR 0008](adr/0008-headlamp-token-login.md) for why it uses token
login rather than OIDC or auto-login, and what that trades away.

## Logging in

Login takes a bearer token, not a password. Mint one from a machine that already has
`kubectl` pointed at the cluster:

```sh
kubectl create token headlamp-admin --namespace kube-tools --duration 8h
```

Paste the printed token into Headlamp's login screen. It stops working after 8 hours;
run the command again for a new one.

`headlamp-admin` is bound to `cluster-admin`
(`kubernetes/apps/kube-tools/headlamp/app/rbac.yaml`), so anyone who logs in this way
can do anything the cluster can do: read every Secret, exec into any pod, delete
anything. That is the deliberate trade-off recorded in ADR 0008, not an oversight.
