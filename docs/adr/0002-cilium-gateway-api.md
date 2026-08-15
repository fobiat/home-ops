# 0002. Cilium's Gateway API rather than Envoy Gateway

Status: Accepted, 2026-08-15

## Context

ingress-nginx reached end of life in March 2026 and was archived. InGate, the proposed
community successor, was retired alongside it. Gateway API is the path forward, which
means picking an implementation.

Cilium is already installed as the CNI and the kube-proxy replacement, and it ships its
own Gateway API implementation. Envoy Gateway is the more common choice in homelab
repositories and is what onedr0p's cluster-template installs.

## Decision

Use Cilium's Gateway API implementation. No second ingress controller.

## Consequences

Good: one component instead of two. No extra controller pods, no extra CRD set, no
second thing to upgrade. On a four core node that headroom is worth having. Cilium is
listed as Conformant against Gateway API v1.6.1, including GRPCRoute and BackendTLSPolicy.

Bad: the gateway's release cadence is tied to Cilium's, so a Gateway API bug means
waiting for a Cilium release. Fewer people run this combination than run Envoy Gateway,
so there is less to copy when something breaks. Cilium's Gateway API needs
`gatewayAPI.enableAlpn=true` for gRPC, which is easy to miss.

## Alternatives

**Envoy Gateway.** The majority choice among actively maintained homelab repos. Rejected
for this cluster on component count alone. Worth noting the official Gateway API
conformance table lists it as only Partially Conformant, which is at odds with how it is
usually described.

**Traefik v3.** Conformant, and ships 85+ ingress-nginx-compatible annotations for people
migrating. That compatibility layer is worth nothing here because there is no
ingress-nginx config to migrate.

## Reversing this

Switching to Envoy Gateway means installing it, changing the `parentRef` on every
HTTPRoute, and deleting the Cilium Gateway. That is a contained change, which is part of
why this was an acceptable bet.
